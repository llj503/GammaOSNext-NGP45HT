package com.ngp.overlay;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.graphics.PixelFormat;
import android.os.Build;
import android.os.IBinder;
import android.util.Log;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.WindowManager;

import java.io.File;
import java.io.FileOutputStream;

import java.util.List;

/**
 * 悬浮窗服务：每秒采集一次，绘制在游戏画面之上。
 *
 * 必须跑成前台服务（startForeground + FOREGROUND_SERVICE_TYPE_SPECIAL_USE）：
 * 普通 startService 起的服务 oom_score_adj=200（缓存/可见服务级），
 * 多开应用时 AMS 会按 "empty #N" 把它当可回收进程杀掉，悬浮窗就消失了。
 * 前台服务 adj=0 级，LMK 不会为别的应用回收它。
 */
public class OverlayService extends Service {

    private static final String TAG = "ngp-overlay";
    private static final String CH_ID = "ngp_overlay_v2";
    private static final int NOTI_ID = 1001;

    private WindowManager wm;
    private OverlayView view;
    private WindowManager.LayoutParams lp;
    private int[] dragStart;
    private float dragX, dragY;
    private boolean draggable = true;
    private Thread worker;
    private volatile boolean running;

    @Override
    public void onCreate() {
        super.onCreate();
        wm = (WindowManager) getSystemService(WINDOW_SERVICE);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent == null ? null : intent.getAction();
        if ("stop".equals(action)) {
            Log.i(TAG, "stop requested");
            stopSelf();
            return START_NOT_STICKY;
        }
        if ("hide".equals(action) || "show".equals(action)) {
            setHidden("hide".equals(action));
            return START_STICKY;
        }
        if ("toggle".equals(action)) {
            if (view == null) {
                // 服务还没跑起来，toggle 等同于打开
                if (!show()) {
                    stopSelf();
                    return START_NOT_STICKY;
                }
                return START_STICKY;
            }
            setHidden(view.getVisibility() == android.view.View.VISIBLE);
            return START_STICKY;
        }
        if (view == null) {
            if (!show()) {
                stopSelf();
                return START_NOT_STICKY;
            }
        }
        return START_STICKY;
    }

    /** 立即成为前台服务，这是 oom_score_adj 从 200 降到 0 级的关键。 */
    private void goForeground() {
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel ch = new NotificationChannel(
                    CH_ID, "性能悬浮窗", NotificationManager.IMPORTANCE_LOW);
            ch.setShowBadge(false);
            ch.setSound(null, null);
            ch.enableVibration(false);
            ch.setLockscreenVisibility(Notification.VISIBILITY_SECRET);
            nm.createNotificationChannel(ch);
        }
        Intent open = new Intent(this, ToggleActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        PendingIntent pi = PendingIntent.getActivity(
                this, 0, open,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        Notification n = new Notification.Builder(this, CH_ID)
                .setContentTitle("性能悬浮窗运行中")
                .setContentText("点按可开关悬浮窗")
                .setSmallIcon(android.R.drawable.ic_menu_info_details)
                .setContentIntent(pi)
                .setOngoing(true)
                .setPriority(Notification.PRIORITY_LOW)
                .setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
                .build();
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(NOTI_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
            } else {
                startForeground(NOTI_ID, n);
            }
            Log.i(TAG, "foreground started");
        } catch (Throwable t) {
            Log.e(TAG, "startForeground failed: " + t);
        }
    }

