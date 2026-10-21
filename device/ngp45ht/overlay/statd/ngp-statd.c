/* ngp-statd — NGP45HT 性能统计守护进程（root）
 *
 * 为什么需要它：Android 给所有 app 进程的 CapBnd 是空的，
 * 所以即使 /vendor/bin/su 带 setuid 位，app 调用也拿不到 CAP_SETUID
 * （setuid(0) → EPERM）。这是 Android 的设计，不是 bug。
 *
 * 做法：本程序由 init/root 启动，每秒问一次 SurfaceFlinger 的 TimeStats，
 * 自己算好帧率后写到 /data/local/tmp/ngp-fps（格式 "<fps> <boot_ms>"），
 * 悬浮窗 app 直接读文件显示，完全不需要 root。
 *
 * 与 v1 的差别：
 *   1. 不再用 popen（dumpsys 卡住会永久阻塞），改成 fork+exec+超时 kill；
 *   2. 帧率在守护进程内算，app 端只管显示，避免两处时钟/基线不一致；
 *   3. 计数器被 -enable 重置时自动重设基线，不会出现一秒钟的"灰屏"；
 *   4. 连续失败才写 -1，短暂抖动保留上一次的有效值。
 *
 * 编译：
 *   $NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android29-clang \
 *       -O2 -static -o ngp-statd ngp-statd.c
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define OUT_PATH "/data/local/tmp/ngp-fps"
#define TMP_PATH "/data/local/tmp/.ngp-fps.tmp"
#define DUMPSYS  "/system/bin/dumpsys"

#define DUMP_TIMEOUT_MS 2000
#define SAMPLE_MS       1000

/* 悬浮窗进程守卫：
 * 该 ROM 上 FGS 在多开应用/内存吃紧时会被 AMS 降级到 adj=200
 * （不是杀掉，是降成 PERCEPTIBLE 缓存级），随后就被当 "empty" 回收，
 * 现象就是用户说的"应用一多开悬浮窗就消失"。
 * 作为 root 守护进程，直接从 /proc 写回 adj，把它钉在不可见前台服务的
 * 权重 -900，LMK 永远不会为别的应用回收它。进程重启则重新找 PID。 */
#define OVERLAY_PKG   "com.ngp.overlay"
#define OVERLAY_ADJ   "-900"
#define GUARD_EVERY   2          /* 每 N 轮检查一次（约 2 秒） */

static int pid_of(const char *name) {
    /* 遍历 /proc/<pid>/cmdline，找到与 name 完全相等的进程 */
    DIR *d = opendir("/proc");
    if (!d) return -1;
    struct dirent *e;
    int found = -1;
    char buf[256];
    while ((e = readdir(d))) {
        if (e->d_name[0] < '0' || e->d_name[0] > '9') continue;
        snprintf(buf, sizeof(buf), "/proc/%s/cmdline", e->d_name);
        int fd = open(buf, O_RDONLY);
        if (fd < 0) continue;
        ssize_t n = read(fd, buf, sizeof(buf) - 1);
        close(fd);
        if (n <= 0) continue;
        buf[n] = '\0';
        if (strcmp(buf, name) == 0) { found = atoi(e->d_name); break; }
    }
    closedir(d);
    return found;
}

static void pin_overlay_adj(void) {
    int pid = pid_of(OVERLAY_PKG);
    if (pid <= 0) return;
    char p[64], cur[16];
    snprintf(p, sizeof(p), "/proc/%d/oom_score_adj", pid);
    int fd = open(p, O_RDONLY);
    if (fd < 0) return;
    ssize_t n = read(fd, cur, sizeof(cur) - 1);
    close(fd);
    if (n <= 0) return;
    cur[n] = '\0';
    if (atoi(cur) <= atoi(OVERLAY_ADJ)) return;   /* 已经够高了 */
    fd = open(p, O_WRONLY);
    if (fd < 0) return;
    if (write(fd, OVERLAY_ADJ, strlen(OVERLAY_ADJ)) < 0) { /* 忽略 */ }
    close(fd);
}

static long long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_BOOTTIME, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void sleep_ms(long long ms) {
    if (ms <= 0) return;
    struct timespec ts;
    ts.tv_sec = (time_t)(ms / 1000);
    ts.tv_nsec = (long)((ms % 1000) * 1000000L);
    nanosleep(&ts, NULL);
}

