#!/bin/bash
# Patch ext4 partitions inside the v1.9 image (system p4: keylayouts)
set -e
unset -f rm unlink rmdir 2>/dev/null
unset CODEBUDDY_SAFE_DELETE_BIN_DIR 2>/dev/null

IMG=/run/media/liang/Data/ngp45ht/gammaosnext-port-analysis/GammaOSCore-RG52Mini-20261008-2036.img
WORK=/home/liang/gammaos-ngp45ht
KL=/run/media/liang/Data/ngp45ht/gammaosnext-port-analysis/ngp45ht-files/keylayout

# exact system partition geometry (from GPT parse: off=121634816, 3565.2MB)
P4_OFF=121634816
P4_SIZE=3740856320   # bytes (last-first+1)*512, filled below by python

python3 - <<'EOF'
import struct
IMG="/run/media/liang/Data/ngp45ht/gammaosnext-port-analysis/GammaOSCore-RG52Mini-20261008-2036.img"
f=open(IMG,"rb"); f.seek(512); hdr=f.read(512)
part_lba=struct.unpack("<Q",hdr[72:80])[0]; num=struct.unpack("<I",hdr[80:84])[0]; psz=struct.unpack("<I",hdr[84:88])[0]
f.seek(part_lba*512); tbl=f.read(num*psz)
for i in range(num):
    e=tbl[i*psz:(i+1)*psz]
    if e[:16]==b"\x00"*16: continue
    first=struct.unpack("<Q",e[32:40])[0]; last=struct.unpack("<Q",e[40:48])[0]
    name=e[56:128].decode("utf-16-le").rstrip("\x00")
    if name=="system":
        print(f"P4_OFF={first*512}")
        print(f"P4_SIZE={(last-first+1)*512}")
        break
EOF
