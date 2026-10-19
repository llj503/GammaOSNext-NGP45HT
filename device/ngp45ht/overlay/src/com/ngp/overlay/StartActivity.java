package com.ngp.overlay;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;

/** 无界面启动器：把应用切到前台后拉起悬浮窗服务（绕过 Android 14 后台启动限制）。 */
public class StartActivity extends Activity {
    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        try {
            startService(new Intent(this, OverlayService.class));
        } catch (Throwable ignored) {
        }
        finish();
    }
}
