#!/usr/bin/env python3
# patch_langos_emu.py — 给 LANGOS 加「开游戏时可选模拟器」
#
# 基线：v38 的 LANGOS（md5 33daa30a04ab309d64315c2b758cefc1）
#
# 改动：
#   1. 字段 ngpPickedEmu（本次选中的包名）
#   2. access$ngpLaunch（内部类回调入口）
#   3. ngpEmuCandidates(platformId) —— 候选表 ∩ 已安装，元素 "包名|显示名"
#   4. ngpEmuChooser(platformId, game) —— ≥2 个候选时弹 AlertDialog
#   5. getStandaloneEmulator 开头优先返回 ngpPickedEmu
#   6. startGame 插入钩子
#   7. 新建 NativeActivity$NgpEmuPickListener.smali
import os
import sys

BASE = '/tmp/lg38/out/smali_classes3/com/retrofront'
NA = os.path.join(BASE, 'NativeActivity.smali')

CANDIDATES = [
    ('ps2', 'xyz.aethersx2.android|NetherSX2 / AetherSX2;com.armsx2|ARMSX2'),
    ('3ds', 'com.gammaos.azaharsf|Azahar(内置);org.azahar.azahar|Azahar;'
            'org.citra.emu|Citra;org.citra.citra_emu|Citra MMJ'),
    ('psp', 'org.ppsspp.ppsspp|PPSSPP;org.ppsspp.ppssppgold|PPSSPP Gold'),
    ('nds', 'com.dsemu.drastic|DraStic;com.gammaos.drasticsf|DraStic(内置)'),
]


def esc(s):
    return s.replace('\\', '\\\\').replace('"', '\\"')


def build_table_chain():
    out = []
    n = len(CANDIDATES)
    for i, (pid, table) in enumerate(CANDIDATES):
        out.append(
            f'    const-string v0, "{pid}"\n\n'
            f'    invoke-virtual {{p1, v0}}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z\n\n'
            f'    move-result v0\n\n'
            f'    if-eqz v0, :ngp_tab{i + 1}\n\n'
            f'    const-string v9, "{esc(table)}"\n\n'
            f'    goto :ngp_tab_have\n\n'
            f'    :ngp_tab{i + 1}')
        if i + 1 == n:
            # 所有平台都不匹配：直接返回 null，避免 v9 出现「int 0 / String」两种类型
            out.append('    const/4 v1, 0x0\n\n    return-object v1')
    return '\n\n'.join(out)


def build_candidates():
    return f'''.method private final ngpEmuCandidates(Ljava/lang/String;)[Ljava/lang/String;
    .locals 12
    .param p1, "platformId"    # Ljava/lang/String;

    # NGP45HT：每个平台的候选模拟器表，元素 "包名|显示名"，分号分隔。
    # 只返回本机真的装了的，没装的不进选择框。
{build_table_chain()}

    :ngp_tab_have
    new-instance v8, Ljava/util/ArrayList;

    invoke-direct {{v8}}, Ljava/util/ArrayList;-><init>()V

    const-string v0, ";"

    invoke-virtual {{v9, v0}}, Ljava/lang/String;->split(Ljava/lang/String;)[Ljava/lang/String;

    move-result-object v7

    array-length v6, v7

    const/4 v5, 0x0

    :ngp_cand_loop
    if-ge v5, v6, :ngp_cand_end

    aget-object v4, v7, v5

    const/16 v0, 0x7c

    invoke-virtual {{v4, v0}}, Ljava/lang/String;->indexOf(I)I

    move-result v3

    if-ltz v3, :ngp_cand_next

    const/4 v0, 0x0

    invoke-virtual {{v4, v0, v3}}, Ljava/lang/String;->substring(II)Ljava/lang/String;

    move-result-object v2

    invoke-direct {{p0, v2}}, Lcom/retrofront/NativeActivity;->isPackageInstalled(Ljava/lang/String;)Z

    move-result v0

    if-eqz v0, :ngp_cand_next

    invoke-virtual {{v8, v4}}, Ljava/util/ArrayList;->add(Ljava/lang/Object;)Z

    move-result v0

    :ngp_cand_next
    add-int/lit8 v5, v5, 0x1

    goto :ngp_cand_loop

    :ngp_cand_end
    invoke-virtual {{v8}}, Ljava/util/ArrayList;->size()I

    move-result v0

    if-eqz v0, :ngp_cand_null

    new-array v1, v0, [Ljava/lang/String;

    invoke-virtual {{v8, v1}}, Ljava/util/ArrayList;->toArray([Ljava/lang/Object;)[Ljava/lang/Object;

    move-result-object v1

    check-cast v1, [Ljava/lang/String;

    return-object v1

    :ngp_cand_null
    const/4 v1, 0x0

    return-object v1
.end method
'''