/* fork+exec 跑 dumpsys，读 stdout，超时 kill。返回 0 成功。 */
static int run_dumpsys(char *buf, size_t cap) {
    int pfd[2];
    if (pipe(pfd) != 0) return -1;

    pid_t pid = fork();
    if (pid < 0) {
        close(pfd[0]);
        close(pfd[1]);
        return -1;
    }
    if (pid == 0) {
        int devnull = open("/dev/null", O_RDWR);
        dup2(pfd[1], STDOUT_FILENO);
        if (devnull >= 0) {
            dup2(devnull, STDERR_FILENO);
            dup2(devnull, STDIN_FILENO);
        }
        close(pfd[0]);
        close(pfd[1]);
        execl(DUMPSYS, "dumpsys", "SurfaceFlinger", "--timestats", "-dump", (char *)NULL);
        _exit(127);
    }

    close(pfd[1]);
    fcntl(pfd[0], F_SETFL, O_NONBLOCK);

    size_t used = 0;
    long long deadline = now_ms() + DUMP_TIMEOUT_MS;
    int timed_out = 0;

    for (;;) {
        ssize_t n = read(pfd[0], buf + used, cap - 1 - used);
        if (n > 0) {
            used += (size_t)n;
            if (used >= cap - 1) break;      /* 缓冲满，够了 */
            continue;
        }
        if (n == 0) break;                   /* EOF：子进程退出并关掉管道 */
        if (errno == EINTR) continue;
        if (errno != EAGAIN && errno != EWOULDBLOCK) break;

        /* 暂时没数据：等一小会，同时看总超时 */
        if (now_ms() >= deadline) {
            timed_out = 1;
            break;
        }
        struct pollfd p = { .fd = pfd[0], .events = POLLIN };
        if (poll(&p, 1, 50) < 0 && errno != EINTR) break;
    }
    close(pfd[0]);

    /* 只有还在跑的子进程才会被 kill；pid 恒为上面 fork 出来的那个 */
    if (timed_out) kill(pid, SIGKILL);
    {
        int st;
        while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
    }
    buf[used] = '\0';
    return timed_out ? -1 : 0;
}

/* 只取全局 totalFrames（第一处，出现在每层统计之前）。失败返回 -1。 */
static long long parse_total_frames(const char *buf) {
    const char *p = buf;
    while ((p = strstr(p, "totalFrames = ")) != NULL) {
        if (p == buf || p[-1] == '\n') {
            return atoll(p + 14);
        }
        p += 14;
    }
    return -1;
}

static long long read_frames(void) {
    static char buf[262144];
    if (run_dumpsys(buf, sizeof(buf)) != 0) return -1;
    return parse_total_frames(buf);
}

static void enable_timestats(void) {
    pid_t pid = fork();
    if (pid == 0) {
        int devnull = open("/dev/null", O_RDWR);
        if (devnull >= 0) {
            dup2(devnull, STDOUT_FILENO);
            dup2(devnull, STDERR_FILENO);
            dup2(devnull, STDIN_FILENO);
        }
        execl(DUMPSYS, "dumpsys", "SurfaceFlinger", "--timestats", "-enable", (char *)NULL);
        _exit(127);
    }
    if (pid > 0) {
        int st;
        while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
    }
}

static void write_status(double fps, long long ms, int valid) {    FILE *f = fopen(TMP_PATH, "w");
    if (!f) return;
    if (valid) fprintf(f, "%.1f %lld\n", fps, ms);
    else       fprintf(f, "-1 %lld\n", ms);
    fclose(f);
    chmod(TMP_PATH, 0644);
    if (rename(TMP_PATH, OUT_PATH) != 0) unlink(TMP_PATH);
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);

    /* 开机早期 SF 可能还没起来，先给个占位 */
    write_status(-1, now_ms(), 0);

    /* TimeStats 默认关闭，--dump 在未 enable 时没有任何输出；
     * 且该开关不跨重启，也不跨熄屏（熄屏后 SF 会自己关掉）。 */
    for (int i = 0; i < 10; i++) {
        enable_timestats();
        if (read_frames() >= 0) break;
        sleep(1);
    }

    long long last_frames = -1, last_ms = 0;
    double fps = -1;
    int fail = 0;
    int tick = 0;

    for (;;) {
        if (++tick % GUARD_EVERY == 0) pin_overlay_adj();

        long long t0 = now_ms();
        long long frames = read_frames();
        long long t1 = now_ms();

        if (frames < 0) {
            /* 熄屏/重置后 TimeStats 会自己关掉，重新打开再试一次 */
            enable_timestats();
            frames = read_frames();
            t1 = now_ms();
        }

        if (frames < 0) {
            if (++fail >= 3) fps = -1;
            write_status(fps, t1, fps >= 0);
        } else {
            fail = 0;
            if (last_frames >= 0 && t1 > last_ms) {
                double dt = (t1 - last_ms) / 1000.0;
                if (frames >= last_frames) {
                    double inst = (frames - last_frames) / dt;
                    if (inst > 240) inst = 240;          /* 计数器跳变兜底 */
                    fps = (fps < 0) ? inst : fps * 0.55 + inst * 0.45;
                }
                /* frames < last_frames：-enable 把计数器清零了，重设基线，保留旧值 */
            }
            last_frames = frames;
            last_ms = t1;
            write_status(fps, t1, fps >= 0);
        }

        long long spent = now_ms() - t0;
        long long wait = SAMPLE_MS - spent;
        if (wait < 100) wait = 100;
        sleep_ms(wait);
    }
    return 0;
}
