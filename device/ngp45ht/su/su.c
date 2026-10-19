/* su for NGP45HT (Android 14 GSI, SELinux Permissive)
 *
 * 为什么需要它：这台机的 GSI 是 userdebug/debuggable=1，但镜像里没装 su
 * 二进制（toybox 也没 su applet），所以 Superuser 类 app 一律报"未安装"。
 *
 * 实现：靠文件 setuid 位提权（/vendor 挂载是 rw,seclabel,relatime，没有 nosuid），
 * 然后 exec 目标命令或起一个 root shell。
 *
 * 局限：不做授权管理。谁调用都直接给 root。需要弹窗授权请配合 Superuser app
 * （phh 系）使用；本程序只解决"没有 su"这一层。
 *
 * 编译：aarch64-linux-gcc -O2 -static -o su su.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>

int main(int argc, char **argv) {
    int i;

    /* 提权：setgid 必须在 setuid 之前（setuid 之后就丢特权了） */
    if (setgid(0) != 0 || setuid(0) != 0) {
        if (getuid() != 0) {
            fprintf(stderr, "su: cannot set uid 0: %s\n", strerror(errno));
            fprintf(stderr, "su: (setuid bit missing? chmod 4755 this binary)\n");
            return 1;
        }
    }

    setenv("PATH", "/sbin:/system/sbin:/system/bin:/system/xbin:/vendor/bin", 1);
    setenv("HOME", "/data/local/tmp", 1);
    setenv("USER", "root", 1);
    setenv("LOGNAME", "root", 1);

    /* 跳过前导选项，支持 su -c "cmd" */
    i = 1;
    while (i < argc && argv[i][0] == '-') {
        if (strcmp(argv[i], "-c") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "su: -c requires an argument\n");
                return 2;
            }
            execl("/system/bin/sh", "sh", "-c", argv[i + 1], (char *)NULL);
            fprintf(stderr, "su: exec sh -c: %s\n", strerror(errno));
            return 127;
        }
        i++;
    }

    if (i < argc) {
        execvp(argv[i], argv + i);
        fprintf(stderr, "su: %s: %s\n", argv[i], strerror(errno));
        return 127;
    }

    execl("/system/bin/sh", "sh", "-i", (char *)NULL);
    fprintf(stderr, "su: exec sh: %s\n", strerror(errno));
    return 127;
}
