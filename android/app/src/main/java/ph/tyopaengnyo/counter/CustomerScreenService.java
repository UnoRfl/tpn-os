package ph.tyopaengnyo.counter;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.hardware.display.DisplayManager;
import android.net.Uri;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.provider.Settings;
import android.view.Display;
import android.view.WindowManager;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.Locale;

/**
 * Keeps the customer screen on the iMin's second display, whatever is in
 * front on the main one (the app, or Chrome).
 *
 * Two ways in:
 *  - the app's own WebView calls {@link #deliver} through window.TPNCounter;
 *  - Chrome (used when the device's WebView is too old for the counter)
 *    POSTs to http://127.0.0.1:8091/state, the same way it already talks to
 *    the iMin print plugin on 8081. Loopback only, so it works offline and
 *    nothing outside the device can reach it.
 *
 * The window is TYPE_APPLICATION_OVERLAY, so it needs "Display over other
 * apps" (MainActivity asks once).
 */
public class CustomerScreenService extends Service {
    static final int PORT = 8091;
    private static final int MAX_BODY = 64 * 1024;
    private static final int MAX_PRINT = 2 * 1024 * 1024;
    private static final String CHANNEL = "customer_screen";
    private static volatile CustomerScreenService self;

    private final Handler main = new Handler(Looper.getMainLooper());
    private CustomerPresentation presentation;
    private DisplayManager displays;
    private ServerSocket server;
    private volatile String last;
    private String allowedOrigin;

    private final DisplayManager.DisplayListener displayListener = new DisplayManager.DisplayListener() {
        @Override public void onDisplayAdded(int id) { showCustomer(); }
        @Override public void onDisplayRemoved(int id) { showCustomer(); }
        @Override public void onDisplayChanged(int id) { }
    };

    static void start(Context c) {
        try { c.startForegroundService(new Intent(c, CustomerScreenService.class)); } catch (Exception ignored) { }
    }

    /** From the app's WebView (any thread). */
    static void deliver(String json) {
        CustomerScreenService s = self;
        if (s != null) s.main.post(() -> s.push(json));
    }

    static boolean showing() {
        CustomerScreenService s = self;
        return s != null && s.presentation != null;
    }

    @Override
    public void onCreate() {
        super.onCreate();
        self = this;
        Uri site = Uri.parse(MainActivity.SITE);
        // With the port when there is one: a test build pointed at a PC's copy of
        // the site (http://127.0.0.1:7071/ through adb reverse) sends "…:7071".
        allowedOrigin = site.getScheme() + "://" + site.getHost() + (site.getPort() > 0 ? ":" + site.getPort() : "");
        startForeground(1, notification());
        displays = getSystemService(DisplayManager.class);
        displays.registerDisplayListener(displayListener, main);
        showCustomer();
        startServer();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        showCustomer();   // e.g. after "Display over other apps" was just allowed
        return START_STICKY;
    }

    @Override
    public IBinder onBind(Intent intent) { return null; }

    @Override
    public void onDestroy() {
        self = null;
        try { if (server != null) server.close(); } catch (Exception ignored) { }
        if (displays != null) displays.unregisterDisplayListener(displayListener);
        if (presentation != null) presentation.dismiss();
        presentation = null;
        super.onDestroy();
    }

    private Notification notification() {
        NotificationManager nm = getSystemService(NotificationManager.class);
        nm.createNotificationChannel(new NotificationChannel(CHANNEL, "Customer screen", NotificationManager.IMPORTANCE_MIN));
        return new Notification.Builder(this, CHANNEL)
                .setSmallIcon(android.R.drawable.ic_menu_slideshow)
                .setContentTitle("Customer screen is on")
                .setOngoing(true)
                .build();
    }

