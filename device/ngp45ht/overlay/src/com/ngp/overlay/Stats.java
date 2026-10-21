package com.ngp.overlay;

import android.os.SystemClock;

import java.io.BufferedReader;
import java.io.FileReader;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * 采集 CPU 频率/负载、GPU 频率/负载、内存占用、SoC 温度、电池功率、帧率。
 *
 * 全部来自 sysfs / procfs（app 可直接读），只有帧率来自 root 守护进程 ngp-statd
 * 写出的 /data/local/tmp/ngp-fps（形如 "59.8 1234567"，即帧率 + 开机毫秒数）。
 *
 * 注意：battery 的 thermal_zone 是 rk817 的假热区，恒为 18.8°C，
 * 不可用；电池功耗改用 voltage_now × current_now 计算。
 *
 * 为什么不用 su：Android 给所有 app 进程的 CapBnd 是空的，
 * 即使 su 带 setuid 位，app 调用 setuid(0) 也会 EPERM。
 */
public final class Stats {

    private static final int CPU_NUM = 4;
    private static final String GPU_DEVFREQ = "/sys/class/devfreq/ff320000.gpu";
    private static final String FPS_FILE = "/data/local/tmp/ngp-fps";
    private static final String PSY = "/sys/class/power_supply/battery/";

    /** 守护进程超过这个时间没更新，就认为它挂了，显示 -- */
    private static final long FPS_STALE_MS = 4000;

    public static final class Snapshot {
        public String line1 = "CPU  --";
        public String line2 = "MEM  --";
        public String line3 = "TMP  --";
        public String fps = "FPS  --";
        public int fpsColor = 0xFF9A9A9A;
    }

    /**
     * CPU 占用率需要两次采样做差，所以状态要跨调用保留。
     * 用 static 而不是实例字段：OverlayService 只有一条采集线程，安全且简单。
     */
    private static long[] prevCpu;
    private static double cpuPercent = -1;
    /** 稳态平滑，避免单次抖动导致数字乱跳（0.55 旧 + 0.45 新） */
    private static boolean cpuPrimed;

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

    /** 读 /proc/stat 第一行，返回 {total, idle}；失败返回 null。 */
    private static long[] readCpuTimes() {
        String s = readLine("/proc/stat");
        if (s == null || !s.startsWith("cpu ")) return null;
        String[] p = s.trim().split("\\s+");
        if (p.length < 5) return null;
        long total = 0, idle = 0;
        try {
            // user nice system idle iowait irq softirq steal ...
            for (int i = 1; i < p.length; i++) {
                long v = Long.parseLong(p[i]);
                total += v;
                if (i == 4 || i == 5) idle += v;   // idle + iowait 都不算忙
            }
        } catch (NumberFormatException e) {
            return null;
        }
        return new long[]{total, idle};
    }

    /** 计算 CPU 占用率（0~100）。首次调用只建立基线，返回 -1。 */
    private static double sampleCpuLoad() {
        long[] cur = readCpuTimes();
        if (cur == null) return -1;
        double out = -1;
        if (prevCpu != null) {
            long dt = cur[0] - prevCpu[0];
            long di = cur[1] - prevCpu[1];
            if (dt > 0) {
                double inst = (dt - di) * 100.0 / dt;
                if (inst < 0) inst = 0;
                if (inst > 100) inst = 100;
                out = cpuPrimed ? cpuPercent * 0.55 + inst * 0.45 : inst;
                cpuPrimed = true;
            }
        }
        prevCpu = cur;
        if (out >= 0) cpuPercent = out;
        return out;
    }

    /** 内存占用：MemTotal - MemAvailable 视为已用（含 cache/buffer 可回收部分）。 */
    private static int sampleMemPercent() {
        long total = 0, avail = -1, free = 0;
        try (BufferedReader br = new BufferedReader(new FileReader("/proc/meminfo"))) {
            String l;
            int n = 0;
            while ((l = br.readLine()) != null && n < 10) {
                n++;
                if (l.startsWith("MemTotal:")) total = parseKb(l);
                else if (l.startsWith("MemAvailable:")) avail = parseKb(l);
                else if (l.startsWith("MemFree:")) free = parseKb(l);
            }
        } catch (Throwable t) {
            return -1;
        }
        if (total <= 0) return -1;
        long used = (avail >= 0) ? total - avail : total - free;
        if (used < 0) used = 0;
        int pct = (int) Math.round(used * 100.0 / total);
        if (pct < 0) pct = 0;
        if (pct > 100) pct = 100;
        return pct;
    }

    private static long parseKb(String line) {
        // "MemTotal:        2027716 kB"
        int i = line.indexOf(':');
        if (i < 0) return 0;
        String rest = line.substring(i + 1).trim();
        int sp = rest.indexOf(' ');
        if (sp > 0) rest = rest.substring(0, sp);
        try {
            return Long.parseLong(rest);
        } catch (NumberFormatException e) {
            return 0;
        }
    }

