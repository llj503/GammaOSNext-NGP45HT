package com.ngp.overlay;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import android.widget.Toast;

/**
 * 无界面启动器：处理操作，拉起/切换悬浮窗后立刻 finish。
 *
 * - 点应用图标 / am start ... .ToggleActivity  → 打开；已在运行则切换显示/隐藏
 * - ACTION_VIEW 带数据（file:// 形式可从启动器直接传参）→ 同样走切换
 */
public class ToggleActivity extends Activity {

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        // 悬浮窗权限没给时先引导授权，否则 addView 一定失败
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(this)) {
            Toast.makeText(this, "请先允许「显示在其他应用上层」", Toast.LENGTH_LONG).show();
            try {
                startActivity(new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        Uri.parse("package:" + getPackageName()))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            } catch (Throwable ignored) {
            }
            finish();
            return;
        }
        try {
            Intent i = new Intent(this, OverlayService.class);
            i.setAction("toggle");
            startService(i);
        } catch (Throwable ignored) {
        }
        finish();
    }
}
