import org.eclipse.jetty.ee11.servlet.ServletContextHandler;
import org.eclipse.jetty.ee11.servlet.ServletHolder;
import org.eclipse.jetty.http2.server.HTTP2CServerConnectionFactory;
import org.eclipse.jetty.server.HttpConfiguration;
import org.eclipse.jetty.server.HttpConnectionFactory;
import org.eclipse.jetty.server.Server;
import org.eclipse.jetty.server.ServerConnector;

/**
 * Embedded Jetty (ee11, h2c) serving the two servlets from ReproServlets.
 *
 * Jetty uses the application content length for last-write detection only when it is set
 * via setContentLengthLong (the sole caller of HttpOutput#setApplicationContentLength);
 * a Content-Length set via setHeader stays a plain header field. Observed framing:
 *
 *   GET /setcontentlength  ->  HEADERS + DATA(4096, END_STREAM)               (one flush)
 *   GET /setheader         ->  HEADERS + DATA(4096) + DATA(0, END_STREAM)     (split; the
 *                              stream is terminated at request completion with a separate
 *                              empty frame)
 *
 * Observe with:  nghttp -nv "http://127.0.0.1:8080/setcontentlength"
 *                nghttp -nv "http://127.0.0.1:8080/setheader"
 */
public class JettyEE11Main {

  public static void main(String[] args) throws Exception {
    Server server = new Server();
    ServerConnector connector = new ServerConnector(
        server,
        new HttpConnectionFactory(),
        new HTTP2CServerConnectionFactory(new HttpConfiguration()));
    connector.setPort(Integer.getInteger("port", 8080));
    server.addConnector(connector);

    ServletContextHandler context = new ServletContextHandler("/");
    context.addServlet(new ServletHolder(ReproServlets.setContentLengthServlet()), "/setcontentlength");
    context.addServlet(new ServletHolder(ReproServlets.setHeaderServlet()), "/setheader");
    server.setHandler(context);

    server.start();
    server.join();
  }
}
