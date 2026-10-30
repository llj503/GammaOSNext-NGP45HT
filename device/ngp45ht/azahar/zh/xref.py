#!/usr/bin/env python3
"""精确分析：每条 adrp 被哪些 add 使用（数据流跟踪，寄存器级）。
输出 adrp -> set(target)，以及每个 target 被哪些 adrp 引用。
"""
import struct, collections, pickle
from capstone import *
from capstone.arm64 import ARM64_OP_REG, ARM64_OP_IMM

BIN = '/home/liang/rainject/azahar-zh/azahar-nano'
b = open(BIN, 'rb').read()
TEXT_OFF, TEXT_SIZE = 0x1b000, 0x52cf0
TEXT_END = TEXT_OFF + TEXT_SIZE

md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
md.detail = True

# 线性扫描：维护 reg -> (页基址, adrp_off)  或 (绝对地址, add_off)
state = {}
adrp_uses = collections.defaultdict(set)     # adrp_off -> {target...}
add_sites = collections.defaultdict(list)    # target -> [(adrp_off, add_off)]
last_adrp = {}                               # adrp_off -> imm base

for ins in md.disasm(b[TEXT_OFF:TEXT_END], TEXT_OFF):
    m = ins.mnemonic
    if m == 'adrp':
        rd = ins.reg_name(ins.operands[0].reg)
        tgt = ins.operands[1].imm
        state[rd] = ('page', tgt, ins.address)
        last_adrp[ins.address] = tgt
    elif m == 'add' and len(ins.operands) == 3 and ins.operands[2].type == ARM64_OP_IMM:
        rn = ins.reg_name(ins.operands[1].reg)
        rd = ins.reg_name(ins.operands[0].reg)
        imm = ins.operands[2].imm
        if rn in state and state[rn][0] == 'page' and rn == rd:
            base, aoff = state[rn][1], state[rn][2]
            target = base + imm
            adrp_uses[aoff].add(target)
            add_sites[target].append((aoff, ins.address))
            state[rd] = ('abs', target, ins.address)
    elif m in ('ldr', 'ldrb', 'ldrh', 'ldrsw') and len(ins.operands) >= 2 \
            and ins.operands[1].type == ARM64_OP_IMM and ins.operands[1].imm == ins.address:
        # ldr xN, [pc, #imm] 形式：literal load
        pass
    else:
        # 写寄存器则失效
        for op in ins.operands:
            if op.type == ARM64_OP_REG and op.access and op.access & CS_AC_WRITE:
                state.pop(ins.reg_name(op.reg), None)

pickle.dump({'adrp_uses': dict(adrp_uses), 'add_sites': dict(add_sites)},
            open('/tmp/azahar_refs.pkl', 'wb'))

multi = {k: v for k, v in adrp_uses.items() if len(v) > 1}
print('adrp 总数:', len(adrp_uses))
print('单目标 adrp:', len(adrp_uses) - len(multi))
print('多目标 adrp:', len(multi))
print('被引用 target 总数:', len(add_sites))
