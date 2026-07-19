import org.eclipse.jetty.ee10.servlet.ServletContextHandler;
import org.eclipse.jetty.ee10.servlet.ServletHolder;
import org.eclipse.jetty.http2.server.HTTP2CServerConnectionFactory;
import org.eclipse.jetty.server.HttpConfiguration;
import org.eclipse.jetty.server.HttpConnectionFactory;
import org.eclipse.jetty.server.Server;
import org.eclipse.jetty.server.ServerConnector;

/**
 * Embedded Jetty (ee10, h2c) serving the two servlets from ReproServlets - the ee10
 * environment contains the same content-length handling as ee11 (setContentLengthLong is
 * the only caller of HttpOutput#setApplicationContentLength; the HttpFieldsWrapper switch
 * special-cases only CONTENT_TYPE), so the framing asymmetry is expected to be identical
 * to JettyEE11Main:
 *
 *   GET /setcontentlength  ->  HEADERS + DATA(4096, END_STREAM)               (one flush)
 *   GET /setheader         ->  HEADERS + DATA(4096) + DATA(0, END_STREAM)     (split)
 */
public class JettyEE10Main {

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
