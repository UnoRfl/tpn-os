package ph.tyopaengnyo.counter;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * Opens the counter when the iMin powers on, so nobody has to after a
 * brown-out. Android 10+ only lets an app do this once it has "Display over
 * other apps" (Settings → Apps → TPN Counter); see GO-LIVE.md section 10.
 */
public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context c, Intent i) {
        if (!Intent.ACTION_BOOT_COMPLETED.equals(i.getAction())) return;
        CustomerScreenService.start(c);   // the back screen, even if the counter can't open by itself
        Intent open = new Intent(c, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try { c.startActivity(open); } catch (Exception ignored) { }
    }
}
