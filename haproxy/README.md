# haproxy issue report: CL-framed h1 response tail delayed ~200 ms when an h2 backend sends END_STREAM in a separate empty DATA frame

Draft report for https://github.com/haproxy/haproxy/issues, structured along the bug-report
template. The reproducer (`h2-backend.py` + `repro.sh`) is in this directory and needs only
python3, curl and a haproxy docker image.

Suggested title:

> h2 backend -> h1 client: response tail of a Content-Length-framed response is held for
> ~200 ms (kernel cork) when the backend sends END_STREAM in a separate empty DATA frame

## Detailed Description of the Problem

When haproxy proxies an HTTP/2 backend to an HTTP/1.1 client and the backend terminates a
response with a **separate empty `DATA(0, END_STREAM)` frame** (a legal and common pattern:
`HEADERS`, `DATA(N)`, then `DATA(0, END_STREAM)` in a later write), the last body bytes of a
**Content-Length-framed** response reach the client only after an extra ~200 ms.

What happens, per our source reading and strace:

1. The client-side send that carries the last body bytes is flagged `CO_SFL_MSG_MORE`:
   `sc_conn_send()` (`src/stconn.c`) sets it because `htx_expect_more()` is still true - the
   h2 mux has not demuxed `END_STREAM` yet, so the channel HTX carries no `HTX_FL_EOM`. The
   flag propagates through `h1_snd_buf()`/`h1_send()` (`H1C_F_CO_MSG_MORE`) down to
   `raw_sock_from_buf()`, which issues `send(..., MSG_MORE)`. The kernel holds the final
   partial TCP segment.
1. When the empty `DATA(0, END_STREAM)` arrives, the h2 mux turns it into an EOT/EOM
   (`h2_frt_transfer_data()` -> `htx_set_eom()`). On the client side, `h1_process_mux()`
   **silently drops the EOT block for non-chunked messages** (`case H1_MSG_DONE:` - TLR/EOT
   are skipped when `!(h1m->flags & H1_MF_CHNK)`), so the EOM produces **zero output bytes**,
   `h1_send()` returns early on an empty obuf, and **no syscall happens at all**.
1. Nothing ever clears the corked segment: there is no uncork/flush primitive in the xprt
   API, so the kernel releases the tail only via the ~200 ms cork timeout (`tcp(7)`,
   TCP_CORK; `MSG_MORE` behaves the same per `send(2)`).

strace of haproxy (v2.8, worker process, client fd 9, 1000-byte response body; 1039 = 1000
body + 39 bytes of status line, content-length header and terminating CRLF) shows the
smoking gun - the whole response is written in one corked send and no further syscall ever
touches the client socket:

```
sendto(9, "HTTP/1.1 200 \r\ncontent-length: 1"..., 1039, MSG_DONTWAIT|MSG_NOSIGNAL|MSG_MORE) = 1039
(no further syscall on fd 9; the client receives the response ~208 ms later)
```

haproxy's own timers never see the delay (`Ta`/`Tr` stop at the successful `send()`); in the
access log it appears as a large idle time (`Ti`/`Tq` ~= 208 ms) before the *next* request on
the keep-alive connection. That makes the problem effectively invisible to haproxy-side
observability, which is part of why it is nasty to diagnose.

