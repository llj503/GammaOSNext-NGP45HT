/* ngp-statd — NGP45HT 性能统计守护进程（root）
 *
 * 为什么需要它：Android 给所有 app 进程的 CapBnd 是空的，
 * 所以即使 /vendor/bin/su 带 setuid 位，app 调用也拿不到 CAP_SETUID
 * （setuid(0) → EPERM）。这是 Android 的设计，不是 bug。
 *
 * 做法：本程序由 init/root 启动，每秒问一次 SurfaceFlinger 的
 * TimeStats，把 totalFrames 与开机毫秒数写到 /data/local/tmp/ngp-fps，
 * 悬浮窗 app 直接读文件算帧率，完全不需要 root。
 *
 * 编译：aarch64-linux-gcc -O2 -static -o ngp-statd ngp-statd.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <sys/stat.h>

#define OUT_PATH "/data/local/tmp/ngp-fps"
#define TMP_PATH "/data/local/tmp/.ngp-fps.tmp"

static long long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_BOOTTIME, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* 返回 totalFrames，失败返回 -1 */
static long long read_total_frames(void) {
    FILE *p = popen("/system/bin/dumpsys SurfaceFlinger --timestats -dump 2>/dev/null", "r");
    if (!p) return -1;
    char line[512];
    long long frames = -1;
    while (fgets(line, sizeof(line), p)) {
        if (strncmp(line, "totalFrames = ", 14) == 0) {
            frames = atoll(line + 14);
            break;
        }
    }
    pclose(p);
    return frames;
}

static void run_quiet(const char *cmd) {
    int r = system(cmd);
    (void)r;
}

static void write_status(long long frames, long long ms) {
    FILE *f = fopen(TMP_PATH, "w");
    if (!f) return;
    fprintf(f, "%lld %lld\n", frames, ms);
    fclose(f);
    chmod(TMP_PATH, 0644);
    if (rename(TMP_PATH, OUT_PATH) != 0) {
        unlink(TMP_PATH);
    }
}

int main(void) {
    /* 开机早期 SF 可能还没起来，先给个占位 */
    write_status(-1, now_ms());

    /* TimeStats 默认是关的，--dump 在未 enable 时没有 totalFrames 输出；
     * 而且这个开关不跨重启，所以每次启动都要 enable 一次。 */
    for (int i = 0; i < 10; i++) {
        run_quiet("/system/bin/dumpsys SurfaceFlinger --timestats -enable >/dev/null 2>&1");
        if (read_total_frames() >= 0) break;
        sleep(1);
    }

    for (;;) {
        long long t0 = now_ms();
        long long frames = read_total_frames();
        if (frames < 0) {
            run_quiet("/system/bin/dumpsys SurfaceFlinger --timestats -enable >/dev/null 2>&1");
            frames = read_total_frames();
        }
        write_status(frames, now_ms());

        long long spent = now_ms() - t0;
        long long sleep_ms = 1000 - spent;
        if (sleep_ms < 100) sleep_ms = 100;
        usleep((useconds_t)(sleep_ms * 1000));
    }
    return 0;
}
