package com.ngp.overlay;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** 广播切换显示/隐藏：am broadcast -a com.ngp.overlay.TOGGLE */
public class ToggleReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context ctx, Intent intent) {
        Intent i = new Intent(ctx, OverlayService.class);
        i.setAction("toggle");
        try {
            ctx.startService(i);
        } catch (Throwable ignored) {
        }
    }
}
