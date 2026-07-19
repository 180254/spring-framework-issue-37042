#!/usr/bin/env python3
"""Minimal scripted HTTP/2 (h2c, prior knowledge) backend for the haproxy cork report.

Serves every request stream on every connection with a fixed 200 response:

  mode=split (the problematic, RFC-legal pattern):
    HEADERS(:status 200, content-length: N, content-type: application/octet-stream)
    DATA(N bytes, no END_STREAM)
    <gap milliseconds>
    DATA(0 bytes, END_STREAM)

  mode=merged (control):
    HEADERS(...) + DATA(N bytes, END_STREAM) in one write

The split pattern is what Jetty 12 produces for Spring Framework 7.0.5+ applications
whose responses carry a Content-Length (spring-projects/spring-framework#37042).
Standard library only; no external dependencies.

Deliberate simplifications: the body is a single DATA frame (so --bytes is capped at
the peer's default SETTINGS_MAX_FRAME_SIZE of 16384), and the gap sleep blocks the
connection's frame loop, so responses on one connection serialize - drive it with
SEQUENTIAL clients only (as repro.sh does); concurrent-client latencies would be
dominated by this serialization, not by the haproxy behavior under test.
"""

import argparse
import socket
import struct
import threading
import time

PREFACE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

FRAME_DATA = 0x0
FRAME_HEADERS = 0x1
FRAME_SETTINGS = 0x4
FRAME_PING = 0x6
FRAME_GOAWAY = 0x7

FLAG_END_STREAM = 0x1
FLAG_ACK = 0x1
FLAG_END_HEADERS = 0x4

# HPACK static table indexes (RFC 7541 appendix A).
IDX_STATUS_200 = 8
IDX_CONTENT_LENGTH = 28
IDX_CONTENT_TYPE = 31


def frame(ftype: int, flags: int, stream_id: int, payload: bytes) -> bytes:
    header = struct.pack(">I", len(payload))[1:] + bytes((ftype, flags))
    return header + struct.pack(">I", stream_id & 0x7FFFFFFF) + payload


def hpack_int(value: int, prefix_bits: int, pattern: int) -> bytes:
    limit = (1 << prefix_bits) - 1
    if value < limit:
        return bytes((pattern | value,))
    out = bytearray((pattern | limit,))
    value -= limit
    while value >= 0x80:
        out.append(0x80 | (value & 0x7F))
        value >>= 7
    out.append(value)
    return bytes(out)


def hpack_literal(indexed_name: int, value: bytes) -> bytes:
    """Literal Header Field without Indexing - Indexed Name (RFC 7541 6.2.2)."""
    return hpack_int(indexed_name, 4, 0x00) + hpack_int(len(value), 7, 0x00) + value


def response_frames(
    stream_id: int, body_size: int, split: bool, content_length: bool = True
) -> tuple[bytes, bytes]:
    """Returns (first_write, second_write); second_write is empty in merged mode.

    content_length=False omits the content-length header; haproxy then forwards the
    response to an HTTP/1.1 client as chunked - the control for the claim that only
    Content-Length-framed responses are delayed.
    """
    header_block = hpack_int(
        IDX_STATUS_200, 7, 0x80
    )  # Indexed Header Field: :status 200
    if content_length:
        header_block += hpack_literal(IDX_CONTENT_LENGTH, str(body_size).encode())
    header_block += hpack_literal(IDX_CONTENT_TYPE, b"application/octet-stream")
    headers = frame(FRAME_HEADERS, FLAG_END_HEADERS, stream_id, header_block)
    body = bytes(body_size)
    if split:
        first = headers + frame(FRAME_DATA, 0, stream_id, body)
        second = frame(FRAME_DATA, FLAG_END_STREAM, stream_id, b"")
        return first, second
    return headers + frame(FRAME_DATA, FLAG_END_STREAM, stream_id, body), b""


def read_exact(conn: socket.socket, size: int) -> bytes:
    data = b""
    while len(data) < size:
        chunk = conn.recv(size - len(data))
        if not chunk:
            raise ConnectionError("peer closed")
        data += chunk
    return data


def handle_connection(
    conn: socket.socket,
    body_size: int,
    gap_ms: float,
    split: bool,
    content_length: bool,
) -> None:
    try:
        serve_connection(conn, body_size, gap_ms, split, content_length)
    except (ConnectionError, OSError):
        # Peer disconnects (keep-alive teardown, probes) are normal; a traceback per
        # closed connection would make a working reproducer look broken.
        return


def serve_connection(
    conn: socket.socket,
    body_size: int,
    gap_ms: float,
    split: bool,
    content_length: bool,
) -> None:
    with conn:
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        if read_exact(conn, len(PREFACE)) != PREFACE:
            return
        conn.sendall(frame(FRAME_SETTINGS, 0, 0, b""))
        while True:
            head = read_exact(conn, 9)
            length = int.from_bytes(head[0:3], "big")
            ftype = head[3]
            flags = head[4]
            stream_id = int.from_bytes(head[5:9], "big") & 0x7FFFFFFF
            payload = read_exact(conn, length) if length else b""
            if ftype == FRAME_SETTINGS and not flags & FLAG_ACK:
                conn.sendall(frame(FRAME_SETTINGS, FLAG_ACK, 0, b""))
            elif ftype == FRAME_PING and not flags & FLAG_ACK:
                conn.sendall(frame(FRAME_PING, FLAG_ACK, 0, payload))
            elif ftype == FRAME_GOAWAY:
                return
            elif (
                ftype in (FRAME_HEADERS, FRAME_DATA)
                and stream_id
                and flags & FLAG_END_STREAM
            ):
                # Request complete on this stream: respond.
                first, second = response_frames(
                    stream_id, body_size, split, content_length
                )
                conn.sendall(first)
                if second:
                    time.sleep(gap_ms / 1000.0)
                    conn.sendall(second)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=18080)
    parser.add_argument("--bytes", type=int, default=4096, dest="body_size")
    parser.add_argument("--gap-ms", type=float, default=5.0)
    parser.add_argument("--mode", choices=("split", "merged"), default="split")
    parser.add_argument(
        "--no-content-length",
        action="store_true",
        help="omit content-length from the response headers (haproxy then forwards the "
        "response to an h1 client as chunked - the immune control)",
    )
    args = parser.parse_args()
    if args.body_size > 16384:
        # The body is sent as one DATA frame; larger values would exceed the peer's
        # default SETTINGS_MAX_FRAME_SIZE and abort the connection (FRAME_SIZE_ERROR).
        parser.error("--bytes must be <= 16384 (body is sent as a single DATA frame)")

    server = socket.create_server(("127.0.0.1", args.port), reuse_port=False)
    print(
        f"h2c backend on 127.0.0.1:{args.port} mode={args.mode} "
        f"bytes={args.body_size} gap={args.gap_ms}ms "
        f"content_length={not args.no_content_length}",
        flush=True,
    )
    while True:
        conn, _ = server.accept()
        thread = threading.Thread(
            target=handle_connection,
            args=(
                conn,
                args.body_size,
                args.gap_ms,
                args.mode == "split",
                not args.no_content_length,
            ),
            daemon=True,
        )
        thread.start()


if __name__ == "__main__":
    main()