    /** 读守护进程算好的帧率；文件过期/内容非法返回 -1（显示 --）。 */
    private static double sampleFps() {
        String s = readLine(FPS_FILE);
        if (s == null) return -1;
        String[] p = s.split("\\s+");
        if (p.length < 2) return -1;
        double fps;
        long ms;
        try {
            fps = Double.parseDouble(p[0]);
            ms = Long.parseLong(p[1]);
        } catch (NumberFormatException e) {
            return -1;
        }
        if (fps < 0 || fps > 240) return -1;
        long nowMs = SystemClock.elapsedRealtime();   // 与守护进程的 CLOCK_BOOTTIME 同源
        if (ms <= 0 || nowMs < ms || nowMs - ms > FPS_STALE_MS) return -1;
        return fps;
    }

    public static Snapshot collect(boolean wantFps) {
        Snapshot s = new Snapshot();

        // ---- CPU：4 核当前频率（取最高）+ 整机占用率 ----
        long max = 0;
        boolean any = false;
        for (int i = 0; i < CPU_NUM; i++) {
            long khz = readLong("/sys/devices/system/cpu/cpu" + i + "/cpufreq/scaling_cur_freq", -1);
            if (khz > 0) {
                any = true;
                if (khz > max) max = khz;
            }
        }
        double cl = sampleCpuLoad();

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
        l1.append(cl >= 0 ? String.format(Locale.US, " %3d%%", (int) Math.round(cl)) : "  --%");
        if (gHz > 0) {
            l1.append(String.format(Locale.US, "  GPU %3dMHz", gHz / 1000000));
            if (gLoad >= 0) l1.append(String.format(Locale.US, " %3d%%", gLoad));
        }
        s.line1 = l1.toString();

        // ---- 内存 ----
        int mem = sampleMemPercent();
        s.line2 = mem >= 0 ? String.format(Locale.US, "MEM %3d%%", mem) : "MEM  --%";

        // ---- SoC 温度（rk817 的 battery 热区是假值，忽略） ----
        double soc = Double.NaN;
        for (int z = 0; z < 20; z++) {
            String base = "/sys/class/thermal/thermal_zone" + z;
            String type = readLine(base + "/type");
            if (type == null) continue;
            if (type.contains("battery")) continue;
            long t = readLong(base + "/temp", Long.MIN_VALUE);
            if (t == Long.MIN_VALUE) continue;
            double c = t / 1000.0;
            if (type.contains("soc") || type.contains("cpu") || type.contains("gpu")) {
                if (Double.isNaN(soc) || c > soc) soc = c;
            }
        }

        // ---- 电池功率：P = U × I（电流方向取绝对值，方向看 status） ----
        String status = readLine(PSY + "status");
        boolean charging = status != null
                && (status.startsWith("Charg") || status.equals("Full"));
        long uv = readLong(PSY + "voltage_now", -1);           // µV
        long ua = readLong(PSY + "current_now", Long.MIN_VALUE); // µA
        double watts = Double.NaN;
        if (uv > 0 && ua != Long.MIN_VALUE) {
            double v = uv / 1e6;
            double a = Math.abs(ua) / 1e6;
            // 越界值直接丢弃（fuel gauge 偶发返回 0 或满量程）
            if (v > 2.5 && v < 5.5 && a < 9.0) watts = v * a;
        }
        long cap = readLong(PSY + "capacity", -1);

        StringBuilder l3 = new StringBuilder("TMP ");
        l3.append(Double.isNaN(soc) ? "  --" : String.format(Locale.US, "%4.1f\u00b0C", soc));
        if (Double.isNaN(watts)) {
            l3.append("  PWR   --");
        } else {
            l3.append(charging ? "  CHG " : "  PWR ")
              .append(String.format(Locale.US, "%4.2fW", watts));
        }
        if (cap >= 0) l3.append(String.format(Locale.US, "  %3d%%", cap));
        s.line3 = l3.toString();

        // ---- FPS ----
        if (wantFps) {
            double fps = sampleFps();
            if (fps >= 0) {
                s.fps = String.format(Locale.US, "FPS %4.1f", fps);
                if (fps >= 50) s.fpsColor = 0xFF7CE38B;
                else if (fps >= 28) s.fpsColor = 0xFFF2C94C;
                else s.fpsColor = 0xFFEB5757;
            } else {
                s.fps = "FPS  --";
                s.fpsColor = 0xFF9A9A9A;
            }
        }
        return s;
    }

    public static List<String> lines(Snapshot s) {
        List<String> out = new ArrayList<>(4);
        out.add(s.line1);
        out.add(s.line2);
        out.add(s.line3);
        out.add(s.fps);
        return out;
    }
}
