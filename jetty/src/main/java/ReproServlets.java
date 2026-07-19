import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;

/**
 * The two servlets under test, shared by the Jetty and Tomcat mains. They are identical
 * except for how the content length is communicated to the container:
 *
 *   /setcontentlength - HttpServletResponse#setContentLengthLong(4096)
 *   /setheader        - HttpServletResponse#setHeader("Content-Length", "4096")
 *
 * Both write a 4096-byte body and call flushBuffer(), which is what web frameworks
 * typically do after writing a response body (e.g. Spring MVC). On Jetty, with a known
 * content length the final write is already the last write and the flush is a no-op;
 * without it the flush sends the body as a non-last DATA frame. Responses larger than the
 * output aggregation buffer split the same way even without an explicit flush. (Tomcat
 * computes END_OF_STREAM at flush time instead, so the distinction does not arise there.)
 *
 * On Jetty (ee10/ee11) the two servlets produce byte-identical response headers but
 * different HTTP/2 framing (see JettyEE11Main/JettyEE10Main); on Tomcat both behave the
 * same (see TomcatMain).
 */
public final class ReproServlets {

  static final int BODY_SIZE = 4096;

  private ReproServlets() {
  }

  public static HttpServlet setContentLengthServlet() {
    return new HttpServlet() {
      @Override
      protected void doGet(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        byte[] body = new byte[BODY_SIZE];
        resp.setContentType("application/octet-stream");
        resp.setContentLengthLong(body.length);
        resp.getOutputStream().write(body);
        resp.flushBuffer();
      }
    };
  }

  public static HttpServlet setHeaderServlet() {
    return new HttpServlet() {
      @Override
      protected void doGet(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        byte[] body = new byte[BODY_SIZE];
        resp.setContentType("application/octet-stream");
        resp.setHeader("Content-Length", String.valueOf(body.length));
        resp.getOutputStream().write(body);
        resp.flushBuffer();
      }
    };
  }
}
