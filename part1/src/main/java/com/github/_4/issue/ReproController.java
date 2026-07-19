package com.github._4.issue;

import java.nio.charset.StandardCharsets;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * Minimal reproducer for the throughput regression (gh-36334).
 */
@RestController
public class ReproController {

  private static final byte[] BODY = "{\"status\":\"ok\"}".getBytes(StandardCharsets.UTF_8);

  @GetMapping("/repro")
  public ResponseEntity<byte[]> repro(
      @RequestParam(name = "responseHeaderCount", defaultValue = "0") int responseHeaderCount) {
    HttpHeaders responseHeaders = new HttpHeaders();
    for (int i = 0; i < responseHeaderCount; i++) {
      responseHeaders.set("X-Repro-" + i, "value-" + i);
    }
    return new ResponseEntity<>(BODY, responseHeaders, HttpStatus.OK);
  }
}