    private boolean show() {
        goForeground();   // 先降 adj，再建窗口：建窗口若失败也不会留下可回收进程
        try {
            view = new OverlayView(this);
            draggable = readFlag("drag", 1) != 0;
            lp = new WindowManager.LayoutParams(
                    WindowManager.LayoutParams.WRAP_CONTENT,
                    WindowManager.LayoutParams.WRAP_CONTENT,
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                            ? WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                            : WindowManager.LayoutParams.TYPE_PHONE,
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                            | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                            | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
                            // 必须 LAYOUT_IN_SCREEN：否则窗口会被限制在调用者 task 的
                            // Leaf 里，别的应用在前台时会被那个 Leaf 盖住，
                            // dumpsys 表现为 Surface: shown=false / isReadyForDisplay()=false
                            | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                    PixelFormat.TRANSLUCENT);
            lp.gravity = Gravity.TOP | Gravity.START;
            int[] pos = readPos();
            lp.x = pos[0];
            lp.y = pos[1];
            if (draggable) {
                // 可拖动：窗口要接收指针事件（鼠标/触控），否则拖动无法触发
                lp.flags &= ~WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE;
                view.setOnTouchListener(this::onTouch);
            }
            wm.addView(view, lp);
        } catch (Throwable t) {
            Log.e(TAG, "addView failed (SYSTEM_ALERT_WINDOW 未授权?): " + t);
            return false;
        }

        running = true;
        worker = new Thread(this::loop, "ngp-stat");
        worker.start();
        // 冷启动一律显示：服务被系统强杀/重装后如果还沿用上次的 hidden=1，
        // 用户看到的就是"悬浮窗莫名消失"，这比丢失开关状态更糟。
        // 开关状态只用于同一进程内的 toggle，不跨启动。
        saveCfg("hidden=0");
        Log.i(TAG, "overlay shown");
        return true;
    }

    /** 显示/隐藏只切 View 可见性，服务与窗口一直保留（点击不重建窗口，更稳）。 */
    private void setHidden(boolean hide) {
        if (view != null) {
            view.setVisibility(hide ? android.view.View.GONE : android.view.View.VISIBLE);
        }
        saveCfg("hidden=" + (hide ? 1 : 0));
        Log.i(TAG, hide ? "overlay hidden" : "overlay visible");
    }

    /** 拖动：按住面板移动，松手后保存到应用私有目录（app 无法写 /data/local/tmp）。 */
    private boolean onTouch(android.view.View v, MotionEvent e) {
        switch (e.getActionMasked()) {
            case MotionEvent.ACTION_DOWN:
                dragStart = new int[]{lp.x, lp.y};
                dragX = e.getRawX();
                dragY = e.getRawY();
                return true;
            case MotionEvent.ACTION_MOVE: {
                if (dragStart == null) return true;
                lp.x = dragStart[0] + (int) (e.getRawX() - dragX);
                lp.y = dragStart[1] + (int) (e.getRawY() - dragY);
                try {
                    wm.updateViewLayout(view, lp);
                } catch (Throwable ignored) {
                }
                return true;
            }
            case MotionEvent.ACTION_UP:
            case MotionEvent.ACTION_CANCEL:
                savePos(lp.x, lp.y);
                dragStart = null;
                return true;
        }
        return false;
    }

    private void savePos(int x, int y) {
        try (FileOutputStream fo = new FileOutputStream(new File(getFilesDir(), "pos.cfg"))) {
            // 与 /data/local/tmp/ngp-overlay.cfg 同格式，readPos/readFlag 共用解析
            fo.write(("x=" + x + "\ny=" + y + "\ndrag=" + (draggable ? 1 : 0) + "\n"
                    + "hidden=" + (view != null && view.getVisibility() != android.view.View.VISIBLE ? 1 : 0)
                    + "\n").getBytes("UTF-8"));
        } catch (Throwable ignored) {
        }
    }

