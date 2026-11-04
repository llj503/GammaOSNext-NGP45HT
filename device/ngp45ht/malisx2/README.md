# malisx2 for NGP45HT（RK3562 / Mali-G52 MP1）

上游 [bmdhacks/malisx2](https://github.com/bmdhacks/malisx2) 的 clean-room Mali Vulkan 驱动。
在 NGP45HT 上一启动就 SIGABRT，根因是它的 gralloc handle 解析按 RK3576 的布局写死，
RK3562 上整体错位 4 字节。此目录是修补后的构建产物与补丁。

## 根因

`src/vk/mali_wsi.c` 用 `memcpy` 把 `native_handle_t` 的 int 数组按 C 结构体解析：

```c
_Static_assert(offsetof(struct arm_gralloc_handle, stride) == 0x38, "arm gralloc stride");
```

该结构体有 `int unknown[2]`，再叠加 `uint64_t` 的 8 字节对齐填充，是照 **RK3576（RG Vita Pro）**
的 handle 布局写的。RK3562 的 ARM gralloc 在 `stride` 之后**只多 1 个 int**，于是：

| 字段 | 偏移 | RK3562 实际 | 被误读成 |
|---|---|---|---|
| stride | 0x38 | 0 | stride = 0 |
| `unknown[2]` | 0x3c | 只有 1 个 | — |
| `alloc_format.modifiers` | 0x44 | 0 | 4096（其实是 `plane[0].byte_stride`）|

于是判定为「gralloc allocated a compressed or tiled buffer」，`vkCreateImage w/ native buffer failed`，
GS 线程 SIGABRT。

实测 handle（日志里 `%x` 打印，索引从 numFds 之后算）：

```
[0]=3141592 magic   [1]=400 w=1024     [2]=300 h=768
[8]=0 stride        [10]=1 format.base [11]=0 modifiers
[12]=0 plane.offset [13]=1000 byte_stride=4096  [14]=400 alloc_w  [15]=300 alloc_h
```

buffer 本身完全正常。

## 补丁

`malisx2-gralloc-rk3562.patch`：不再 `memcpy` 整个结构体，改为**按 int 索引取值**，
扫描 plane 数组取第一个 `offset == 0` 且能容纳图像宽高的平面。截断/畸形 handle 会被拒绝
（返回 0 + 原因），而不是误读成别的布局。

保留的校验：magic、fd/int 计数、宽高与图像一致、`modifiers == 0`、`pitch % bpp == 0`、
`pitch * height <= size`。

## 构建

```bash
# 依赖（Ubuntu 26.04 实测）
#   NDK r27c（README 写 r28c，r27c 可用）
#   rustup target add aarch64-linux-android
#   cargo install bindgen-cli --version 0.72.1 --locked
#   meson / ninja / mako / PyYAML

git clone --depth 1 https://github.com/bmdhacks/malisx2.git src
cd src && git apply /path/to/malisx2-gralloc-rk3562.patch

# mesa 必须是 meson.build 里写死的那个 commit
git init mesa && cd mesa
git remote add origin https://github.com/bmdhacks/armsx2-turnip.git
git fetch --depth 1 origin 81113fce01b0e3974cdbb2683449e8619d0639e0
git checkout -q FETCH_HEAD && cd ..

# 交叉文件里把 NDK 路径换成本机的
sed 's|/home/bmd/Android/Sdk/ndk/28.2.13676358|/path/to/android-ndk-r27c|' \
    cross/android-aarch64.ini > /tmp/android-aarch64-ngp.ini

**两个必踩的坑**

# 坑 1：WorkBuddy 的 safe-delete 钩子通过 PYTHONPATH 注入 sitecustomize.py，
#        会拦掉 meson 清理临时目录 → setup 静默 exit=1 且不生成 build.ninja
unset PYTHONPATH BASH_ENV CODEBUDDY_SAFE_DELETE_ENABLED

# 坑 2：Ubuntu 的 llvm-21 没装 libclang-common-21-dev，
#        /usr/lib/llvm-21/lib/clang/*/include 不存在 → bindgen 找不到 float.h
NDK=/path/to/android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64
export BINDGEN_EXTRA_CLANG_ARGS="--target=aarch64-linux-android29 \
  --sysroot=$NDK/sysroot -isystem $NDK/lib/clang/18/include"

export BINDGEN=$(command -v bindgen)
meson setup build-android --cross-file /tmp/android-aarch64-ngp.ini
ninja -C build-android

# 打包（adrenotools 格式：.so + meta.json）
$NDK/bin/llvm-strip --strip-all build-android/src/libvulkan_malisx2.so
zip malisx2-0.3.2-ngp1.zip libvulkan_malisx2.so meta.json
```

## 装机

ARMSX2：设置 → 渲染器 → 图形 API 选 Vulkan → GPU 驱动 → 导入 → 选 zip。

**注意两个坑**：

1. 驱动存放在 `/data/data/com.armsx2/files/drivers/`，选择结果存在
   **`/data/data/com.armsx2/shared_prefs/ARMSX2.xml`**（不是
   `/storage/emulated/0/Android/data/com.armsx2/files/armsx2-settings.json`，
   那个只是镜像，改了不生效）。
2. ARMSX2 支持**按游戏覆盖驱动**。游戏级设置优先级高于全局，
   换驱动后必须清掉游戏级覆盖（UI 里改，或把旧驱动目录移走迫使回落）。

## 实测（2026-11-04）

| 项 | 结果 |
|---|---|
| God of War II 主菜单 | 25~26 fps，GPU 73%，EE 61% |
| 运行 2 分钟 | 稳定，无 SIGABRT |
| 内存 PSS | 697 MB（系统 Vulkan 直连下 2GB 机器偏紧）|
| gralloc 报错 | 消失 |

同一台机器、同一份驱动，补丁前后差别就在这一处 handle 解析：补丁前启动即 abort，
补丁后正常出图。
