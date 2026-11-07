#!/usr/bin/env bash
# build_v42_local.sh — V42: LANGOS 3.7.1 + 官方 Azahar / ARMSX2 + V39 键位 + HDMI/EEROMS 修复
# 基线：/root/ngp-v41/v41.img，只改 p5 vendor；首启由 ngp-fixup.sh 安装 APK。
set -euo pipefail

SRC=/root/ngp-v41/v41.img
WORK=/root/ngp-v42
FILES=/mnt/e/ngp45ht/v42/files
IMG=$WORK/v42.img
VEN_OFF=3686793216
VEN_SIZE=602931200

say() { echo "### $*"; }
mkdir -p "$WORK"
cd "$WORK"

say "copy v41 -> v42"
cp -f "$SRC" "$IMG"

say "extract p5"
dd if="$IMG" of=vendor.img bs=4M iflag=skip_bytes,count_bytes skip="$VEN_OFF" count="$VEN_SIZE" status=none
sync

say "context value files"
printf 'u:object_r:vendor_file:s0\0' > ctx_vendor_file
printf 'u:object_r:vendor_configs_file:s0\0' > ctx_vendor_configs_file
printf 'u:object_r:vendor_keylayout_file:s0\0' > ctx_vendor_keylayout_file

write_file() {
    local src="$1" dst="$2" mode="$3" gid="$4" ctx="$5"
    debugfs -w -R "rm $dst" vendor.img >/dev/null 2>&1 || true
    debugfs -w -R "write $src $dst" vendor.img >/dev/null
    debugfs -w -R "sif $dst mode $mode" vendor.img >/dev/null
    debugfs -w -R "sif $dst uid 0" vendor.img >/dev/null
    debugfs -w -R "sif $dst gid $gid" vendor.img >/dev/null
    debugfs -w -R "ea_rm $dst security.selinux" vendor.img >/dev/null 2>&1 || true
    debugfs -w -R "ea_set -f $ctx $dst security.selinux" vendor.img >/dev/null
}

say "V39 side keys + HDMI + EEROMS + fixup"
write_file "$FILES/adc-keys-ngp.kl"      /usr/keylayout/adc-keys-ngp.kl 0100644 0 ctx_vendor_keylayout_file
write_file "$FILES/ngp-navkey.sh"        /bin/ngp-navkey.sh               0100755 0 ctx_vendor_file
write_file "$FILES/ngp-navkey.rc"        /etc/init/ngp-navkey.rc          0100644 0 ctx_vendor_configs_file
write_file "$FILES/ngp-hdmi-ratio.sh"    /bin/ngp-hdmi-ratio.sh           0100755 0 ctx_vendor_file
write_file "$FILES/ngp-eeroms-link.sh"   /bin/ngp-eeroms-link.sh          0100755 0 ctx_vendor_file
write_file "$FILES/ngp-eeroms-link.rc"   /etc/init/ngp-eeroms-link.rc     0100644 0 ctx_vendor_configs_file
write_file "$FILES/ngp-fixup.sh"         /bin/ngp-fixup.sh                0100755 2000 ctx_vendor_file

say "LANGOS 3.7.1 + IME 0.1.1"
write_file "$FILES/LANGOS.apk"           /etc/ngp/LANGOS.apk              0100644 0 ctx_vendor_configs_file
write_file "$FILES/NgpIme-0.1.1.apk"     /etc/ngp/NgpIme-0.1.1.apk        0100644 0 ctx_vendor_configs_file

say "official Azahar + ARMSX2 APKs"
write_file "$FILES/Azahar-official-2126.2.apk" /etc/ngp/emulators/Azahar-official-2126.2.apk 0100644 0 ctx_vendor_configs_file
write_file "$FILES/ARMSX2-2.9.2-legacy-armv8.0.apk" /etc/ngp/emulators/ARMSX2-2.9.2-legacy-armv8.0.apk 0100644 0 ctx_vendor_configs_file

