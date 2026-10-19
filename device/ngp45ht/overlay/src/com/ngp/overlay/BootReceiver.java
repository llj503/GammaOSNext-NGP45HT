package com.ngp.overlay;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

/** 开机自动拉起悬浮窗服务。 */
public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context ctx, Intent intent) {
        String a = intent == null ? null : intent.getAction();
        if (Intent.ACTION_BOOT_COMPLETED.equals(a)
                || Intent.ACTION_MY_PACKAGE_REPLACED.equals(a)) {
            try {
                Intent i = new Intent(ctx, OverlayService.class);
                ctx.startService(i);
                Log.i("ngp-overlay", "boot: service start requested");
            } catch (Throwable t) {
                Log.w("ngp-overlay", "boot start failed: " + t);
            }
        }
    }
}
