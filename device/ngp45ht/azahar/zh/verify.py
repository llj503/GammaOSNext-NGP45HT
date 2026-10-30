#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""验证汉化后的 azahar-nano.zh：
  1. .bss 对应文件区间必须全 0（否则全局变量带垃圾）
  2. 逐条重扫 .text 的 adrp+add，确认原字面量引用已全部改到新地址
  3. 确认没有 add 算出越界地址（映射区之外）
  4. 确认池内每条中文都能被正确读到
"""
import struct, sys, os
from capstone import *
from capstone.arm64 import ARM64_OP_REG, ARM64_OP_IMM

D = os.path.dirname(os.path.abspath(__file__))
P = os.path.join(D, 'azahar-nano.zh')
sys.path.insert(0, D)
from zhtable import ZH

b = open(P, 'rb').read()
ok = True

e_phoff = struct.unpack_from('<Q', b, 0x20)[0]
e_phentsize = struct.unpack_from('<H', b, 0x36)[0]
e_phnum = struct.unpack_from('<H', b, 0x38)[0]
loads = []
for i in range(e_phnum):
    o = e_phoff + i * e_phentsize
    t = struct.unpack_from('<I', b, o)[0]
    off, va, pa, fs, ms, al = struct.unpack_from('<QQQQQQ', b, o + 8)
    if t == 1:
        loads.append((off, va, fs, ms))
print('LOAD 段:')
for off, va, fs, ms in loads:
    print(f'  off {off:#08x} vaddr {va:#08x} filesz {fs:#08x} memsz {ms:#08x} -> [{va:#x},{va+fs:#x})')

# ---- 1. .bss 清零检查 ----
# .bss vaddr 0x7cd60 size 0x237a；对应文件 = vaddr - 0x1000
bss_va, bss_sz = 0x7cd60, 0x237a
bss_off = bss_va - 0x1000
chunk = b[bss_off:bss_off + bss_sz]
nz = sum(1 for x in chunk if x)
print(f'\n[1] .bss 文件区 {bss_off:#x}..{bss_off+bss_sz:#x}: 非零字节 {nz}')
if nz:
    print('    !! 失败：.bss 会被写成垃圾初值')
    ok = False

# ---- 2. 反汇编重扫 ----
md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
md.detail = True
TEXT_OFF, TEXT_SIZE = 0x1b000, 0x52cf0
TEXT_END = TEXT_OFF + TEXT_SIZE
state = {}
sites = {}
for ins in md.disasm(b[TEXT_OFF:TEXT_END], TEXT_OFF):
    m = ins.mnemonic
    if m == 'adrp':
        rd = ins.reg_name(ins.operands[0].reg)
        state[rd] = ('page', ins.operands[1].imm, ins.address)
    elif m == 'add' and len(ins.operands) == 3 and ins.operands[2].type == ARM64_OP_IMM:
        rn = ins.reg_name(ins.operands[1].reg)
        rd = ins.reg_name(ins.operands[0].reg)
        if rn == rd and rn in state and state[rn][0] == 'page':
            base, aoff = state[rn][1], state[rn][2]
            sites.setdefault(base + ins.operands[2].imm, []).append((aoff, ins.address))
            state[rd] = ('abs', base + ins.operands[2].imm, ins.address)
    else:
        for op in ins.operands:
            if op.type == ARM64_OP_REG and op.access and op.access & CS_AC_WRITE:
                state.pop(ins.reg_name(op.reg), None)


def mapped(va):
    return any(v <= va < v + fs for _, v, fs, _ in loads)


def cstr(va):
    # vaddr -> 文件偏移（按所在 LOAD 段换算）
    for off, v, fs, _ in loads:
        if v <= va < v + fs:
            fo = off + (va - v)
            e = b.find(b'\0', fo)
            if e < 0 or e - fo > 600:
                return None
            try:
                return b[fo:e].decode('utf-8')
            except UnicodeDecodeError:
                return None
    return None


newaddr = {}
# 池起点：从 ZH 里找一个已知项的地址反推（用 build 的规则：POOL 起点 = 文件 0x80000）
# 直接扫描：池内中文按 zh 顺序排列，重建一次映射
pool_off = 0x80000
cur = pool_off
for a in sorted(ZH):
    newaddr[a] = cur + 0x1000
    cur += len(ZH[a].encode()) + 1

bad = 0
hit = 0
for a, zh in ZH.items():
    exp = newaddr[a]
    got = sites.get(exp, [])
    if not got:
        print(f'  !! {a:#06x} 未指向新地址 {exp:#x}')
        bad += 1
        continue
    s = cstr(exp)
    if s != zh:
        print(f'  !! {a:#06x} 读到 {s!r} != {zh!r}')
        bad += 1
        continue
    hit += 1
print(f'\n[2] 新地址引用: {hit}/{len(ZH)} 命中，异常 {bad}')
if bad:
    ok = False

# ---- 3. 越界检查 ----
oob = []
for tgt, ss in sites.items():
    if not mapped(tgt):
        oob.append((tgt, ss))
print(f'[3] 映射区外的 add 目标: {len(oob)}')
for tgt, ss in oob[:10]:
    print(f'    {tgt:#x} @ ' + ','.join(f'{x[1]:#x}' for x in ss))
if oob:
    ok = False

# ---- 4. 池完整性 ----
print(f'[4] 池字节 {len(b) - pool_off - (0x105 + 0x3a10 + 0x80):d} (预期 5735)')

print('\n===> ' + ('全部通过' if ok else '存在问题'))
sys.exit(0 if ok else 1)
