import org.apache.catalina.Context;
import org.apache.catalina.connector.Connector;
import org.apache.catalina.startup.Tomcat;
import org.apache.coyote.http2.Http2Protocol;

/**
 * Embedded Tomcat (h2c) serving the same two servlets from ReproServlets, for comparison.
 *
 * Tomcat treats setHeader("Content-Length", ...) and setContentLengthLong as equivalent
 * (org.apache.coyote.Response#setHeader routes the header through checkSpecialHeader into
 * setContentLength), and its HTTP/2 output computes END_OF_STREAM at flush time from the
 * stream state. Observed framing - identical for both endpoints:
 *
 *   GET /setcontentlength  ->  HEADERS + DATA(4096, END_STREAM)   (one flush)
 *   GET /setheader         ->  HEADERS + DATA(4096, END_STREAM)   (one flush)
 *
 * Observe with:  nghttp -nv "http://127.0.0.1:8080/setcontentlength"
 *                nghttp -nv "http://127.0.0.1:8080/setheader"
 */
public class TomcatMain {

  public static void main(String[] args) throws Exception {
    Tomcat tomcat = new Tomcat();
    // Under target/ so mvn clean removes it (a temp dir would leak one copy per run);
    // relative paths resolve against the working directory, which repro.sh sets to the
    // project dir.
    tomcat.setBaseDir("target/tomcat-basedir");

    Connector connector = new Connector();
    connector.setPort(Integer.getInteger("port", 8080));
    connector.addUpgradeProtocol(new Http2Protocol());
    tomcat.setConnector(connector);

    Context context = tomcat.addContext("", null);
    // The servlets use no annotations; skip their annotation processing. (This does not
    // remove the need for the annotations API on the classpath: Tomcat.addContext's
    // FixContextListener scans servlet classes for @Resource regardless of this flag.)
    context.setIgnoreAnnotations(true);
    Tomcat.addServlet(context, "setcontentlength", ReproServlets.setContentLengthServlet());
    context.addServletMappingDecoded("/setcontentlength", "setcontentlength");
    Tomcat.addServlet(context, "setheader", ReproServlets.setHeaderServlet());
    context.addServletMappingDecoded("/setheader", "setheader");

    tomcat.start();
    tomcat.getServer().await();
  }
}
