package com.github._4.issue;

import java.util.List;
import org.springframework.core.MethodParameter;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.http.converter.HttpMessageConverter;
import org.springframework.http.server.ServerHttpRequest;
import org.springframework.http.server.ServerHttpResponse;
import org.springframework.web.bind.annotation.ControllerAdvice;
import org.springframework.web.servlet.mvc.method.annotation.ResponseBodyAdvice;

/**
 * Models a response pipeline that reads RESPONSE headers.
 */
@ControllerAdvice
public class ReadResponseHeadersAdvice implements ResponseBodyAdvice<Object> {

  @SuppressWarnings("unused")
  private static volatile long sink;

  @Override
  public boolean supports(MethodParameter returnType, Class<? extends HttpMessageConverter<?>> converterType) {
    return true;
  }

  @Override
  public Object beforeBodyWrite(Object body, MethodParameter returnType, MediaType contentType,
      Class<? extends HttpMessageConverter<?>> converterType, ServerHttpRequest request,
      ServerHttpResponse response) {
    int responseHeaderReads = parseResponseHeaderReads(request.getURI().getQuery());
    if (responseHeaderReads <= 0) {
      return body;
    }
    HttpHeaders headers = response.getHeaders();
    long acc = 0;
    for (int i = 0; i < responseHeaderReads; i++) {
      for (String name : headers.headerNames()) {
        List<String> values = headers.get(name);
        if (values != null) {
          for (String v : values) {
            acc += v.length();
          }
        }
      }
    }
    sink = acc;
    return body;
  }

  private static int parseResponseHeaderReads(String query) {
    if (query == null) {
      return 0;
    }
    for (String part : query.split("&")) {
      if (part.startsWith("responseHeaderReads=")) {
        try {
          return Integer.parseInt(part.substring("responseHeaderReads=".length()));
        } catch (NumberFormatException e) {
          return 0;
        }
      }
    }
    return 0;
  }
}
