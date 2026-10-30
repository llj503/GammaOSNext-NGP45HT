# -*- coding: utf-8 -*-
"""被编译器内联复制的字符串 —— 必须用短词。

这些字面量在 .text 里不是走 strlen/memcpy，而是：
    adrp x9, page ; add x9, x9, #off ; ldr x9, [x9]      ← 只读前 8 字节
    后面再用 mov/movk 立即数补上剩余的字节
所以只改 .rodata（或把它搬到串池）只能改前半截，后半截仍是英文原样，
拼起来就是半中半英甚至非法 UTF-8，屏幕上显示成 U+FFFD（菱形框问号）。

硬约束：**中文不超过 6 字节（2 个汉字）**，这样 NUL 一定落在前 8 字节里，
strlen 到 NUL 就停，后面立即数补进来的字节不会被读到。

超过 6 字节的只能保留英文（HLE / LLE / Xbox / Nintendo 这类术语本来就该保留）。
"""

INLINE_SHORT = {
    0x00a34f: "省电",      # Powersave
    0x00a60c: "超频",      # Overclock
    0x00a02f: "原生",      # Native (1x)
    0x00a98a: "上屏",      # Top Screen
    0x00d405: "大屏",      # Large Screen
    0x00ebd3: "双屏",      # Both Screens
    0x00b644: "并排",      # Side by Side
    0x009abe: "反转",      # Opposite Screen
    0x00e4d8: "下屏",      # Bottom Screen
    0x00d793: "游戏",      # Game Controlled
    0x00dd7d: "邻近",      # Nearest Neighbor
    0x00aba8: "近线",      # Nearest 2D, Linear 3D
    0x00ebe0: "锐线",      # Sharp Bilinear 2D, Linear 3D
    0x00981b: "锐双",      # Sharp Bilinear 2D and 3D
    0x00cc93: "锐近",      # Sharp Bilinear 2D, Nearest 3D
    0x00e1c9: "锐利",      # Sharp Bilinear
    0x009d43: "隔行",      # Interlaced
    0x00efc7: "反隔",      # Reverse Interlaced
    0x00b950: "无限",      # Unlimited
    0x00ccb1: "关闭",      # Off (faster)
    0x00d7ee: "澳洲",      # Australia
    0x00f664: "触控",      # Touch Cursor
    0x00b965: "C杆",       # C-Stick + Cursor
    0x00b976: "名称",      # New cheat name
    0x00ad1d: "删除",      # Delete Per-Game Override?
    0x00c05f: "创建",      # Create Per-Game Override?
    0x00d216: "搜索",      # Search cheats

    # 以下保持英文：长度压不进 6 字节，且本身就是术语/品牌
    #   0x00b95a HLE (fast)   0x00efe6 LLE (accurate)
    #   0x0094da LLE multithreaded   0x00c91a Xbox (…)
    #   0x00eff5 Nintendo (…)         0x00935f 无
}
