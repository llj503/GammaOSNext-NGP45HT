#!/usr/bin/env python3
"""扫描 aarch64 .text，找 adrp+add 指向的字符串；输出每个字面量的引用点。
用于 azahar-nano 汉化：需要知道每条英文字面量被哪条 add 指令引用，
才能把 add 的 imm12 改指向新字符串池。"""
import struct, sys, collections

BIN = '/home/liang/rainject/azahar-zh/azahar-nano'
b = open(BIN, 'rb').read()

TEXT_OFF, TEXT_SIZE = 0x1b000, 0x52cf0
TEXT_END = TEXT_OFF + TEXT_SIZE


def cstr(vaddr, maxlen=400):
    if vaddr <= 0 or vaddr >= len(b):
        return None
    e = b.find(b'\0', vaddr)
    if e < 0 or e - vaddr > maxlen:
        return None
    try:
        return b[vaddr:e].decode('utf-8')
    except UnicodeDecodeError:
        return None


def scan():
    """返回 [(adrp_off, add_off, target_vaddr)]"""
    out = []
    for off in range(TEXT_OFF, TEXT_END, 4):
        w = struct.unpack_from('<I', b, off)[0]
        if (w & 0x9F000000) != 0x90000000:   # adrp
            continue
        immlo, immhi = (w >> 29) & 3, (w >> 5) & 0x7FFFF
        imm = (immhi << 2) | immlo
        if imm & (1 << 20):
            imm -= (1 << 21)
        rd = w & 0x1F
        base = (off & ~0xFFF) + (imm << 12)
        for k in range(1, 6):
            p = off + 4 * k
            if p >= TEXT_END:
                break
            w2 = struct.unpack_from('<I', b, p)[0]
            if (w2 & 0xFF800000) != 0x91000000:   # add imm
                continue
            rn, imm12, sh = (w2 >> 5) & 0x1F, (w2 >> 10) & 0xFFF, (w2 >> 22) & 3
            if rn != rd:
                continue
            val = imm12 << 12 if sh == 1 else imm12
            if base + val < len(b):
                out.append((off, p, base + val))
            break
    return out


if __name__ == '__main__':
    refs = scan()
    print(f'total refs: {len(refs)}', file=sys.stderr)
    # 按目标归类
    tbl = collections.defaultdict(list)
    for adrp_off, add_off, tgt in refs:
        tbl[tgt].append((adrp_off, add_off))
    # 只保留看起来是文本的
    rows = []
    for tgt, sites in sorted(tbl.items()):
        s = cstr(tgt)
        if not s or len(s) < 2:
            continue
        if not (0x9330 <= tgt < TEXT_OFF):   # 必须在 .rodata
            continue
        rows.append((tgt, s, sites))
    print(f'text literals: {len(rows)}', file=sys.stderr)
    with open('/home/liang/rainject/azahar-zh/refs.txt', 'w') as f:
        for tgt, s, sites in rows:
            f.write(f'{tgt:06x}\t{len(s):3d}\t{len(sites)}\t{s!r}\t' +
                    ' '.join(f'{a:x}/{d:x}' for a, d in sites) + '\n')
    print('wrote refs.txt')
