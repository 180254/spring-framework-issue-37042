package com.github._4.issue;

import jakarta.servlet.Filter;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.ServletRequest;
import jakarta.servlet.ServletResponse;
import jakarta.servlet.http.HttpServletRequest;
import java.io.IOException;
import java.util.List;
import org.springframework.http.HttpHeaders;
import org.springframework.http.server.ServletServerHttpRequest;
import org.springframework.stereotype.Component;

/**
 * Models a response pipeline that reads REQUEST headers.
 */
@Component
public class ReadRequestHeadersFilter implements Filter {

  @SuppressWarnings("unused")
  private static volatile long sink;

  @Override
  public void doFilter(ServletRequest request, ServletResponse response, FilterChain chain)
      throws IOException, ServletException {
    int requestHeaderReads = parse(request.getParameter("requestHeaderReads"));
    if (requestHeaderReads > 0 && request instanceof HttpServletRequest httpRequest) {
      HttpHeaders headers = new ServletServerHttpRequest(httpRequest).getHeaders();
      long acc = 0;
      for (int i = 0; i < requestHeaderReads; i++) {
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
    }
    chain.doFilter(request, response);
  }

  private static int parse(String value) {
    if (value == null) {
      return 0;
    }
    try {
      return Integer.parseInt(value);
    } catch (NumberFormatException e) {
      return 0;
    }
  }
}
