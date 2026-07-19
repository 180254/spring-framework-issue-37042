package com.github._4.issue;

import java.io.ByteArrayInputStream;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import org.springframework.core.io.InputStreamResource;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestMethod;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.context.request.async.DeferredResult;

/**
 * Reproducer for the HTTP/2 END_STREAM split introduced by Spring Framework 7.0.5.
 *
 * Since 7.0.5, ServletServerHttpResponse writes Content-Length only as a plain header
 * (HttpServletResponse#setHeader/addHeader) and never calls
 * HttpServletResponse#setContentLengthLong.
 * Jetty tracks the application content length exclusively through setContentLengthLong
 * (ee11 HttpOutput#_applicationContentLength), so the final body write is no longer
 * recognized as the last one: the response is flushed as DATA without END_STREAM and the
 * stream is terminated later, at request completion, with a separate empty DATA frame.
 *
 * The response shape mirrors the production service: ResponseEntity of InputStreamResource
 * with an explicit Content-Length, optionally completed through a DeferredResult so the
 * body is written on an async dispatch (as in the real service).
 */
@RestController
public class EndStreamController {

  private static final ExecutorService COMPLETER = Executors.newSingleThreadExecutor();

  @RequestMapping(path = "/endstream", method = {RequestMethod.GET, RequestMethod.POST})
  public Object endstream(
      @RequestParam(name = "bytes", defaultValue = "8192") int bytes,
      @RequestParam(name = "async", defaultValue = "false") boolean async,
      @RequestParam(name = "contentLength", defaultValue = "true") boolean contentLength,
      @RequestParam(name = "json", defaultValue = "false") boolean json,
      @RequestParam(name = "gzipCe", defaultValue = "false") boolean gzipCe) {
    if (!async) {
      return response(bytes, contentLength, json, gzipCe);
    }
    DeferredResult<ResponseEntity<InputStreamResource>> result = new DeferredResult<>(35_000L);
    COMPLETER.execute(() -> result.setResult(response(bytes, contentLength, json, gzipCe)));
    return result;
  }

  // contentLength=false mirrors the production branch taken when the client did not send
  // Accept-Encoding: gzip: the body is streamed and no Content-Length is ever known.
  // json=true mirrors the production Content-Type (application/json;charset=UTF-8), which is in
  // the server.compression mime list; gzipCe=true mirrors the pre-compressed production branch.
  private ResponseEntity<InputStreamResource> response(
      int bytes, boolean contentLength, boolean json, boolean gzipCe) {
    byte[] body = new byte[bytes];
    HttpHeaders headers = new HttpHeaders();
    headers.setContentType(json
        ? MediaType.parseMediaType("application/json;charset=UTF-8")
        : MediaType.APPLICATION_OCTET_STREAM);
    if (gzipCe) {
      headers.set(HttpHeaders.CONTENT_ENCODING, "gzip");
    }
    if (contentLength) {
      headers.setContentLength(body.length);
    }
    return new ResponseEntity<>(
        new InputStreamResource(new ByteArrayInputStream(body)), headers, HttpStatus.OK);
  }
}
