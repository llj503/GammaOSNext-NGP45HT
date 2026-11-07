package com.ngp;

import android.content.Context;
import android.os.Looper;
import android.widget.Toast;
import java.lang.reflect.Method;

public final class ToastMain {
    public static void main(String[] args) {
        String text = args.length > 0 ? args[0] : "鼠标模式";
        try {
            Looper.prepareMainLooper();
            Class<?> atClass = Class.forName("android.app.ActivityThread");
            Object at = atClass.getMethod("systemMain").invoke(null);
            Context ctx = (Context) atClass.getMethod("getSystemContext").invoke(at);

            // The process starts as root (app_process); the system context is
            // package "android" (uid 1000). Drop to uid 1000 before showing the
            // toast so NotificationManager's package/uid check passes.
            Method setUid = Class.forName("android.os.Process")
                    .getDeclaredMethod("setUid", int.class);
            setUid.invoke(null, 1000);

            Toast.makeText(ctx, text, Toast.LENGTH_SHORT).show();
            Thread.sleep(2200);
        } catch (Throwable t) {
            t.printStackTrace();
        }
    }
}
