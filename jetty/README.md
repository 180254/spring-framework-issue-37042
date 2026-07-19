# HTTP/2: Content-Length via setHeader() ends responses with a separate empty DATA(END_STREAM) frame (unlike setContentLengthLong; ee10/ee11; differs from Tomcat)

## Jetty version(s)

12.1.11 verified in source and on the wire, on both the ee11 and ee10 environments.

## Jetty Environment

ee11 and ee10, embedded.

## HTTP version

HTTP/2 (verified on h2c; the framing logic sits above the transport, so h2 over TLS
behaves the same). HTTP/1.1 is not affected (see "What is not affected (verified)").

## Java version/vendor

openjdk version "25.0.3" 2026-04-21 LTS (Amazon Corretto 25.0.3.9.1)

## OS type/version

Ubuntu 26.04 LTS (kernel 7.0.0-28-generic)

## Description

`HttpServletResponse#setContentLengthLong` and
`HttpServletResponse#setHeader("Content-Length", ...)` produce byte-identical response
headers on the wire, but different HTTP/2 framing and a different output lifecycle:

- `setContentLengthLong(4096)`: the final body write is recognized as the last write; Jetty
  sends `HEADERS` + `DATA(4096, END_STREAM)` in one flush and the output is closed in place.
- `setHeader("Content-Length", "4096")`: the write is never recognized as last; the body is
  sent as `DATA(4096)` without END_STREAM, explicit flushes become real network flushes, and
  the stream is terminated only at request completion with a separate empty
  `DATA(0, END_STREAM)` frame (a second flush/syscall).

