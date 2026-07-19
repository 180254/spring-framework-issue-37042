# Part 2: ServletServerHttpResponse no longer calls setContentLengthLong - Jetty HTTP/2 splits END_STREAM - proxies add ~200 ms per response

This is the corrected reproducer for the throughput regression originally reported in this
issue. The first reproducer (repository root) blamed per-header CPU costs; that was wrong.
The real mechanism is a wire-protocol behavior change, invisible to CPU profiling.

## The Spring Framework issue

Up to 7.0.4, `ServletServerHttpResponse.writeHeaders()` applied the buffered `Content-Length`
header to the container by calling `HttpServletResponse#setContentLengthLong(long)`.

Since 7.0.5 (gh-36334 rework), response headers are written through
`ServletResponseHeadersAdapter` directly as string headers (`setHeader`/`addHeader`), and
**`setContentLengthLong` is never called on this code path** - `Content-Length` reaches the
container only as a raw header field. This is still the case in 7.0.8 and master. (Other
Spring code paths still call it - e.g. WebMvc.fn functional endpoints via
`DefaultEntityResponseBuilder` - so functional endpoints are not affected; only the
annotated-controller / `ResponseEntity` path that writes through `ServletServerHttpResponse`
is.)

On Jetty 12 (ee11) this changes the HTTP/2 framing of every response whose Content-Length is
known to Spring. Jetty learns the "application content length" exclusively through
`ServletApiResponse#setContentLengthLong` -> `HttpOutput#setApplicationContentLength`; raw
header fields are not inspected (Jetty's `ServletContextResponse.HttpFieldsWrapper` intercepts
only `Content-Type`). Without it, `HttpOutput.isAllContentWritten()` never becomes true, so
the final body write is not marked *last*:

- Spring \<= 7.0.4: one flush, `HEADERS` + `DATA(N, END_STREAM)`.
- Spring >= 7.0.5: two flushes, `HEADERS` + `DATA(N)` ... then, at request completion, a
  separate empty `DATA(0, END_STREAM)` (`HttpOutput.complete()` writes an empty last buffer).

The response headers on the wire are identical in both cases; only the DATA framing and flush
pattern differ. A further side effect beyond the extra frame: Spring's trailing `flush()`
calls become real network flushes instead of no-ops.

## Why this costs ~200 ms per response behind a proxy (our production observation)

Our service sits behind haproxy (kubernetes haproxy-ingress: HTTP/1.1 towards the client, h2c
towards the pod). haproxy forwards response bytes to the client with `MSG_MORE` while the
backend message is incomplete (`htx_expect_more()`: no EOM seen). With the split framing, the
send carrying the last body bytes is always flagged `MSG_MORE`, so the kernel corks the final
partial TCP segment. The trailing empty `DATA(0, END_STREAM)` then produces **zero output
bytes** for a Content-Length-framed h1 response (haproxy's mux_h1 silently drops the internal
EOT block for non-chunked messages), so no further `send()` happens and nothing uncorks the
socket. The kernel releases the tail only after the cork timeout (~200 ms, see `tcp(7)`
TCP_CORK). strace of haproxy shows the smoking gun: `sendto(..., MSG_MORE) = N` followed by
no further syscall on the client socket; the client receives the response ~208 ms later.

haproxy's own accounting never sees the delay (its timers stop at the successful `send()`);
in haproxy logs it appears as a large idle time (`Ti`/`Tq` ~ 208-254 ms) before the *next*
request on the keep-alive connection, while `Ta`/`Tr` of the affected response stay small.

Measured impact in our tests: a sequential closed-loop client drops from ~5-7 ms/request to
~210-225 ms/request (production overhead test: 35 -> 5 matrices/s).

## Conditions required to observe the failure (and why each one is necessary)

1. **Spring Framework >= 7.0.5** (fixed by reverting `ServletServerHttpResponse` to 7.0.4).
   Why: 7.0.4 calls `setContentLengthLong`, so Jetty marks the final body write as last and
   sends `DATA(N, END_STREAM)` in one flush - nothing left to delay.

1. **Embedded Jetty** (tested: 12.1.x ee11). Why: Jetty is the only container that learns the
   application content length exclusively via `setContentLengthLong`. Tomcat is immune twice
   over: `org.apache.coyote.Response#setHeader/addHeader` special-case `Content-Length` into
   `setContentLength` internally, and Tomcat's h2 output computes END_OF_STREAM at flush time
   from stream state rather than from a per-write "last" flag.

1. **HTTP/2 between the application and its immediate peer** (h2c in our deployment). Why: on
   HTTP/1.1 the response is already fully framed by Content-Length, and the late empty last
   write emits zero bytes - the wire is byte-identical in both Spring versions. Only on h2
   does stream termination (END_STREAM) have to travel as its own frame.

