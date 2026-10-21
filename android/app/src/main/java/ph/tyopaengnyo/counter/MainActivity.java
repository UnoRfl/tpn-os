package ph.tyopaengnyo.counter;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Bundle;
import android.provider.Settings;
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
import android.widget.Toast;

/**
 * The counter.
 *
 * The customer screen on the iMin's second display always comes from
 * {@link CustomerScreenService}. The counter itself (the website's floor
 * screen) runs in one of two places:
 *  - here, in a full-screen WebView, when the device's Android System
 *    WebView is new enough (MIN_WEBVIEW);
 *  - in Chrome, when it isn't (the D4-504 ships WebView 83, Chrome 104).
 *    Chrome sends the customer screen its updates over the service's
 *    loopback link, so the app only has to drive the back screen.
 * When iMin updates the WebView, the app moves back in by itself.
 */
public class MainActivity extends Activity {
    static final String SITE = BuildConfig.SITE_URL;            // ends with '/'
    static final String COUNTER = SITE + "tpn-dine-in-floor";
    static final String CUSTOMER = SITE + "tpn-dine-in-floor-customer";
    /** The site needs Chrome 87-era features (2021 JavaScript, CSS `inset`). */
    static final int MIN_WEBVIEW = 87;
    private static final int CAMERA_REQ = 7;

    private WebView web;
    private PermissionRequest pendingCamera;
    private boolean askedOverlay, started;
    private AlertDialog overlayDialog;

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

    /** Major version of the device's WebView, or 0 if unknown. */
    static int webViewMajor() {
        PackageInfo wv = WebView.getCurrentWebViewPackage();
        if (wv == null || wv.versionName == null) return 0;
        try { return Integer.parseInt(wv.versionName.split("\\.")[0]); } catch (NumberFormatException e) { return 0; }
    }

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        // Remote debugging (chrome://inspect) only while USB debugging is switched on.
        WebView.setWebContentsDebuggingEnabled(Settings.Global.getInt(getContentResolver(), Settings.Global.ADB_ENABLED, 0) == 1);
        proceed(state);
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (web != null) web.onResume();
        proceed(null);   // back from the "Display over other apps" screen
    }

    private void proceed(Bundle state) {
        if (overlayDialog != null && overlayDialog.isShowing()) return;   // waiting for an answer
        // The back screen floats over whatever is in front, so it needs this once.
        if (!Settings.canDrawOverlays(this) && !askedOverlay) {
            askedOverlay = true;
            overlayDialog = new AlertDialog.Builder(this)
                    .setTitle("Allow the customer screen")
                    .setMessage("TPN Counter shows the guest's order on the back screen. Turn on \"Allow display over other apps\" for TPN Counter on the next screen, then come back.")
                    .setPositiveButton("Open setting", (d, w) -> {
                        try { startActivity(new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:" + getPackageName()))); }
                        catch (Exception e) { startActivity(new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION)); }
                    })
                    .setNegativeButton("Not now", (d, w) -> proceed(null))
                    .setCancelable(false)
                    .show();
            return;
        }
        CustomerScreenService.start(this);
        if (started) return;
        started = true;
        if (webViewMajor() >= MIN_WEBVIEW) openHere(state);
        else openInChrome();
    }

    /** Old WebView: the counter runs in Chrome; this app keeps only the back screen. */
    private void openInChrome() {
        Intent chrome = new Intent(Intent.ACTION_VIEW, Uri.parse(COUNTER)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try {
            startActivity(new Intent(chrome).setPackage("com.android.chrome"));
        } catch (Exception e) {
            try { startActivity(chrome); } catch (Exception ignored) { }
        }
        Toast.makeText(this, "Counter opened in Chrome. The customer screen stays on.", Toast.LENGTH_LONG).show();
        finish();
    }

    private void openHere(Bundle state) {
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
    }

    /** window.TPNCounter in the page (modules/customer-display.js). */
    class Bridge {
        @JavascriptInterface
        public void toCustomer(String json) { CustomerScreenService.deliver(json); }
        @JavascriptInterface
        public boolean hasCustomerScreen() { return CustomerScreenService.showing(); }
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
        if (focus && web != null) immersive();
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
        if (web != null) web.saveState(out);
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
        if (web != null && web.canGoBack()) web.goBack();
    }

    @Override
    protected void onDestroy() {
        if (web != null) web.destroy();
        super.onDestroy();
    }
}
