#!/bin/bash
# 构建 NGP 性能悬浮窗 APK（无需 Gradle）
set -euo pipefail

SDK=/home/liang/android-build
BT=$SDK/android-14
AJAR=$SDK/android-34/android.jar
export JAVA_HOME=$SDK/jdk-17.0.20.1+1
export PATH=$JAVA_HOME/bin:$PATH

SRC=/home/liang/rainject/ngp-overlay
OUT=$SRC/build
PROJ=$SRC

command rm -rf "$OUT"
mkdir -p "$OUT/classes" "$OUT/dex"

echo "[1/6] aapt2 link"
"$BT/aapt2" link \
    -o "$OUT/app-unsigned.apk" \
    -I "$AJAR" \
    --manifest "$PROJ/AndroidManifest.xml" \
    --min-sdk-version 29 \
    --target-sdk-version 33 \
    --version-code 1 --version-name 1.0

echo "[2/6] javac"
find "$PROJ/src" -name '*.java' > "$OUT/sources.txt"
javac -source 11 -target 11 -nowarn -encoding UTF-8 \
    -classpath "$AJAR" \
    -d "$OUT/classes" @"$OUT/sources.txt"

echo "[3/6] d8"
"$BT/d8" --lib "$AJAR" --min-api 29 --output "$OUT/dex" \
    $(find "$OUT/classes" -name '*.class')

echo "[4/6] 打包 classes.dex"
( cd "$OUT/dex" && zip -q -j "$OUT/app-unsigned.apk" classes.dex )

echo "[5/6] zipalign"
"$BT/zipalign" -f 4 "$OUT/app-unsigned.apk" "$OUT/app-aligned.apk"

echo "[6/6] 签名"
KS=$SRC/ngp.keystore
if [ ! -f "$KS" ]; then
    keytool -genkeypair -keystore "$KS" -alias ngp -keyalg RSA -keysize 2048 \
        -validity 10000 -storepass ngp12345 -keypass ngp12345 \
        -dname "CN=NGP45HT, OU=ngp, O=ngp, L=-, S=-, C=CN" >/dev/null 2>&1
fi
"$BT/apksigner" sign \
    --ks "$KS" --ks-key-alias ngp \
    --ks-pass pass:ngp12345 --key-pass pass:ngp12345 \
    --out "$PROJ/ngp-overlay.apk" "$OUT/app-aligned.apk"

"$BT/apksigner" verify --print-certs "$PROJ/ngp-overlay.apk" | head -3
ls -la "$PROJ/ngp-overlay.apk"
echo "OK"
