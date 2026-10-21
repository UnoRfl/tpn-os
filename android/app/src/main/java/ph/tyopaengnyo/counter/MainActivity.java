package ph.tyopaengnyo.counter;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Bundle;
import android.provider.Settings;
import android.view.View;
import android.view.WindowManager;
import android.webkit.CookieManager;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.widget.EditText;

import org.mozilla.geckoview.AllowOrDeny;
import org.mozilla.geckoview.GeckoResult;
import org.mozilla.geckoview.GeckoRuntime;
import org.mozilla.geckoview.GeckoRuntimeSettings;
import org.mozilla.geckoview.GeckoSession;
import org.mozilla.geckoview.GeckoSessionSettings;
import org.mozilla.geckoview.GeckoView;
import org.mozilla.geckoview.WebRequestError;

/**
 * TPN OS, all in one app.
 *
 * It opens on the staff portal (sign-in required); Floor & Counter and the
 * kitchen station open in the same window, as parts of the same system.
 * The front screen runs on GeckoView, a modern
 * web engine bundled in the APK, so it no longer depends on the device's
 * Android System WebView (the D4-504 ships 83; TPN OS needs 87+).
 *
 * The back screen is {@link CustomerScreenService}: the customer page on the
 * system WebView (it is written to run there) on the second display. The
 * counter page reaches it over the service's loopback link (127.0.0.1:8091),
 * the same way it reaches the iMin print plugin (127.0.0.1:8081).
 */
public class MainActivity extends Activity {
    static final String SITE = BuildConfig.SITE_URL;            // ends with '/'
    static final String COUNTER = SITE + "tpn-dine-in-floor";
    static final String CUSTOMER = SITE + "tpn-dine-in-floor-customer";
    static final String PORTAL = SITE + "portal";
    private static final int PERM_REQ = 7;

    private static GeckoRuntime runtime;
    private GeckoView view;
    private GeckoSession session;
    private boolean canGoBack, askedOverlay, started;
    private AlertDialog overlayDialog;
    private GeckoSession.PermissionDelegate.Callback pendingPerms;

