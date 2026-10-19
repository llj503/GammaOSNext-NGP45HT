package com.ngp.overlay;

import java.io.BufferedReader;
import java.io.FileReader;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * 采集 CPU / GPU 频率、温度、帧率。
 *
 * CPU/GPU/温度直接读 sysfs（app 可读）。
 * 帧率来自 root 守护进程 ngp-statd 写出的 /data/local/tmp/ngp-fps
 * （形如 "12345 678901"，即 SurfaceFlinger totalFrames + 开机毫秒数）。
 *
 * 为什么不用 su：Android 给所有 app 进程的 CapBnd 是空的，
 * 即使 su 带 setuid 位，app 调用 setuid(0) 也会 EPERM。
 */
public final class Stats {

    private static final int CPU_NUM = 4;
    private static final String GPU_DEVFREQ = "/sys/class/devfreq/ff320000.gpu";
    private static final String FPS_FILE = "/data/local/tmp/ngp-fps";

    private static long sLastFrames = -1;
    private static long sLastMs = -1;
    private static long sLastNanos = -1;
    private static double sFps = -1;

    public static final class Snapshot {
        public String line1 = "CPU  --";
        public String line2 = "TMP  --";
        public String fps = "FPS  --";
        public int fpsColor = 0xFF9A9A9A;
    }

    private Stats() {}

    private static String readLine(String path) {
        try (BufferedReader br = new BufferedReader(new FileReader(path))) {
            String s = br.readLine();
            return s == null ? null : s.trim();
        } catch (Throwable t) {
            return null;
        }
    }

    private static long readLong(String path, long def) {
        String s = readLine(path);
        if (s == null) return def;
        try {
            return Long.parseLong(s.trim());
        } catch (NumberFormatException e) {
            return def;
        }
    }

    /** 读守护进程写的 totalFrames / uptime_ms，按本地墙钟算帧率。 */
    private static double sampleFps() {
        String s = readLine(FPS_FILE);
        if (s == null) return -1;
        String[] p = s.split("\\s+");
        if (p.length < 2) return -1;
        long frames, ms;
        try {
            frames = Long.parseLong(p[0]);
            ms = Long.parseLong(p[1]);
        } catch (NumberFormatException e) {
            return -1;
        }
        if (frames < 0) return -1;
        if (ms == sLastMs) return -1;            // 守护进程没更新（挂了/停了）

        long now = System.nanoTime();
        double fps = -1;
        if (sLastFrames >= 0 && frames >= sLastFrames && sLastNanos > 0) {
            double dt = (now - sLastNanos) / 1e9;
            if (dt > 0.2) fps = (frames - sLastFrames) / dt;
        }
        sLastFrames = frames;
        sLastMs = ms;
        sLastNanos = now;
        return fps;
    }

    public static Snapshot collect(boolean wantFps) {
        Snapshot s = new Snapshot();

        // ---- CPU：4 核当前频率 ----
        long[] f = new long[CPU_NUM];
        long max = 0;
        boolean any = false;
        for (int i = 0; i < CPU_NUM; i++) {
            long khz = readLong("/sys/devices/system/cpu/cpu" + i + "/cpufreq/scaling_cur_freq", -1);
            f[i] = khz;
            if (khz > 0) {
                any = true;
                if (khz > max) max = khz;
            }
        }

        // ---- GPU：devfreq 频率（单位 Hz）+ 负载 ----
        long gHz = readLong(GPU_DEVFREQ + "/cur_freq", -1);
        String loadRaw = readLine(GPU_DEVFREQ + "/load");   // "12@300000000Hz"
        int gLoad = -1;
        if (loadRaw != null) {
            int at = loadRaw.indexOf('@');
            String num = (at > 0 ? loadRaw.substring(0, at) : loadRaw).trim();
            try {
                gLoad = (int) Double.parseDouble(num);
            } catch (NumberFormatException ignored) {
            }
        }

        StringBuilder l1 = new StringBuilder();
        l1.append(any ? String.format(Locale.US, "CPU %4dMHz", max / 1000) : "CPU   --MHz");
        if (gHz > 0) {
            l1.append(String.format(Locale.US, "  GPU %3dMHz", gHz / 1000000));
            if (gLoad >= 0) l1.append(String.format(Locale.US, " %3d%%", gLoad));
        }
        s.line1 = l1.toString();

        // ---- 温度 + 电量 ----
        double soc = Double.NaN, bat = Double.NaN;
        for (int z = 0; z < 20; z++) {
            String base = "/sys/class/thermal/thermal_zone" + z;
            String type = readLine(base + "/type");
            if (type == null) continue;
            long t = readLong(base + "/temp", Long.MIN_VALUE);
            if (t == Long.MIN_VALUE) continue;
            double c = t / 1000.0;
            if (type.contains("soc") || type.contains("cpu") || type.contains("gpu")) {
                if (Double.isNaN(soc) || c > soc) soc = c;
            } else if (type.contains("battery")) {
                bat = c;
            }
        }
        long cap = readLong("/sys/class/power_supply/battery/capacity", -1);

        StringBuilder l2 = new StringBuilder("TMP ");
        l2.append(Double.isNaN(soc) ? "  --" : String.format(Locale.US, "%4.1f\u00b0C", soc));
        if (!Double.isNaN(bat)) l2.append(String.format(Locale.US, "  BAT %4.1f\u00b0C", bat));
        if (cap >= 0) l2.append(String.format(Locale.US, "  %3d%%", cap));
        s.line2 = l2.toString();

        // ---- FPS ----
        if (wantFps) sFps = sampleFps();
        double fps = sFps;
        if (fps >= 0) {
            s.fps = String.format(Locale.US, "FPS %4.1f", fps);
            if (fps >= 50) s.fpsColor = 0xFF7CE38B;
            else if (fps >= 28) s.fpsColor = 0xFFF2C94C;
            else s.fpsColor = 0xFFEB5757;
        } else {
            s.fps = "FPS  --";
            s.fpsColor = 0xFF9A9A9A;
        }
        return s;
    }

    public static List<String> lines(Snapshot s) {
        List<String> out = new ArrayList<>(3);
        out.add(s.line1);
        out.add(s.line2);
        out.add(s.fps);
        return out;
    }
}
