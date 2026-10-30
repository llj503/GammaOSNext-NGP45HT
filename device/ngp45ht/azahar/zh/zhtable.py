# -*- coding: utf-8 -*-
"""合并后的最终汉化表。build.py / verify.py 都从这里取，保证判定一致。"""
from zh import ZH as _ZH
from zh_inline import INLINE_SHORT

ZH = dict(_ZH)
# 被编译器内联复制的短串，用 6 字节以内的短词覆盖
ZH.update(INLINE_SHORT)
# 这 5 条压不进 6 字节，且本身是术语/品牌，保持英文原样
KEEP_EN = (0x00b95a, 0x00efe6, 0x0094da, 0x00c91a, 0x00eff5)
for _a in KEEP_EN:
    ZH.pop(_a, None)

# 内联串的长度红线
for _a, _s in INLINE_SHORT.items():
    assert len(_s.encode('utf-8')) <= 6, f'{_a:#06x} 内联串超过 6 字节: {_s}'