def build_chooser():
    return '''.method private final ngpEmuChooser(Ljava/lang/String;Lcom/retrofront/data/Game;)Z
    .locals 12
    .param p1, "platformId"    # Ljava/lang/String;
    .param p2, "game"    # Lcom/retrofront/data/Game;

    # NGP45HT：同一平台装了多个模拟器时弹框让玩家选。
    # 返回 true = 已弹框，后续由回调启动，调用方必须直接 return。
    const/4 v0, 0x0

    iput-object v0, p0, Lcom/retrofront/NativeActivity;->ngpPickedEmu:Ljava/lang/String;

    # 「最近游玩 / 收藏」屏的 currentPlatform 是 recent / favorite，查不到候选表，
    # 必须用游戏自己的 platformId。
    invoke-virtual {p2}, Lcom/retrofront/data/Game;->getPlatformId()Ljava/lang/String;

    move-result-object v9

    if-nez v9, :ngp_chooser_pid

    move-object v9, p1

    :ngp_chooser_pid
    invoke-direct {p0, v9}, Lcom/retrofront/NativeActivity;->ngpEmuCandidates(Ljava/lang/String;)[Ljava/lang/String;

    move-result-object v1

    const/4 v11, 0x0

    # 诊断日志：候选数量
    new-instance v0, Ljava/lang/StringBuilder;

    invoke-direct {v0}, Ljava/lang/StringBuilder;-><init>()V

    const-string v3, "chooser platform="

    invoke-virtual {v0, v3}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    move-result-object v0

    invoke-virtual {v0, v9}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    move-result-object v0

    const-string v3, " cand="

    invoke-virtual {v0, v3}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    move-result-object v0

    if-eqz v1, :ngp_log_zero

    array-length v3, v1

    goto :ngp_log_n

    :ngp_log_zero
    const/4 v3, 0x0

    :ngp_log_n
    invoke-virtual {v0, v3}, Ljava/lang/StringBuilder;->append(I)Ljava/lang/StringBuilder;

    move-result-object v0

    const-string v3, " azh="

    invoke-virtual {v0, v3}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    move-result-object v0

    const-string v3, "com.gammaos.azaharsf"

    invoke-direct {p0, v3}, Lcom/retrofront/NativeActivity;->isPackageInstalled(Ljava/lang/String;)Z

    move-result v3

    invoke-virtual {v0, v3}, Ljava/lang/StringBuilder;->append(Z)Ljava/lang/StringBuilder;

    move-result-object v0

    const-string v3, " armsx2="

    invoke-virtual {v0, v3}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    move-result-object v0

    const-string v3, "com.armsx2"

    invoke-direct {p0, v3}, Lcom/retrofront/NativeActivity;->isPackageInstalled(Ljava/lang/String;)Z

    move-result v3

    invoke-virtual {v0, v3}, Ljava/lang/StringBuilder;->append(Z)Ljava/lang/StringBuilder;

    move-result-object v0

    invoke-virtual {v0}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;

    move-result-object v0

    const-string v3, "NGP_EMU"

    invoke-static {v3, v0}, Landroid/util/Log;->d(Ljava/lang/String;Ljava/lang/String;)I

    if-eqz v1, :ngp_choose_zero

    array-length v2, v1

    if-eqz v2, :ngp_choose_zero

    const/4 v0, 0x1

    if-ne v2, v0, :ngp_choose_multi

    # 只有一个已安装：直接用，不打扰玩家
    aget-object v3, v1, v11

    const/16 v4, 0x7c

    invoke-virtual {v3, v4}, Ljava/lang/String;->indexOf(I)I

    move-result v4

    invoke-virtual {v3, v11, v4}, Ljava/lang/String;->substring(II)Ljava/lang/String;

    move-result-object v4

    iput-object v4, p0, Lcom/retrofront/NativeActivity;->ngpPickedEmu:Ljava/lang/String;

    return v11

    :ngp_choose_zero
    return v11

    :ngp_choose_multi
    new-array v5, v2, [Ljava/lang/CharSequence;

    new-array v6, v2, [Ljava/lang/String;

    const/4 v3, 0x0

    :ngp_choose_loop
    if-ge v3, v2, :ngp_choose_loop_end

    aget-object v4, v1, v3

    const/16 v7, 0x7c

    invoke-virtual {v4, v7}, Ljava/lang/String;->indexOf(I)I

    move-result v7

    invoke-virtual {v4, v11, v7}, Ljava/lang/String;->substring(II)Ljava/lang/String;

    move-result-object v8

    aput-object v8, v6, v3

    add-int/lit8 v7, v7, 0x1

    invoke-virtual {v4, v7}, Ljava/lang/String;->substring(I)Ljava/lang/String;

    move-result-object v8

    aput-object v8, v5, v3

    add-int/lit8 v3, v3, 0x1

    goto :ngp_choose_loop

    :ngp_choose_loop_end
    new-instance v4, Ljava/lang/StringBuilder;

    invoke-direct {v4}, Ljava/lang/StringBuilder;-><init>()V

    const-string v7, "\\u9009\\u62e9\\u6a21\\u62df\\u5668\\uff08"

    invoke-virtual {v4, v7}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    move-result-object v4

    invoke-virtual {v4, v9}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    move-result-object v4

    const-string v7, "\\uff09"

    invoke-virtual {v4, v7}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    move-result-object v4

    invoke-virtual {v4}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;

    move-result-object v4

    new-instance v7, Landroid/app/AlertDialog$Builder;

    invoke-direct {v7, p0}, Landroid/app/AlertDialog$Builder;-><init>(Landroid/content/Context;)V

    invoke-virtual {v7, v4}, Landroid/app/AlertDialog$Builder;->setTitle(Ljava/lang/CharSequence;)Landroid/app/AlertDialog$Builder;

    move-result-object v7

    new-instance v8, Lcom/retrofront/NativeActivity$NgpEmuPickListener;

    invoke-direct {v8, p0, p2, v6}, Lcom/retrofront/NativeActivity$NgpEmuPickListener;-><init>(Lcom/retrofront/NativeActivity;Lcom/retrofront/data/Game;[Ljava/lang/String;)V

    invoke-virtual {v7, v5, v8}, Landroid/app/AlertDialog$Builder;->setItems([Ljava/lang/CharSequence;Landroid/content/DialogInterface$OnClickListener;)Landroid/app/AlertDialog$Builder;

    move-result-object v7

    invoke-virtual {v7}, Landroid/app/AlertDialog$Builder;->show()Landroid/app/AlertDialog;

    const/4 v0, 0x1

    return v0
.end method
'''