    /** Settings for the back screen's WebView (CustomerPresentation). */
    @SuppressLint("SetJavaScriptEnabled")
    static void configure(WebView w) {
        WebSettings s = w.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setDatabaseEnabled(true);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE);
        CookieManager.getInstance().setAcceptCookie(true);
    }

    /** Only the site itself loads inside the app; any other link opens in the browser. */
    static boolean isSite(Uri u) {
        Uri site = Uri.parse(SITE);
        return u != null && "https".equals(u.getScheme()) && site.getHost().equals(u.getHost())
                && u.getPath() != null && u.getPath().startsWith(site.getPath());
    }

    private boolean adbOn() {
        return Settings.Global.getInt(getContentResolver(), Settings.Global.ADB_ENABLED, 0) == 1;
    }

    /** One engine per app process. */
    private GeckoRuntime runtime() {
        if (runtime == null) {
            runtime = GeckoRuntime.create(getApplicationContext(), new GeckoRuntimeSettings.Builder()
                    .remoteDebuggingEnabled(adbOn())   // about:debugging, only while USB debugging is on
                    .build());
        }
        return runtime;
    }

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        proceed();
    }

    @Override
    protected void onResume() {
        super.onResume();
        proceed();   // back from the "Display over other apps" screen
    }

    private void proceed() {
        if (overlayDialog != null && overlayDialog.isShowing()) return;   // waiting for an answer
        // The back screen floats over the counter, so it needs this once.
        if (!Settings.canDrawOverlays(this) && !askedOverlay) {
            askedOverlay = true;
            overlayDialog = new AlertDialog.Builder(this)
                    .setTitle("Allow the customer screen")
                    .setMessage("TPN Counter shows the guest's order on the back screen. Turn on \"Allow display over other apps\" for TPN Counter on the next screen, then come back.")
                    .setPositiveButton("Open setting", (d, w) -> {
                        try { startActivity(new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:" + getPackageName()))); }
                        catch (Exception e) { startActivity(new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION)); }
                    })
                    .setNegativeButton("Not now", (d, w) -> proceed())
                    .setCancelable(false)
                    .show();
            return;
        }
        CustomerScreenService.start(this);
        if (started) return;
        started = true;
        openCounter();
    }

    private void openCounter() {
        view = new GeckoView(this);
        setContentView(view);
        immersive();
        newSession();
    }

    private void newSession() {
        if (session != null) { try { session.close(); } catch (Exception ignored) { } }
        session = new GeckoSession(new GeckoSessionSettings.Builder().usePrivateMode(false).build());

        session.setNavigationDelegate(new GeckoSession.NavigationDelegate() {
            @Override
            public void onCanGoBack(GeckoSession s, boolean can) { canGoBack = can; }

            // No internet when the app opens: the portal can't load, but the counter
            // works offline (its service worker), so go there instead.
            @Override
            public GeckoResult<String> onLoadError(GeckoSession s, String uri, WebRequestError error) {
                if (uri != null && uri.startsWith(PORTAL)) runOnUiThread(() -> s.loadUri(COUNTER));
                return null;
            }

            @Override
            public GeckoResult<AllowOrDeny> onLoadRequest(GeckoSession s, LoadRequest r) {
                Uri u = Uri.parse(r.uri);
                if (isSite(u)) {
                    // The portal opens Floor & Counter and the kitchen "in a new tab": here, same window.
                    if (r.target == TARGET_WINDOW_NEW) { s.loadUri(r.uri); return GeckoResult.fromValue(AllowOrDeny.DENY); }
                    return GeckoResult.fromValue(AllowOrDeny.ALLOW);
                }
                if ("about".equals(u.getScheme())) return GeckoResult.fromValue(AllowOrDeny.ALLOW);
                try { startActivity(new Intent(Intent.ACTION_VIEW, u)); } catch (Exception ignored) { }
                return GeckoResult.fromValue(AllowOrDeny.DENY);
            }
        });

        session.setPermissionDelegate(new GeckoSession.PermissionDelegate() {
            @Override
            public void onAndroidPermissionsRequest(GeckoSession s, String[] permissions, Callback callback) {
                boolean all = true;
                if (permissions != null) for (String p : permissions) all &= checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED;
                if (all) { callback.grant(); return; }
                pendingPerms = callback;
                requestPermissions(permissions, PERM_REQ);
            }

            @Override
            public void onMediaPermissionRequest(GeckoSession s, String uri, MediaSource[] video, MediaSource[] audio, MediaCallback callback) {
                // Clock-in photo: the camera, only for our own site; never the microphone.
                if (video != null && video.length > 0 && isSite(Uri.parse(uri))) callback.grant(video[0], null);
                else callback.reject();
            }

            @Override
            public GeckoResult<Integer> onContentPermissionRequest(GeckoSession s, ContentPermission perm) {
                boolean ok = isSite(Uri.parse(perm.uri))
                        && (perm.permission == PERMISSION_AUTOPLAY_AUDIBLE || perm.permission == PERMISSION_AUTOPLAY_INAUDIBLE
                            || perm.permission == PERMISSION_PERSISTENT_STORAGE);
                return GeckoResult.fromValue(ok ? ContentPermission.VALUE_ALLOW : ContentPermission.VALUE_DENY);
            }
        });

        session.setPromptDelegate(new GeckoSession.PromptDelegate() {
            @Override
            public GeckoResult<PromptResponse> onAlertPrompt(GeckoSession s, AlertPrompt p) {
                GeckoResult<PromptResponse> res = new GeckoResult<>();
                new AlertDialog.Builder(MainActivity.this).setTitle(p.title).setMessage(p.message)
                        .setPositiveButton("OK", (d, w) -> res.complete(p.dismiss()))
                        .setOnCancelListener(d -> res.complete(p.dismiss()))
                        .show();
                return res;
            }

            @Override
            public GeckoResult<PromptResponse> onButtonPrompt(GeckoSession s, ButtonPrompt p) {
                GeckoResult<PromptResponse> res = new GeckoResult<>();
                new AlertDialog.Builder(MainActivity.this).setTitle(p.title).setMessage(p.message)
                        .setPositiveButton("OK", (d, w) -> res.complete(p.confirm(ButtonPrompt.Type.POSITIVE)))
                        .setNegativeButton("Cancel", (d, w) -> res.complete(p.confirm(ButtonPrompt.Type.NEGATIVE)))
                        .setOnCancelListener(d -> res.complete(p.dismiss()))
                        .show();
                return res;
            }

            @Override
            public GeckoResult<PromptResponse> onTextPrompt(GeckoSession s, TextPrompt p) {
                GeckoResult<PromptResponse> res = new GeckoResult<>();
                EditText input = new EditText(MainActivity.this);
                if (p.defaultValue != null) input.setText(p.defaultValue);
                new AlertDialog.Builder(MainActivity.this).setTitle(p.title).setMessage(p.message).setView(input)
                        .setPositiveButton("OK", (d, w) -> res.complete(p.confirm(input.getText().toString())))
                        .setNegativeButton("Cancel", (d, w) -> res.complete(p.dismiss()))
                        .setOnCancelListener(d -> res.complete(p.dismiss()))
                        .show();
                return res;
            }
        });

        session.setContentDelegate(new GeckoSession.ContentDelegate() {
            // The page's process died (low memory): start a fresh one. The ticket and
            // the offline outbox are in the site's storage, so nothing is lost.
            @Override public void onCrash(GeckoSession s) { runOnUiThread(MainActivity.this::newSession); }
            @Override public void onKill(GeckoSession s) { runOnUiThread(MainActivity.this::newSession); }
        });

        session.open(runtime());
        view.setSession(session);
        session.loadUri(PORTAL);
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
        if (focus && view != null) immersive();
    }

    @Override
    public void onRequestPermissionsResult(int code, String[] perms, int[] results) {
        if (code != PERM_REQ || pendingPerms == null) return;
        boolean all = results.length > 0;
        for (int r : results) all &= r == PackageManager.PERMISSION_GRANTED;
        if (all) pendingPerms.grant(); else pendingPerms.reject();
        pendingPerms = null;
    }

    @SuppressWarnings("deprecation")
    @Override
    public void onBackPressed() {
        // Back steps back inside the site; it never closes the counter.
        if (session != null && canGoBack) session.goBack();
    }

    @Override
    protected void onDestroy() {
        if (session != null) { try { session.close(); } catch (Exception ignored) { } }
        super.onDestroy();
    }
}
