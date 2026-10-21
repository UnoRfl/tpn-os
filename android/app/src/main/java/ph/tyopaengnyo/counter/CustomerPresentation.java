package ph.tyopaengnyo.counter;

import android.app.Presentation;
import android.content.Context;
import android.os.Bundle;
import android.view.Display;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import org.json.JSONObject;

/**
 * The screen on the back of the iMin: tpn-dine-in-floor-customer in its own
 * WebView. It has no buttons; it draws what the counter sends.
 *
 * The page also reads the last state from localStorage (shared with the
 * counter's WebView), so a reload or a late start shows the right thing.
 */
class CustomerPresentation extends Presentation {
    private final String url;
    private WebView web;
    private String last;

    CustomerPresentation(Context outer, Display display, String url) {
        super(outer, display);
        this.url = url;
    }

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        web = new WebView(getContext());
        MainActivity.configure(web);
        web.setWebViewClient(new WebViewClient() {
            @Override
            public void onPageFinished(WebView v, String u) { if (last != null) push(); }
        });
        setContentView(web);
        web.loadUrl(url);
    }

    void deliver(String json) {
        last = json;
        if (web != null) push();
    }

    private void push() {
        web.evaluateJavascript("window.tpnCdsReceive && tpnCdsReceive(" + JSONObject.quote(last) + ")", null);
    }

    @Override
    protected void onStop() {
        if (web != null) web.destroy();
        web = null;
        super.onStop();
    }
}
