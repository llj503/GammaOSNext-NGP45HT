# 3DS —— azahar-nano + AzaharSf

NGP45HT 上的 Nintendo 3DS 由两部分组成：

| 组件 | 位置 | 作用 |
| --- | --- | --- |
| `azahar-nano` | `/system/bin/` | GammaOS nano 外壳下的 3DS 前端（DRM/KMS 直渲染） |
| `AzaharSf` | `/system/app/AzaharSf/` | Android 侧宿主，从 LANGOS 或 nano 外壳拉起 |
| `libazahar-nano-core.so`（38 MB） | `/vendor/azahar/` | 模拟器主体 |
| 4 个 AdrenoTools hook | `/vendor/azahar/` | `libhook_impl` / `libmain_hook` / `libfile_redirect_hook` / `libgsl_alloc_hook` |

只走 Vulkan —— OpenGL ES 在 Mali-G52 上跑 azahar 会崩，菜单里没有 GL 选项是正常的。

## core 为什么在 /vendor 而不在 /system

两个硬约束：

1. **放不进 system**。p4 加完内置应用后只剩约 4.6 MB，core 本身 38 MB。
2. **必须和 4 个 hook 同目录**。前端从 core 的 dirname 推导 hook 目录，hooks 散在
   `/system/lib64` 就找不到。

也不能靠符号链接放进 `/vendor/lib64` —— linker 会按 realpath 判断，链接目标不在
permitted paths 里会被拒。

所以：core + hooks 一起放 `/vendor/azahar/`，开机由 `azahar-nano-setup.sh` 复制到
`/data`，再把 `persist.gammaos.azahar_nano.core` 指向 `/data/azahar-core.so`。
前端从属性里拿绝对路径 dlopen，`/data` 没有 namespace 限制。

> v26/v27 时 p5 只有 254 MiB、剩 7.8 MB，core 是放在启动分区（p3 的 `/azahar`，
> FAT32）再复制到 `/data` 的。v28 把 p5 扩到 575 MiB，core 才搬进 vendor ——
> 不再依赖 FAT 分区，p3 也腾出了 36 MB。

## 文件来源

`libazahar-nano-core.so` 和 4 个 hook 来自 **`GammaOSCore-RG52Mini-20261025-2119-ota.zip`**
（RG52mini v1.14）的下列路径，未做任何修改：

```
system/lib64/libazahar-nano-core.so        37,943,712 B  md5 db3d2ab74a3af4611b9dc2b5ef4e6a9d
system/lib64/libhook_impl.so                  277,824 B  md5 423d0691585c9b2a16b59358125038ec
system/lib64/libmain_hook.so                    3,984 B  md5 959fcaa5e12136e7969d8c9475328142
system/lib64/libfile_redirect_hook.so           3,784 B  md5 868aededd1dd042c2c58e7f5415bdbd4
system/lib64/libgsl_alloc_hook.so               4,080 B  md5 717ce0e8b721c25f237b4f5234c7e97e
```

这 5 个二进制不进 git（38 MB，走 Git Data API 太慢），需要时按上表从 zip 里取。

`azahar-nano` 前端自身（524,080 B）和 `nano_shaderc` 在 `GammaOSCore-RG52Mini` 的
`system/bin/` 下，同样未改动，直接写进镜像的 `/system/bin/`。

## 两个脚本

**`azahar-nano.rc`** —— init 服务定义。`post-fs-data` 时跑一次 setup；
`sys.gammaos.azahar_nano.start=1`（nano 外壳拉起）和 `start_app=1`
（Android 侧 AzaharSf 拉起）是两个入口。会话结束按 `host` 决定是否回到 nano 外壳。

**`azahar-nano-setup.sh`** —— 把 core 和 hooks 从 `/vendor/azahar` 复制到 `/data`。
按**文件大小**判断是否需要复制，所以升级镜像时 /data 里的旧 core 会被自动换掉
（只判断"是否存在"的话，刷了新版 core 也还是用旧的）。