LISTENER = '''.class Lcom/retrofront/NativeActivity$NgpEmuPickListener;
.super Ljava/lang/Object;
.implements Landroid/content/DialogInterface$OnClickListener;

.source "NativeActivity.kt"


# instance fields
.field final synthetic activity:Lcom/retrofront/NativeActivity;

.field final synthetic game:Lcom/retrofront/data/Game;

.field final synthetic pkgs:[Ljava/lang/String;


# direct methods
.method public constructor <init>(Lcom/retrofront/NativeActivity;Lcom/retrofront/data/Game;[Ljava/lang/String;)V
    .locals 0

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    iput-object p1, p0, Lcom/retrofront/NativeActivity$NgpEmuPickListener;->activity:Lcom/retrofront/NativeActivity;

    iput-object p2, p0, Lcom/retrofront/NativeActivity$NgpEmuPickListener;->game:Lcom/retrofront/data/Game;

    iput-object p3, p0, Lcom/retrofront/NativeActivity$NgpEmuPickListener;->pkgs:[Ljava/lang/String;

    return-void
.end method


# virtual methods
.method public onClick(Landroid/content/DialogInterface;I)V
    .locals 3

    iget-object v0, p0, Lcom/retrofront/NativeActivity$NgpEmuPickListener;->pkgs:[Ljava/lang/String;

    aget-object v1, v0, p2

    iget-object v0, p0, Lcom/retrofront/NativeActivity$NgpEmuPickListener;->activity:Lcom/retrofront/NativeActivity;

    iget-object v2, p0, Lcom/retrofront/NativeActivity$NgpEmuPickListener;->game:Lcom/retrofront/data/Game;

    invoke-static {v0, v1, v2}, Lcom/retrofront/NativeActivity;->access$ngpLaunch(Lcom/retrofront/NativeActivity;Ljava/lang/String;Lcom/retrofront/data/Game;)V

    invoke-interface {p1}, Landroid/content/DialogInterface;->dismiss()V

    return-void
.end method
'''


MANIFEST = '/tmp/lg38/out/AndroidManifest.xml'