say "Azahar config preset"
debugfs -w -R "mkdir /etc/ngp/azahar" vendor.img >/dev/null 2>&1 || true
debugfs -w -R "sif /etc/ngp/azahar mode 040755" vendor.img >/dev/null 2>&1 || true
debugfs -w -R "sif /etc/ngp/azahar uid 0" vendor.img >/dev/null 2>&1 || true
debugfs -w -R "sif /etc/ngp/azahar gid 0" vendor.img >/dev/null 2>&1 || true
debugfs -w -R "ea_rm /etc/ngp/azahar security.selinux" vendor.img >/dev/null 2>&1 || true
debugfs -w -R "ea_set -f ctx_vendor_configs_file /etc/ngp/azahar security.selinux" vendor.img >/dev/null 2>&1 || true
write_file "$FILES/azahar-config.ini"    /etc/ngp/azahar/config.ini       0100644 0 ctx_vendor_configs_file

say "fsck vendor"
e2fsck -f -y vendor.img || true
e2fsck -f -n vendor.img

say "write vendor back"
dd if=vendor.img of="$IMG" bs=4M oflag=seek_bytes seek="$VEN_OFF" conv=notrunc status=none
sync

say "verify files"
for spec in \
    "/usr/keylayout/adc-keys-ngp.kl:$FILES/adc-keys-ngp.kl" \
    "/bin/ngp-navkey.sh:$FILES/ngp-navkey.sh" \
    "/etc/init/ngp-navkey.rc:$FILES/ngp-navkey.rc" \
    "/bin/ngp-hdmi-ratio.sh:$FILES/ngp-hdmi-ratio.sh" \
    "/bin/ngp-eeroms-link.sh:$FILES/ngp-eeroms-link.sh" \
    "/etc/init/ngp-eeroms-link.rc:$FILES/ngp-eeroms-link.rc" \
    "/bin/ngp-fixup.sh:$FILES/ngp-fixup.sh" \
    "/etc/ngp/LANGOS.apk:$FILES/LANGOS.apk" \
    "/etc/ngp/NgpIme-0.1.1.apk:$FILES/NgpIme-0.1.1.apk" \
    "/etc/ngp/emulators/Azahar-official-2126.2.apk:$FILES/Azahar-official-2126.2.apk" \
    "/etc/ngp/emulators/ARMSX2-2.9.2-legacy-armv8.0.apk:$FILES/ARMSX2-2.9.2-legacy-armv8.0.apk" \
    "/etc/ngp/azahar/config.ini:$FILES/azahar-config.ini"; do
    path=${spec%%:*}; src=${spec#*:}
    out=/tmp/check.$$
    rm -f "$out"
    debugfs -R "dump $path $out" "v42.img?offset=$VEN_OFF" >/dev/null 2>&1
    [ -f "$out" ] || { echo "MISSING $path"; exit 1; }
    a=$(md5sum "$out" | awk '{print $1}'); b=$(md5sum "$src" | awk '{print $1}')
    if [ "$a" = "$b" ]; then echo "OK  $path"; else echo "BAD $path $a != $b"; exit 1; fi
    rm -f "$out"
done

say "final p5 fsck"
dd if="$IMG" of=vendor-final.img bs=4M iflag=skip_bytes,count_bytes skip="$VEN_OFF" count="$VEN_SIZE" status=none
e2fsck -f -n vendor-final.img

say "GPT"
sgdisk -v "$IMG"

say "image hashes"
stat -c '%s %n' "$IMG"
md5sum "$IMG" | tee v42-img-md5.txt
sha256sum "$IMG" | tee v42-img-sha256.txt

say "xz"
rm -f v42.img.xz
xz -T0 -6 -c "$IMG" > v42.img.xz
stat -c '%s %n' v42.img.xz
sha256sum v42.img.xz | tee v42-xz-sha256.txt

say "BUILD_READY"