1. **A response whose Content-Length is known to Spring** (set on the `ResponseEntity`
   headers, or derived by a message converter - `byte[]`, `String`, resources with known
   length; in our service: a pre-gzipped body with `HttpHeaders#setContentLength`). Why:
   without a Content-Length, *neither* version can call `setContentLengthLong`, so both
   versions produce the same split framing - there is no 7.0.4-vs-7.0.5 difference to
   observe. Additionally, the downstream amplifier disappears: a no-CL response is chunked on
   the h1 client side and its terminal `0\r\n\r\n` chunk is real bytes sent without
   `MSG_MORE`, which flushes the corked socket immediately.

1. **A proxy that corks the response tail** (haproxy in our case; the defect itself needs no
   proxy - see below). Why: with a direct h2 connection the extra empty END_STREAM frame
   arrives microseconds after the body, so the client sees no added latency (the defect is
   then only an extra frame and an extra flush/syscall). The
   proxy converts the split into ~200 ms because the CL-framed response tail is corked and
   the EOM produces no bytes to uncork it. Verified on haproxy 2.2, 2.8.22, 2.8.26, 3.0.25,
   3.2.21, 3.3.12 and 3.4.2 (all cork; `option http-no-delay` disables it; over TLS the cork
   exists on haproxy >= 2.8, because 2.8 started propagating `MSG_MORE` through the SSL send
   path). Other MSG_MORE/cork-style intermediaries are likely affected the same way.

1. **Observation method: sequential requests on a keep-alive connection.** Why: every
   response tail is delayed ~200 ms, so a closed-loop client's *next* request starts ~200 ms
   late - the effect compounds into a throughput collapse and is plainly visible in
   per-request timings (`time_starttransfer ~= time_total ~= 208 ms`). A one-shot request on
   a fresh connection often looks normal because the cork release is racy there (e.g., TLS
   session-ticket records written after the handshake flush the socket) and the delay hides
   inside DNS/TLS/WAN noise. This condition affects only observability, not existence.

In our performance test all conditions were met for every run.

## When the regression stops being visible in our tests

Any one of these makes the ~200 ms disappear:

- Spring Framework \<= 7.0.4, or 7.0.5+ with `ServletServerHttpResponse` reverted (class
  shadowing) - restores `setContentLengthLong`.
- Tomcat instead of Jetty.
- HTTP/1.1 instead of h2c between proxy and application.
- Responses without Content-Length (in our service: clients whose Accept-Encoding does not
  include gzip).
- `option http-no-delay` on the haproxy frontend/backend (disables MSG_MORE).
- (Apparent only) measuring with one-shot fresh-connection requests instead of sequential
  keep-alive requests.

## Reproducer

The application is the Maven project in the repository root (endpoint
`/endstream` in `EndStreamController`; parameters: `bytes`, `async`, `contentLength`, `json`,
`gzipCe`). The response mirrors the production shape: `ResponseEntity<InputStreamResource>`
with an explicit Content-Length, completed through a `DeferredResult` (async dispatch).

Two scripts, run from this directory:

1. `./repro-frames.sh` - the frame-level proof (no proxy needed). Requires `nghttp`, a JDK.
   Fetches `/endstream` over h2c and prints the received frames.

   Expected:

   | container | 7.0.4        | 7.0.5            | 7.0.8            | 7.0.8+shadow revert |
   | --------- | ------------ | ---------------- | ---------------- | ------------------- |
   | jetty     | single-flush | split-END_STREAM | split-END_STREAM | single-flush        |
   | tomcat    | single-flush | single-flush     | single-flush     | single-flush        |

   single-flush = `DATA(N, END_STREAM)`; split-END_STREAM = `DATA(N)` + `DATA(0, END_STREAM)`.

1. `./repro-latency.sh` - the end-to-end latency impact. Requires docker (`HAPROXY_IMAGE`,
   default `haproxy:3.5-dev`; any 2.x/3.x image reproduces it), `curl`, a JDK. Runs haproxy
   (h1 frontend, h2c backend, mirroring a kubernetes haproxy-ingress data path) and measures
   a sequential keep-alive client. Routes: direct,
   via haproxy, via haproxy with `option http-no-delay`; shapes: with and without
   Content-Length.

   Expected (median ms/request; measured values from our run):

   | version | shape | direct | haproxy  | haproxy+http-no-delay |
   | ------- | ----- | ------ | -------- | --------------------- |
   | 7.0.4   | CL    | ~1     | ~2       | ~1                    |
   | 7.0.5   | CL    | ~1     | **~208** | ~1                    |
   | 7.0.4   | no-CL | ~1     | ~2       | ~1                    |
   | 7.0.5   | no-CL | ~1     | ~2       | ~1                    |

## Suggested fix direction

Special-case `Content-Length` in the Servlet response adapter (or in `writeHeaders()`), so
that setting it through `HttpHeaders` again reaches
`HttpServletResponse#setContentLengthLong`, restoring the pre-7.0.5 container contract.

Related, for completeness: Jetty could arguably also honor the raw `Content-Length` field for
last-write detection, and haproxy could flush the client socket on backend EOM even when it
produces no output bytes (haproxy fixed the bodyless-response variant of this in March 2026,
commit `ee95a7539`; body-carrying CL responses still cork as of 3.4) - but the
version-dependent trigger is the Spring 7.0.5 change, and restoring `setContentLengthLong`
fully removes the regression.