    /** 只写单个配置项（pos.cfg 里的其它值保持不变）。 */
    private void saveCfg(String kv) {
        String key = kv.substring(0, kv.indexOf('='));
        File f = new File(getFilesDir(), "pos.cfg");
        int x = 20, y = 14, drag = draggable ? 1 : 0, hidden = 0;
        try (java.io.BufferedReader br = new java.io.BufferedReader(new java.io.FileReader(f))) {
            String l;
            while ((l = br.readLine()) != null) {
                l = l.trim();
                if (l.startsWith("x=")) x = Integer.parseInt(l.substring(2).trim());
                else if (l.startsWith("y=")) y = Integer.parseInt(l.substring(2).trim());
                else if (l.startsWith("drag=")) drag = Integer.parseInt(l.substring(5).trim());
                else if (l.startsWith("hidden=")) hidden = Integer.parseInt(l.substring(7).trim());
            }
        } catch (Throwable ignored) {
        }
        if (key.equals("hidden")) hidden = Integer.parseInt(kv.substring(7).trim());
        try (FileOutputStream fo = new FileOutputStream(f)) {
            fo.write(("x=" + x + "\ny=" + y + "\ndrag=" + drag + "\nhidden=" + hidden + "\n")
                    .getBytes("UTF-8"));
        } catch (Throwable ignored) {
        }
    }

    private int readFlag(String key, int def) {
        for (File f : new File[]{new File(getFilesDir(), "pos.cfg"),
                new File("/data/local/tmp/ngp-overlay.cfg")}) {
            try (java.io.BufferedReader br = new java.io.BufferedReader(new java.io.FileReader(f))) {
                String l;
                while ((l = br.readLine()) != null) {
                    l = l.trim();
                    if (l.startsWith(key + "=")) {
                        return Integer.parseInt(l.substring(key.length() + 1).trim());
                    }
                }
            } catch (Throwable ignored) {
            }
        }
        return def;
    }

    /** 位置优先级：app 自己保存的 pos.cfg > /data/local/tmp/ngp-overlay.cfg > 默认左上角 */
    private int[] readPos() {
        int x = 20, y = 14;
        File own = new File(getFilesDir(), "pos.cfg");
        File cfg = own.exists() ? own : new File("/data/local/tmp/ngp-overlay.cfg");
        try (java.io.BufferedReader br = new java.io.BufferedReader(
                new java.io.FileReader(cfg))) {
            String l;
            while ((l = br.readLine()) != null) {
                l = l.trim();
                if (l.startsWith("x=")) x = Integer.parseInt(l.substring(2).trim());
                else if (l.startsWith("y=")) y = Integer.parseInt(l.substring(2).trim());
            }
        } catch (Throwable ignored) {
        }
        return new int[]{x, y};
    }

    private void loop() {
        boolean first = true;
        while (running) {
            try {
                Stats.Snapshot s = Stats.collect(!first);   // 第一次只取基线，不算 FPS
                first = false;
                final List<String> ls = Stats.lines(s);
                final int color = s.fpsColor;
                final OverlayView v = view;
                if (v != null) {
                    v.post(() -> v.setData(ls, color));
                } else {
                    // 窗口丢失（SurfaceFlinger 重启 / 窗口被系统摘掉）→ 重新挂上
                    Log.w(TAG, "window lost, re-attaching");
                    reattach();
                }
            } catch (Throwable t) {
                Log.w(TAG, "collect failed: " + t);
            }
            try {
                Thread.sleep(1000);
            } catch (InterruptedException e) {
                break;
            }
        }
    }

    /** 窗口丢了就重新 addView（保留原来的可见性意图）。 */
    private void reattach() {
        if (wm == null || lp == null) return;
        try {
            OverlayView nv = new OverlayView(this);
            nv.setOnTouchListener(this::onTouch);
            wm.addView(nv, lp);
            view = nv;
            Log.i(TAG, "window re-attached");
        } catch (Throwable t) {
            Log.e(TAG, "re-attach failed: " + t);
        }
    }

    @Override
    public void onDestroy() {
        running = false;
        if (worker != null) worker.interrupt();
        if (view != null && wm != null) {
            try {
                wm.removeView(view);
            } catch (Throwable ignored) {
            }
            view = null;
        }
        Log.i(TAG, "overlay destroyed");
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
