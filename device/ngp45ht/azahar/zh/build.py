#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""azahar-nano 菜单汉化构建器。

原理：
  1. 中文串池追加到文件末尾（页对齐），vaddr 由图尾 LOAD 段的 vaddr-offset 差推出；
  2. 扩展该 LOAD 段的 p_filesz / p_memsz 让新页被映射；
  3. 原文 .shstrtab / .gnu_debugdata / 节表搬到文件最末（不被映射），
     原位置清零 —— 因为扩展 filesz 后这段文件会落到 .bss 的地址上，
     不清零会把 .bss 变成垃圾初值；
  4. 重写所有引用该字面量的 adrp+add 指令对（aarch64 无 32 位绝对地址，
     不能原地放指针，只能改指令里的页/偏移）。
"""
import struct, sys, pickle, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zhtable import ZH

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'azahar-nano.orig')
DST = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'azahar-nano.zh')
PAGE = 0x1000

orig = open(SRC, 'rb').read()
buf = bytearray(orig)


# ---------- ELF 头 ----------
def hdr():
    return dict(
        e_phoff=struct.unpack_from('<Q', orig, 0x20)[0],
        e_shoff=struct.unpack_from('<Q', orig, 0x28)[0],
        e_phentsize=struct.unpack_from('<H', orig, 0x36)[0],
        e_phnum=struct.unpack_from('<H', orig, 0x38)[0],
        e_shentsize=struct.unpack_from('<H', orig, 0x3A)[0],
        e_shnum=struct.unpack_from('<H', orig, 0x3C)[0],
        e_shstrndx=struct.unpack_from('<H', orig, 0x3E)[0],
    )


H = hdr()


def phdrs():
    out = []
    for i in range(H['e_phnum']):
        o = H['e_phoff'] + i * H['e_phentsize']
        t, fl = struct.unpack_from('<II', orig, o)
        off, va, pa, fs, ms, al = struct.unpack_from('<QQQQQQ', orig, o + 8)
        out.append(dict(idx=i, off=o, type=t, flags=fl, offset=off,
                        vaddr=va, paddr=pa, filesz=fs, memsz=ms, align=al))
    return out


def shdrs():
    out = []
    for i in range(H['e_shnum']):
        o = H['e_shoff'] + i * H['e_shentsize']
        name, typ = struct.unpack_from('<II', orig, o)
        flags, addr, off, size = struct.unpack_from('<QQQQ', orig, o + 8)
        link, info = struct.unpack_from('<II', orig, o + 40)
        align, ent = struct.unpack_from('<QQ', orig, o + 48)
        out.append(dict(idx=i, off=o, name=name, type=typ, flags=flags,
                        addr=addr, offset=off, size=size, link=link,
                        info=info, align=align, ent=ent))
    return out


PH = phdrs()
SH = shdrs()
SHSTR = SH[H['e_shstrndx']]


def sname(sh):
    s = orig[SHSTR['offset'] + sh['name']:]
    return s[:s.index(b'\0')].decode()


# 最后那个有文件内容的 LOAD（.data + .bss）
tail = max((p for p in PH if p['type'] == 1 and p['filesz'] > 0),
           key=lambda p: p['offset'])
assert sname([s for s in SH if s['offset'] == tail['offset'] and s['type'] == 1][0]) == '.data'
DELTA = tail['vaddr'] - tail['offset']      # 0x1000


# ---------- 1. 建池 ----------
POOL_OFF = (len(orig) + PAGE - 1) // PAGE * PAGE       # 页对齐
pool = bytearray()
newaddr = {}
for a in sorted(ZH):
    s = ZH[a].encode('utf-8')
    newaddr[a] = POOL_OFF + len(pool) + DELTA
    pool += s + b'\0'
POOL_END = POOL_OFF + len(pool)
print(f'池: 文件 {POOL_OFF:#x}..{POOL_END:#x}  vaddr {POOL_OFF+DELTA:#x}..{POOL_END+DELTA:#x}  '
      f'{len(ZH)} 条 / {len(pool)} 字节')


# ---------- 2. 搬走 .shstrtab / .gnu_debugdata ----------
moved = {}
tailbuf = bytearray()


def move_section(s):
    """把节内容追加到 tailbuf，返回新 offset；原地址在文件里的数据稍后清零。"""
    data = orig[s['offset']:s['offset'] + s['size']]
    while len(tailbuf) % 8:
        tailbuf.append(0)
    newoff = POOL_END + len(tailbuf)
    moved[s['idx']] = dict(off=newoff, size=s['size'])
    tailbuf.extend(data)
    return newoff


for s in SH:
    if s['type'] == 8:      # SHT_NOBITS（.bss）无文件内容
        continue
    if s['flags'] & 0x2:    # SHF_ALLOC 不能搬
        continue
    move_section(s)

# ---------- 3. 组装文件 ----------
buf = bytearray(orig)
buf += b'\0' * (POOL_OFF - len(buf))              # 补齐到页边界
zero_from = tail['offset'] + tail['filesz']
buf[zero_from:POOL_OFF] = b'\0' * (POOL_OFF - zero_from)   # 原 shstrtab/debugdata/节表 归零
buf += pool

# tailbuf（shstrtab + debugdata）附在池后
buf += tailbuf

# 新节表放最末尾
while len(buf) % 64:
    buf.append(0)
NEW_SH_OFF = len(buf)
buf += b'\0' * (H['e_shnum'] * H['e_shentsize'])

# 写回节表（内容基本照抄，只改被搬走的 offset，并写到新位置）
sh_blob = bytearray(orig[H['e_shoff']:H['e_shoff'] + H['e_shnum'] * H['e_shentsize']])
for idx, m in moved.items():
    o = idx * H['e_shentsize']
    struct.pack_into('<Q', sh_blob, o + 24, m['off'])
buf[NEW_SH_OFF:NEW_SH_OFF + len(sh_blob)] = sh_blob

# ---------- 4. 扩展 tail LOAD ----------
new_filesz = POOL_END - tail['offset']
new_memsz = max(new_filesz, tail['memsz'])
struct.pack_into('<Q', buf, tail['off'] + 32, new_filesz)
struct.pack_into('<Q', buf, tail['off'] + 40, new_memsz)
struct.pack_into('<Q', buf, 0x28, NEW_SH_OFF)      # e_shoff
print(f'LOAD[{tail["idx"]}] filesz {tail["filesz"]:#x} -> {new_filesz:#x}, '
      f'memsz {tail["memsz"]:#x} -> {new_memsz:#x}')
print(f'新节表 @ {NEW_SH_OFF:#x}')


# ---------- 5. 改写引用 ----------
def enc_adrp(rd, pc, page):
    imm = (page - (pc & ~0xFFF)) >> 12
    assert -(1 << 20) <= imm < (1 << 20), 'adrp 越界'
    return 0x90000000 | ((imm & 3) << 29) | (((imm >> 2) & 0x7FFFF) << 5) | rd


def enc_add(rd, rn, imm):
    assert 0 <= imm <= 0xFFF
    return 0x91000000 | (imm << 10) | (rn << 5) | rd


refs = pickle.load(open('/tmp/azahar_refs.pkl', 'rb'))['add_sites']
patched = 0
missing = []
for a, zh in ZH.items():
    sites = refs.get(a, [])
    if not sites:
        missing.append(hex(a))
        continue
    tgt = newaddr[a]
    for adrp_off, add_off in sites:
        w1 = struct.unpack_from('<I', orig, adrp_off)[0]
        w2 = struct.unpack_from('<I', orig, add_off)[0]
        rd1 = w1 & 0x1F
        rd2 = w2 & 0x1F
        rn2 = (w2 >> 5) & 0x1F
        assert rd1 == rd2 == rn2, f'寄存器不一致 @{adrp_off:x}'
        struct.pack_into('<I', buf, adrp_off, enc_adrp(rd1, adrp_off, tgt & ~0xFFF))
        struct.pack_into('<I', buf, add_off, enc_add(rd2, rn2, tgt & 0xFFF))
        patched += 1
print(f'改写 {patched} 条指令，覆盖 {len(ZH)-len(missing)} 条字符串')
if missing:
    print('!! 无引用（未生效）:', missing)


# ---------- 6. 字形图集 1024 -> 2048 ----------
# 中文字形数量是英文的十几倍。atlas 只有 1024x1024，一页菜单就快满，
# loadGlyph 里装不下时调 resetAtlas() 回收：glyph 表被清空，可已经 emit 到
# vertex buffer 的 UV 还指着旧位置，新字形重新分配后覆盖过去 —— 菜单上就出现
# 半截汉字 / 乱码（"HLE 后面有乱码" 就是这个）。
# 这里把图集尺寸、四处边界判断、UV 归一化系数一起翻倍。
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
_md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)

def _patch_bits(off, mask, val):
    w = struct.unpack_from('<I', orig, off)[0]
    new = (w & ~mask) | val
    struct.pack_into('<I', buf, off, new)
    txt = ' ; '.join(f'{i.mnemonic} {i.op_str}'
                     for i in _md.disasm(struct.pack('<I', new), off))
    print(f'  {off:#06x}: {w:08x} -> {new:08x}  {txt}')

print('atlas 2048:')
_patch_bits(0x6798c, 0xFFFF << 5, 0x800 << 5)     # mov w3, #0x400  (glTexImage2D 宽)
_patch_bits(0x67990, 0xFFFF << 5, 0x800 << 5)     # mov w4, #0x400  (高)
_patch_bits(0x67bac, 0xFFF << 10, 0x7FF << 10)    # cmp w8,  #0x3ff
_patch_bits(0x67bb8, 0xFFF << 10, 0x7FF << 10)    # cmp w23, #0x3ff
_patch_bits(0x67bd0, 0xFFF << 10, 0x800 << 10)    # cmp w8,  #0x400
_patch_bits(0x67c20, 0xFFF << 10, 0x801 << 10)    # cmp w8,  #0x401
_patch_bits(0x67c9c, (0xFFFF << 5) | (3 << 21),   # mov w8, #0x3a800000 (1/1024)
            (0x3A00 << 5) | (1 << 21))            #      -> #0x3a000000 (1/2048)
_patch_bits(0x67cdc, 0x3F << 10, 53 << 10)  # scvtf s0,w8,#0xa -> #0xb (imm6 = 64-fbits)
_patch_bits(0x67cec, 0x3F << 10, 53 << 10)

open(DST, 'wb').write(buf)
os.chmod(DST, 0o755)
print(f'输出 {DST}  {len(buf)} 字节')