Chunked responses are NOT affected: the terminal `0\r\n\r\n` chunk is real output bytes,
emitted on the EOM pass without `MSG_MORE`, and it flushes the corked data. Known siblings of
this bug class, all accepted and fixed: the chunked variant existed in 2.2.0/2.2.1 via a
stale `CF_EXPECT_MORE` and was addressed by `2151cdd38` (issue #756, reported as a FastCGI
performance regression; merged in 2.3-dev and backported to 2.2/2.1); interim 100-continue
responses were delayed the same way in 2.2.2 (issue #825); bodyless responses (HEAD/204/304)
were fixed in March 2026 by `ee95a7539` ("BUG/MEDIUM: mux-h1: Don't set MSG_MORE on bodyless
responses forwarded to client"), whose commit message describes exactly this scenario ("H2
backends frequently deliver the end-of-stream signal in a separate scheduling round, leaving
htx_expect_more() returning TRUE") but whose guard is scoped to `H1S_F_BODYLESS_RESP`. This
report is about the remaining, body-carrying Content-Length case.

## When it occurs (all conditions required)

- h2 (or h2c) backend server that sends the final body bytes and `END_STREAM` in separate
  writes, so haproxy demuxes them in separate passes. With them in one TCP segment it becomes
  a race; with a few ms of gap it is deterministic.
- Response framed by `Content-Length` towards the HTTP/1.1 client (chunked is immune, see
  above).
- `option http-no-delay` not set (it disables `MSG_MORE` and fully hides the problem).
- The corked segment is the only unacked data in flight (true for any response smaller than
  one MSS, and for the last partial segment of larger responses on an otherwise idle
  connection - i.e., the common request/response case).

This is not an exotic backend behavior: Jetty 12 produces exactly this frame pattern for
every response with a known Content-Length served by a Spring Framework 7.0.5+ MVC
application (a Spring regression stopped propagating the content length to
`HttpServletResponse#setContentLengthLong`, so Jetty no longer recognizes the final write and
defers stream termination to an empty trailing DATA frame - see
spring-projects/spring-framework#37042). Any h2 server that flushes the body before
completing the exchange can legally do the same.

## Consequences

Every affected response is delivered to the client ~200 ms late (almost exactly the kernel
cork timeout; measured 207.8-208.9 ms median on loopback). For a sequential keep-alive
client this compounds into a throughput collapse: in our production-like test, per-request
time went from ~5-7 ms to ~210-225 ms, i.e. a 30-40x slowdown on that flow and a 7x lower
end-to-end throughput for the real service (35 -> 5 requests/s). We verified the behavior is present and unchanged on 2.2,
2.8.22, 2.8.26, 3.0.25, 3.2.21, 3.3.12, 3.4.2 and 3.5-dev (cleartext; over TLS it appears
from 2.8 on, since `ac78c4fd9` started propagating `MSG_MORE` through the SSL send path -
2.6/2.7 TLS frontends are immune, so a 2.6 -> 2.8 upgrade can introduce it on TLS).

## Expected Behavior

The last body bytes of a Content-Length-framed response should be flushed to the client as
soon as the backend message is complete: when the EOM arrives with no output bytes to send,
the pending corked data should still be pushed (or the last body send should not carry
`MSG_MORE` once the announced Content-Length has been fully produced).

## Steps to Reproduce the Behavior

Files in this directory; only python3, curl and a haproxy docker image are needed. Docker
must provide real host networking (native Linux; Docker Desktop and rootless docker run
`--network host` inside a VM/namespace and will not work). The scripted backend supports
single-frame bodies up to 16384 bytes and sequential clients only (both enforced/documented
in the scripts):

```
./repro.sh                          # default image haproxy:3.5-dev
HAPROXY_IMAGE=haproxy:2.8 ./repro.sh
```

`h2-backend.py` is a dependency-free scripted h2c server that answers every request with
`HEADERS + DATA(4096, no ES)`, a 5 ms gap, then `DATA(0, ES)` (`--mode split`), or with
`END_STREAM` on the body frame (`--mode merged`, control); `--no-content-length` omits the
content-length header, so haproxy forwards the response to the h1 client as chunked (the
immune control). `repro.sh` runs haproxy in docker with the full configuration shown under
"What is your configuration?" below and measures a sequential keep-alive curl. Measured
result:

```
CELL         ROUTE           MEDIAN_MS  P90_MS
split        default         207.8      208.0     <- the bug
split        http-no-delay   5.1        5.1
split-nocl   default         5.3        5.3       <- same split framing, no content-length
merged       default         0.1        0.1
```

(haproxy:3.5-dev, loopback; the split cells include the 5 ms backend gap.)

## Do you have any idea what may have caused the issue?

The `MSG_MORE` decision is made upstream from h2-EOM knowledge only (`htx_expect_more()`),
while the h1 mux internally already knows the Content-Length is exhausted (h1m state
`H1_MSG_DONE`); and the EOM pass for non-chunked messages produces no send that could clear
the cork. Same bug class as issue #756 (the chunked variant, commit `2151cdd38`) and
`ee95a7539` (bodyless, fixed 2026-03); the body-carrying CL case is the remaining gap.

## Do you have an idea how to solve the issue?

Two directions, either seems sufficient:

- do not set `CO_SFL_MSG_MORE` on a send once the h1 mux has produced the full announced
  Content-Length (h1m reaches `H1_MSG_DONE`), independently of `HTX_FL_EOM`; or
- on EOM that generates no output bytes for a non-chunked message, perform an explicit
  flush/uncork of the client connection (an empty send without `MSG_MORE`, or a
  `TCP_CORK`-style clear).

## What is your configuration?

The exact configuration repro.sh writes; the fe_nodelay/be_nodelay pair is the control for
the `http-no-delay` results row (and a working mitigation):

```
global
    maxconn 100

defaults
    mode http
    timeout connect 5s
    timeout client 60s
    timeout server 60s

frontend fe_default
    bind 0.0.0.0:19090
    default_backend be_app

frontend fe_nodelay
    bind 0.0.0.0:19091
    option http-no-delay
    default_backend be_nodelay

backend be_app
    server app 127.0.0.1:18080 proto h2

backend be_nodelay
    option http-no-delay
    server app 127.0.0.1:18080 proto h2
```

## Output of haproxy -vv

Fill in from the environment used; for the docker image:
`docker run --rm --entrypoint haproxy <image> -vv`. Reproduced on 2.2 through 3.5-dev.

## Additional Information

- Real-world origin: haproxy-ingress (kubernetes) in front of Spring Boot / Jetty 12 pods
  over h2c; the Spring 7.0.5 regression made every Content-Length response from those pods
  take the split-END_STREAM shape, and every response through the ingress gained ~200 ms.
  Spring-side report: spring-projects/spring-framework#37042 (a Spring fix restores the
  single-flush pattern, but the haproxy behavior remains triggerable by any h2 backend that
  splits its stream termination).
- The delay is invisible in haproxy logs except as `Ti`/`Tq` of the following request;
  `Ta`/`Tr` of the affected response look healthy.
