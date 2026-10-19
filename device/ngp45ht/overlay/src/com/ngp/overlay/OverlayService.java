package com.ngp.overlay;

import android.app.Service;
import android.content.Intent;
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

/** 悬浮窗服务：每秒采集一次，绘制在游戏画面之上。 */
public class OverlayService extends Service {

    private static final String TAG = "ngp-overlay";

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
        if ("toggle".equals(action) && view != null) {
            view.setVisibility(view.getVisibility() == android.view.View.VISIBLE
                    ? android.view.View.GONE : android.view.View.VISIBLE);
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

    private boolean show() {
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
                            | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
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
        Log.i(TAG, "overlay shown");
        return true;
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
            fo.write(("x=" + x + "\ny=" + y + "\ndrag=" + (draggable ? 1 : 0) + "\n").getBytes("UTF-8"));
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