Expected: the two calls are equivalent - the Servlet API documents
`setContentLength`/`setContentLengthLong` as setting the Content-Length header: "Sets the
length of the content body in the response. In HTTP servlets, this method sets the HTTP
Content-Length header."
([`ServletResponse#setContentLengthLong`, Servlet 6.1 javadoc](https://jakarta.ee/specifications/servlet/6.1/apidocs/jakarta.servlet/jakarta/servlet/ServletResponse.html#setContentLengthLong%28long%29);
the [Servlet 6.0 wording](https://jakarta.ee/specifications/servlet/6.0/apidocs/jakarta.servlet/jakarta/servlet/ServletResponse.html#setContentLengthLong%28long%29)
for ee10 is identical, as is the `setContentLength(int)` javadoc.) Tomcat accordingly
produces the single-flush framing for both (see "Comparison with Tomcat" below).

The reason is that the servlet layer's "application content length" is populated only by
`setContentLengthLong`. Source links below are pinned to the release tags `jetty-12.1.11`
and (for Tomcat) `11.0.24`, not to a moving main/master branch, so the line references stay
stable:

- [`ServletApiResponse#setContentLengthLong` (line 390)](https://github.com/jetty/jetty.project/blob/jetty-12.1.11/jetty-ee11/jetty-ee11-servlet/src/main/java/org/eclipse/jetty/ee11/servlet/ServletApiResponse.java#L390-L410)
  is the **only** caller of
  [`HttpOutput#setApplicationContentLength` (line 175)](https://github.com/jetty/jetty.project/blob/jetty-12.1.11/jetty-ee11/jetty-ee11-servlet/src/main/java/org/eclipse/jetty/ee11/servlet/HttpOutput.java#L175)
  (`HttpOutput._applicationContentLength`, default -1).
- Header writes go through `ServletContextResponse.HttpFieldsWrapper`, which special-cases
  **only `CONTENT_TYPE`**: the
  [`onAddField` switch (lines 491-503)](https://github.com/jetty/jetty.project/blob/jetty-12.1.11/jetty-ee11/jetty-ee11-servlet/src/main/java/org/eclipse/jetty/ee11/servlet/ServletContextResponse.java#L491-L503)
  is `case CONTENT_TYPE -> setContentType(field); default -> super.onAddField(field);`, and
  [`onReplaceField` (lines 534-546)](https://github.com/jetty/jetty.project/blob/jetty-12.1.11/jetty-ee11/jetty-ee11-servlet/src/main/java/org/eclipse/jetty/ee11/servlet/ServletContextResponse.java#L534-L546)
  intercepts only `CONTENT_TYPE` the same way. A `Content-Length` field is stored as a
  plain header and never reaches `HttpOutput`.
- [`HttpOutput.isAllContentWritten(written)` (line 199)](https://github.com/jetty/jetty.project/blob/jetty-12.1.11/jetty-ee11/jetty-ee11-servlet/src/main/java/org/eclipse/jetty/ee11/servlet/HttpOutput.java#L199)
  therefore never becomes true, so `write()` never marks the last write
  (`last = isAllContentWritten(written)` in the write paths, e.g. lines 831 and 968),
  `flush()` performs real non-last flushes, and `HttpOutput.complete()` has to write an
  empty last buffer at request completion.
- The core layer does read the raw header - but only to validate over-writing and to build
  the response head:
  [`HttpChannelState.ChannelResponse#write` uses `getHeaders().getLongField(HttpHeader.CONTENT_LENGTH)` for error checks (line 1380)](https://github.com/jetty/jetty.project/blob/jetty-12.1.11/jetty-core/jetty-server/src/main/java/org/eclipse/jetty/server/internal/HttpChannelState.java#L1380)
  and never upgrades `last=false`, and
  [`lockedPrepareResponse` (line 1580)](https://github.com/jetty/jetty.project/blob/jetty-12.1.11/jetty-core/jetty-server/src/main/java/org/eclipse/jetty/server/internal/HttpChannelState.java#L1580-L1593)
  copies the field into the HEADERS frame (which is why the wire headers look correct in
  both cases).
- The ee10 environment contains the same logic and reproduces identically:
  [ee10 `ServletApiResponse#setContentLengthLong` (line 354)](https://github.com/jetty/jetty.project/blob/jetty-12.1.11/jetty-ee10/jetty-ee10-servlet/src/main/java/org/eclipse/jetty/ee10/servlet/ServletApiResponse.java#L354-L364)
  is again the only caller of `setApplicationContentLength`, and the
  [ee10 `HttpFieldsWrapper.onAddField` switch (lines 485-497)](https://github.com/jetty/jetty.project/blob/jetty-12.1.11/jetty-ee10/jetty-ee10-servlet/src/main/java/org/eclipse/jetty/ee10/servlet/ServletContextResponse.java#L485-L497)
  again special-cases only `CONTENT_TYPE`.

## How to reproduce

Plain-servlet reproducer (no frameworks) next to this report (the `jetty/` directory of
https://github.com/180254/spring-framework-issue-37042): a small Maven project with
three profiles - `jetty-ee11` (embedded Jetty ee11, h2c), `jetty-ee10` (the same on ee10)
and `tomcat` (embedded Tomcat 11, h2c) - running the **same two servlets**
(`ReproServlets.java`), identical except for how they set the content length. Both write a 4096-byte body and call `flushBuffer()` (which is what web
frameworks typically do after writing a body; responses larger than the output aggregation
buffer split the same way without any explicit flush). Run `./repro.sh` (requires
`nghttp`, `curl`, a JDK and Maven; uses `../mvnw` when available; Linux/macOS) to trace
all three containers, or per container:

```
mvn -Pjetty-ee11 clean compile dependency:build-classpath -Dmdep.outputFile=target/cp.txt
java -cp "target/classes:$(cat target/cp.txt)" JettyEE11Main
# other profiles: -Pjetty-ee10 -> JettyEE10Main, -Ptomcat -> TomcatMain
nghttp -nv "http://127.0.0.1:8080/setcontentlength"
nghttp -nv "http://127.0.0.1:8080/setheader"
```

Observed frames (trimmed and annotated `./repro.sh` output):

```
### container=jetty-ee11 ###
--- GET /setcontentlength ---
recv HEADERS frame <length=65, flags=0x04, stream_id=1>
recv DATA frame <length=4096, flags=0x01, stream_id=1>     <- END_STREAM on the body frame

--- GET /setheader ---
recv HEADERS frame <length=65, flags=0x04, stream_id=1>
recv DATA frame <length=4096, flags=0x00, stream_id=1>
recv DATA frame <length=0, flags=0x01, stream_id=1>        <- separate empty END_STREAM

### container=jetty-ee10 ###
(identical to jetty-ee11: single-flush for /setcontentlength, split for /setheader)

### container=tomcat ###
--- GET /setcontentlength ---
recv HEADERS frame <length=54, flags=0x04, stream_id=1>
recv DATA frame <length=4096, flags=0x01, stream_id=1>

--- GET /setheader ---
recv HEADERS frame <length=54, flags=0x04, stream_id=1>
recv DATA frame <length=4096, flags=0x01, stream_id=1>     <- same as setcontentlength
```

| container  | /setcontentlength | /setheader       |
| ---------- | ----------------- | ---------------- |
| jetty-ee11 | single-flush      | split-END_STREAM |
| jetty-ee10 | single-flush      | split-END_STREAM |
| tomcat     | single-flush      | single-flush     |

The proxy-latency measurements (see Consequences) and the full analysis of the production
incident that led here, including the haproxy mechanism, are available in
https://github.com/180254/spring-framework-issue-37042 (`part2/`).

## Consequences

1. **Protocol/efficiency**: one extra empty DATA frame and one extra flush/syscall per
   response; stream completion is deferred from the last body write to the end of the
   request lifecycle.
1. **Severe real-world latency behind proxies**: intermediaries that cork output while a
   message is incomplete deliver the response tail late. With haproxy in a standard
   kubernetes ingress setup (HTTP/1.1 towards the client, h2c towards Jetty), the last body
   bytes are sent to the client with `MSG_MORE` (backend END_STREAM not yet seen), and the
   trailing empty `DATA(0, END_STREAM)` produces no forwardable bytes for a
   Content-Length-framed h1 response - nothing uncorks the socket, and the kernel releases
   the tail only after the ~200 ms cork timeout (`tcp(7)` TCP_CORK). Measured: ~208 ms
   median per response instead of ~2 ms, on every haproxy version we tested (2.2 through
   3.4.2). A sequential client's throughput collapses accordingly.
1. **Scale of exposure**: Spring Framework >= 7.0.5 no longer calls `setContentLengthLong`
   on its Servlet response path - `Content-Length` reaches the container only via
   `setHeader`/`addHeader` (see spring-projects/spring-framework#37042). On Jetty + HTTP/2,
   effectively every Spring MVC response written through the annotated-controller /
   `ResponseEntity` path with a known Content-Length is affected (WebMvc.fn functional
   endpoints still call `setContentLengthLong` and are not affected). We hit this in
   production as a 7x throughput drop (35 -> 5 matrices/s) after a routine framework
   upgrade; the same applies to any application or framework that sets the header directly.

## What is not affected (verified)

- **HTTP/1.1**: no wire-visible difference; the split is specific to HTTP/2 stream
  termination. The h1 responses of the two servlets are byte-identical (headers and body),
  and strace shows exactly one `writev` per response for both - the deferred empty last
  write produces no bytes and no syscall on h1.
- **Under-write detection** (worth stating explicitly, since the ee-layer code suggests
  otherwise): the ee-layer
  [`HttpOutput.isContentIncomplete()` (line 193)](https://github.com/jetty/jetty.project/blob/jetty-12.1.11/jetty-ee11/jetty-ee11-servlet/src/main/java/org/eclipse/jetty/ee11/servlet/HttpOutput.java#L193)
  guard is indeed bypassed in the `setHeader` case, but the core-layer validation (the
  `ChannelResponse#write` check linked above) still detects a servlet that declares
  `Content-Length: 100` and writes only 50 bytes. Verified for both APIs and both
  protocols: a pre-commit under-write yields a 500 either way (only the error page text
  differs by detecting layer); a post-commit under-write yields a truncated response
  aborted with a connection close (h1) or `RST_STREAM` (h2) either way.

## Comparison with Tomcat

Tomcat treats the two APIs as equivalent (links pinned to the `11.0.24` tag):
[`org.apache.coyote.Response#setHeader` (line 444)](https://github.com/apache/tomcat/blob/11.0.24/java/org/apache/coyote/Response.java#L444-L456)
and
[`#addHeader` (line 465)](https://github.com/apache/tomcat/blob/11.0.24/java/org/apache/coyote/Response.java#L465-L489)
call
[`checkSpecialHeader` (line 522)](https://github.com/apache/tomcat/blob/11.0.24/java/org/apache/coyote/Response.java#L522-L542),
which parses a `Content-Length` header and routes it to `setContentLength(long)` - the
header value and the internal content-length property can never diverge. Independently,
Tomcat's HTTP/2 output
([`org.apache.coyote.http2.Stream.StreamOutputBuffer` (line 978)](https://github.com/apache/tomcat/blob/11.0.24/java/org/apache/coyote/http2/Stream.java#L978))
computes END_OF_STREAM at flush time from the stream's closed state rather than from a
per-write "last" flag, so its final body DATA frame carries END_OF_STREAM in one flush
either way. The same
application code therefore behaves optimally on Tomcat and pessimally on Jetty, which makes
the difference invisible to application developers until it surfaces as a production
latency problem.

## Why this is worth changing

Applications and frameworks reasonably treat `setHeader("Content-Length", ...)` and
`setContentLength`/`setContentLengthLong` as interchangeable - the
[Servlet API documents both methods](https://jakarta.ee/specifications/servlet/6.1/apidocs/jakarta.servlet/jakarta/servlet/ServletResponse.html#setContentLengthLong%28long%29)
as "set[ting] the HTTP Content-Length header" (quoted in full under Description), and
Tomcat honors both directions. Jetty already
special-cases `Content-Type` in exactly the right place
(`ServletContextResponse.HttpFieldsWrapper`), keeping the header field and the
servlet-layer property in sync; `Content-Length` is arguably the second header where the
container attaches semantics beyond header emission (last-write detection and the resulting
single-flush HTTP/2 termination), and it is the one currently missing from that switch.

Suggested direction: handle `CONTENT_LENGTH` in `HttpFieldsWrapper.onAddField` /
`onReplaceField` by parsing the field value and calling
`HttpOutput#setApplicationContentLength` (mirroring what `setContentLengthLong` does), and
reset it to -1 when the field is removed. The existing `isCommitted()` guard at the top of
`onAddField` already covers the post-commit case; a non-numeric value could fall through to
the default branch unchanged.