def patch_manifest():
    """Android 11+ 包可见性：不在 <queries> 里的包，getPackageInfo 会抛
    NameNotFoundException，isPackageInstalled 恒为 false。补上候选表里的包。"""
    s = open(MANIFEST, encoding='utf-8').read()
    need = ['com.gammaos.azaharsf', 'com.gammaos.drasticsf', 'com.armsx2',
            'org.azahar.azahar', 'org.ppsspp.ppssppgold']
    add = ''.join(f'        <package android:name="{p}"/>\n'
                  for p in need if f'android:name="{p}"' not in s)
    if not add:
        print('manifest queries already complete')
        return
    s = s.replace('    </queries>', add + '    </queries>', 1)
    open(MANIFEST, 'w', encoding='utf-8').write(s)
    print('manifest queries +=', add.count('<package'))


def main():
    patch_manifest()
    src = open(NA, encoding='utf-8').read()

    a_field = '.field private final timeUpdateRunnable:Lcom/retrofront/NativeActivity$timeUpdateRunnable$1;'
    a_ha = '.method private final hasAllFilesAccess()Z'
    a_gse = '''.method private final getStandaloneEmulator(Ljava/lang/String;)Ljava/lang/String;
    .locals 1
    .param p1, "platformId"    # Ljava/lang/String;

    .line 1879
    invoke-virtual {p1}, Ljava/lang/String;->hashCode()I'''
    a_sg = '''    .line 1798
    invoke-direct {v1, v10}, Lcom/retrofront/NativeActivity;->getStandaloneEmulator(Ljava/lang/String;)Ljava/lang/String;'''

    for name, a in (('field', a_field), ('hasAllFilesAccess', a_ha),
                    ('getStandaloneEmulator', a_gse), ('startGame', a_sg)):
        if a not in src:
            print(f'!! 锚点缺失: {name}')
            return 1

    if 'ngpPickedEmu:Ljava/lang/String;' in src:
        print('已打过补丁')
        return 0

    src = src.replace(a_field,
                      '# NGP45HT: 玩家在「选择模拟器」弹窗里选中的包名\n'
                      '.field private ngpPickedEmu:Ljava/lang/String;\n\n' + a_field, 1)

    block = ('''.method public static final synthetic access$ngpLaunch(Lcom/retrofront/NativeActivity;Ljava/lang/String;Lcom/retrofront/data/Game;)V
    .locals 0
    .param p0, "$this"    # Lcom/retrofront/NativeActivity;
    .param p1, "packageName"    # Ljava/lang/String;
    .param p2, "game"    # Lcom/retrofront/data/Game;

    invoke-direct {p0, p1, p2}, Lcom/retrofront/NativeActivity;->launchWithStandaloneEmulator(Ljava/lang/String;Lcom/retrofront/data/Game;)V

    return-void
.end method

''' + build_candidates() + '\n' + build_chooser() + '\n')
    src = src.replace(a_ha, block + a_ha, 1)

    src = src.replace(a_gse, '''.method private final getStandaloneEmulator(Ljava/lang/String;)Ljava/lang/String;
    .locals 3
    .param p1, "platformId"    # Ljava/lang/String;

    # NGP45HT: 玩家在弹窗里选过的模拟器优先于硬编码默认值
    iget-object v1, p0, Lcom/retrofront/NativeActivity;->ngpPickedEmu:Ljava/lang/String;

    if-eqz v1, :ngp_no_pick

    invoke-virtual {v1}, Ljava/lang/String;->length()I

    move-result v2

    if-eqz v2, :ngp_no_pick

    return-object v1

    :ngp_no_pick
    .line 1879
    invoke-virtual {p1}, Ljava/lang/String;->hashCode()I''', 1)

    src = src.replace(a_sg, '''    # NGP45HT: 多个模拟器时先让玩家选，选完由回调启动，本方法直接返回
    invoke-direct {v1, v10, v2}, Lcom/retrofront/NativeActivity;->ngpEmuChooser(Ljava/lang/String;Lcom/retrofront/data/Game;)Z

    move-result v13

    if-eqz v13, :ngp_chooser_go

    return-void

    :ngp_chooser_go
    .line 1798
    invoke-direct {v1, v10}, Lcom/retrofront/NativeActivity;->getStandaloneEmulator(Ljava/lang/String;)Ljava/lang/String;''', 1)

    open(NA, 'w', encoding='utf-8').write(src)
    open(os.path.join(BASE, 'NativeActivity$NgpEmuPickListener.smali'), 'w',
         encoding='utf-8').write(LISTENER)
    print('OK patched')
    return 0


if __name__ == '__main__':
    sys.exit(main())
