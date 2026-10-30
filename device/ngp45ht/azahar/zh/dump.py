#!/usr/bin/env python3
# 反汇编辅助工具（名字不能叫 dis.py，会遮蔽标准库）
import sys, struct
from capstone import *

BIN = '/home/liang/rainject/azahar-zh/azahar-nano'
b = open(BIN, 'rb').read()

# 段映射：用 program header 判断可执行范围
TEXT_OFF, TEXT_ADDR, TEXT_SIZE = 0x1b000, 0x1b000, 0x52cf0

def disas(start, end):
    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    md.detail = False
    code = b[start:end]
    for i in md.disasm(code, start):
        # 标注 adrp/add 目标附近的字符串
        print(f'{i.address:6x}: {i.mnemonic}\t{i.op_str}')

def cstr(vaddr):
    off = vaddr
    if off < 0 or off >= len(b):
        return None
    e = b.find(b'\0', off)
    if e < 0 or e - off > 300:
        return None
    try:
        return b[off:e].decode('utf-8')
    except UnicodeDecodeError:
        return None

if __name__ == '__main__':
    a = int(sys.argv[1], 16)
    l = int(sys.argv[2], 16) if len(sys.argv) > 2 else 0x200
    disas(a, a + l)