    private void showCustomer() {
        Display[] ds = displays.getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION);
        Display d = ds.length > 0 ? ds[0] : null;
        if (presentation != null && (d == null || presentation.getDisplay().getDisplayId() != d.getDisplayId())) {
            presentation.dismiss();
            presentation = null;
        }
        if (d == null || presentation != null || !Settings.canDrawOverlays(this)) return;
        CustomerPresentation p = new CustomerPresentation(this, d, MainActivity.CUSTOMER);
        p.getWindow().setType(WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY);
        try {
            p.show();
            presentation = p;
            if (last != null) p.deliver(last);
        } catch (Exception e) {
            presentation = null;
        }
    }

    private void push(String json) {
        last = json;
        if (presentation != null) presentation.deliver(json);
    }

    /* ── The local link for Chrome ───────────────────────────── */

    private void startServer() {
        Thread t = new Thread(() -> {
            try {
                server = new ServerSocket(PORT, 8, InetAddress.getByName("127.0.0.1"));
                while (!server.isClosed()) {
                    Socket s = server.accept();
                    new Thread(() -> handle(s), "cds-conn").start();
                }
            } catch (Exception ignored) { }
        }, "cds-server");
        t.setDaemon(true);
        t.start();
    }

    private void handle(Socket s) {
        try (Socket sock = s) {
            sock.setSoTimeout(5000);
            InputStream in = sock.getInputStream();
            String head = readHead(in);
            if (head == null) return;
            String[] lines = head.split("\r\n");
            String[] req = lines[0].split(" ");
            if (req.length < 2) return;
            String method = req[0], path = req[1];
            String origin = null;
            int length = 0;
            for (int i = 1; i < lines.length; i++) {
                int c = lines[i].indexOf(':');
                if (c < 0) continue;
                String k = lines[i].substring(0, c).trim().toLowerCase(Locale.ROOT), v = lines[i].substring(c + 1).trim();
                if (k.equals("origin")) origin = v;
                if (k.equals("content-length")) try { length = Integer.parseInt(v); } catch (NumberFormatException ignored) { }
            }
            OutputStream out = sock.getOutputStream();
            // Only our own site (or no Origin at all for nothing but /ping).
            boolean ours = allowedOrigin.equals(origin);
            if (method.equals("OPTIONS")) { reply(out, 204, origin, ours, ""); return; }
            if (method.equals("GET") && path.startsWith("/ping")) {
                reply(out, 200, origin, ours, "{\"ok\":true,\"print\":true,\"screen\":" + (presentation != null) + "}");
                return;
            }
            if (method.equals("POST") && path.startsWith("/state") && ours && length > 0 && length <= MAX_BODY) {
                byte[] body = new byte[length];
                int got = 0;
                while (got < length) { int n = in.read(body, got, length - got); if (n < 0) break; got += n; }
                String json = new String(body, 0, got, StandardCharsets.UTF_8);
                if (json.startsWith("{")) main.post(() -> push(json));
                reply(out, 204, origin, ours, "");
                return;
            }
            if (method.equals("POST") && path.startsWith("/print") && ours && length > 0 && length <= MAX_PRINT) {
                String err = print(path, in, length);
                reply(out, err == null ? 200 : 502, origin, ours, err == null ? "{\"ok\":true}" : "{\"ok\":false,\"error\":\"" + err + "\"}");
                return;
            }
            reply(out, ours ? 404 : 403, origin, ours, "");
        } catch (Exception ignored) { }
    }

    /* ── Network printer (the kitchen printer) ─────────────────
       The page can't open a raw socket, so it POSTs the printer's own
       ESC/POS bytes to /print?host=192.168.1.50&port=9100 and this
       passes them on. Only printers on the restaurant's own network
       (private IPv4 addresses) and the raw print ports 9100–9109. */
    private static String print(String path, InputStream in, int length) {
        Uri q = Uri.parse("http://x" + path);
        String host = q.getQueryParameter("host");
        int port;
        try { port = Integer.parseInt(q.getQueryParameter("port") == null ? "9100" : q.getQueryParameter("port")); } catch (NumberFormatException e) { return "bad port"; }
        if (host == null || !isLan(host)) return "not a printer on this network";
        if (port < 9100 || port > 9109) return "bad port";
        try {
            byte[] body = new byte[length];
            int got = 0;
            while (got < length) { int n = in.read(body, got, length - got); if (n < 0) break; got += n; }
            if (got < length) return "incomplete";
            try (Socket p = new Socket()) {
                p.connect(new InetSocketAddress(host, port), 4000);
                p.setSoTimeout(8000);
                OutputStream o = p.getOutputStream();
                o.write(body, 0, got);
                o.flush();
            }
            return null;
        } catch (java.net.SocketTimeoutException e) {
            return "printer did not answer";
        } catch (Exception e) {
            return "could not reach the printer";
        }
    }

    static boolean isLan(String host) {
        String[] p = host.split("\\.");
        if (p.length != 4) return false;
        int[] n = new int[4];
        try { for (int i = 0; i < 4; i++) { n[i] = Integer.parseInt(p[i]); if (n[i] < 0 || n[i] > 255 || !p[i].equals(String.valueOf(n[i]))) return false; } }
        catch (NumberFormatException e) { return false; }
        return n[0] == 10 || (n[0] == 172 && n[1] >= 16 && n[1] <= 31) || (n[0] == 192 && n[1] == 168);
    }

    private static String readHead(InputStream in) throws java.io.IOException {
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        int prev3 = 0, c;
        while ((c = in.read()) >= 0) {
            b.write(c);
            prev3 = ((prev3 << 8) | c) & 0xFFFFFFFF;
            if (prev3 == 0x0D0A0D0A) return b.toString("UTF-8");
            if (b.size() > 8192) return null;
        }
        return null;
    }

    private static void reply(OutputStream out, int code, String origin, boolean ours, String body) throws java.io.IOException {
        byte[] data = body.getBytes(StandardCharsets.UTF_8);
        StringBuilder h = new StringBuilder("HTTP/1.1 ").append(code).append(code == 200 ? " OK" : code == 204 ? " No Content" : " Error").append("\r\n");
        if (ours) {
            h.append("Access-Control-Allow-Origin: ").append(origin).append("\r\n")
             .append("Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n")
             .append("Access-Control-Allow-Headers: content-type\r\n")
             .append("Access-Control-Allow-Private-Network: true\r\n")
             .append("Vary: Origin\r\n");
        }
        h.append("Content-Type: application/json\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: ").append(data.length).append("\r\n\r\n");
        out.write(h.toString().getBytes(StandardCharsets.UTF_8));
        out.write(data);
        out.flush();
    }
}
