package ph.tyopaengnyo.counter;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.hardware.display.DisplayManager;
import android.net.Uri;
import android.os.Bundle;
import android.view.Display;
import android.view.View;
import android.view.WindowManager;
import android.webkit.CookieManager;
import android.webkit.JavascriptInterface;
import android.webkit.PermissionRequest;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

/**
 * The counter: the website's floor screen, full screen, with the customer
 * screen on the iMin's second display when it has one.
 *
 * The website does all the work (orders, payments, the offline outbox and
 * its service worker). This app only adds what Chrome can't: the second
 * display, start on boot, keep the screen on, and storage Android never
 * clears on its own.
 */
public class MainActivity extends Activity {
    static final String SITE = BuildConfig.SITE_URL;            // ends with '/'
    static final String COUNTER = SITE + "tpn-dine-in-floor";
    static final String CUSTOMER = SITE + "tpn-dine-in-floor-customer";
    private static final int CAMERA_REQ = 7;

    private WebView web;
    private CustomerPresentation customer;
    private DisplayManager displays;
    private PermissionRequest pendingCamera;

    private final DisplayManager.DisplayListener displayListener = new DisplayManager.DisplayListener() {
        @Override public void onDisplayAdded(int id) { showCustomer(); }
        @Override public void onDisplayRemoved(int id) { showCustomer(); }
        @Override public void onDisplayChanged(int id) { }
    };

    /** Settings both WebViews share. Same app, same origin: they share storage too. */
    @SuppressLint("SetJavaScriptEnabled")
    static void configure(WebView w) {
        WebSettings s = w.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);            // signed-in session, offline outbox, saved ticket
        s.setDatabaseEnabled(true);
        s.setMediaPlaybackRequiresUserGesture(false);   // order chime
        // The print plugin is ws://127.0.0.1 under an https page (allowed for localhost).
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE);
        s.setSupportMultipleWindows(true);       // so onCreateWindow can refuse pop-ups
        s.setJavaScriptCanOpenWindowsAutomatically(false);
        CookieManager.getInstance().setAcceptCookie(true);
    }

    /** Only the site itself loads inside the app; any other link opens in the browser. */
    static boolean isSite(Uri u) {
        Uri site = Uri.parse(SITE);
        return u != null && "https".equals(u.getScheme()) && site.getHost().equals(u.getHost())
                && u.getPath() != null && u.getPath().startsWith(site.getPath());
    }

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        web = new WebView(this);
        configure(web);
        web.addJavascriptInterface(new Bridge(), "TPNCounter");
        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest r) {
                if (isSite(r.getUrl())) return false;
                try { startActivity(new Intent(Intent.ACTION_VIEW, r.getUrl())); } catch (Exception ignored) { }
                return true;
            }
            @Override
            public boolean onRenderProcessGone(WebView v, RenderProcessGoneDetail d) {
                // The page crashed (low memory): start over rather than die. The ticket
                // and the outbox are in storage, so nothing is lost.
                recreate();
                return true;
            }
        });
        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onCreateWindow(WebView v, boolean dialog, boolean userGesture, android.os.Message m) {
                return false;   // receipts print on the iMin printer, not in pop-ups
            }
            @Override
            public void onPermissionRequest(PermissionRequest r) {
                // Clock-in photo: the camera, only for our own site.
                boolean camera = false;
                for (String res : r.getResources()) camera |= PermissionRequest.RESOURCE_VIDEO_CAPTURE.equals(res);
                if (!camera || !isSite(r.getOrigin())) { r.deny(); return; }
                if (checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
                    r.grant(new String[]{PermissionRequest.RESOURCE_VIDEO_CAPTURE});
                } else {
                    pendingCamera = r;
                    requestPermissions(new String[]{Manifest.permission.CAMERA}, CAMERA_REQ);
                }
            }
        });
        setContentView(web);
        immersive();
        if (state == null || web.restoreState(state) == null) web.loadUrl(COUNTER);

        displays = getSystemService(DisplayManager.class);
        displays.registerDisplayListener(displayListener, null);
        showCustomer();
    }

    /** Put the customer page on the second display, if the device has one. */
    private void showCustomer() {
        Display[] ds = displays.getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION);
        Display d = ds.length > 0 ? ds[0] : null;
        if (customer != null && (d == null || customer.getDisplay().getDisplayId() != d.getDisplayId())) {
            customer.dismiss();
            customer = null;
        }
        if (d == null || customer != null) return;
        customer = new CustomerPresentation(this, d, CUSTOMER);
        try {
            customer.show();
        } catch (WindowManager.InvalidDisplayException e) {
            customer = null;
        }
    }

    /** window.TPNCounter in the page (modules/customer-display.js). */
    class Bridge {
        @JavascriptInterface
        public void toCustomer(String json) {
            runOnUiThread(() -> { if (customer != null) customer.deliver(json); });
        }
        @JavascriptInterface
        public boolean hasCustomerScreen() { return customer != null; }
    }

    @SuppressWarnings("deprecation")
    private void immersive() {
        getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                | View.SYSTEM_UI_FLAG_FULLSCREEN | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                | View.SYSTEM_UI_FLAG_LAYOUT_STABLE | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN);
    }

    @Override
    public void onWindowFocusChanged(boolean focus) {
        super.onWindowFocusChanged(focus);
        if (focus) immersive();
    }

    @Override
    public void onRequestPermissionsResult(int code, String[] perms, int[] results) {
        if (code != CAMERA_REQ || pendingCamera == null) return;
        if (results.length > 0 && results[0] == PackageManager.PERMISSION_GRANTED) {
            pendingCamera.grant(new String[]{PermissionRequest.RESOURCE_VIDEO_CAPTURE});
        } else {
            pendingCamera.deny();
        }
        pendingCamera = null;
    }

    @Override
    protected void onSaveInstanceState(Bundle out) {
        super.onSaveInstanceState(out);
        web.saveState(out);
    }

    @Override
    protected void onResume() {
        super.onResume();
        web.onResume();
        showCustomer();
    }

    @Override
    protected void onPause() {
        // Keep running: the counter must hear new orders even behind a dialog.
        super.onPause();
        CookieManager.getInstance().flush();
    }

    @SuppressWarnings("deprecation")
    @Override
    public void onBackPressed() {
        // Back steps back inside the site; it never closes the counter.
        if (web.canGoBack()) web.goBack();
    }

    @Override
    protected void onDestroy() {
        if (displays != null) displays.unregisterDisplayListener(displayListener);
        if (customer != null) customer.dismiss();
        customer = null;
        web.destroy();
        super.onDestroy();
    }
}
