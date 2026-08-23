#!/usr/bin/env bash
# Build floss-ims from source: Kotlin+Java -> dex -> repack into targetSdk-28
# base (v28test/f17-unsigned.apk) -> align -> sign.
# Usage: ./build_floss.sh   (run from _fix/; outputs floss-ims-vN.apk)
set -e
source "/d/Code/Claude Code/tools/env/toolchain.sh"
cd "/d/Code/Claude Code/ksu-work/qns-study/floss-ims/_fix"

S="../ims-main/app/src/main/java"
if [ -z "$1" ]; then echo "usage: build_floss.sh <version-number>   e.g. 25" >&2; exit 2; fi
VER="v$1"

# Fail loudly if a build input is missing. These are all artifacts produced by
# earlier sessions, not checked-in sources, so a missing one used to yield a
# silently broken APK (the `cp ... || true` below).
COR="/c/Users/26928/.gradle/caches/modules-2/files-2.1/org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm/1.10.2/4a9f78ef49483748e2c129f3d124b8fa249dafbf/kotlinx-coroutines-core-jvm-1.10.2.jar"
for f in "v28test/f17-unsigned.apk" \
         "shim7/kotlin/coroutines/jvm/internal/SpillingKt.class" \
         "out3/META-INF/main.kotlin_module" \
         "deps/android-system-shim.jar" \
         "../ims-main/app/libs/android.jar" \
         "../ims-main/app/libs/ImsMediaFramework.jar" \
         "../floss.keystore" \
         "$COR"; do
  [ -e "$f" ] || { echo "BUILD INPUT MISSING: $f" >&2; exit 1; }
done

rm -rf javaoutX && mkdir -p javaoutX
# Note the pipefail-style guard: piping into grep would otherwise mask a compiler
# failure and we would happily package the previous build's classes.
if ! "$JDK_HOME/bin/javac" -source 21 -target 21 -nowarn \
  -cp "$(cygpath -w ../ims-main/app/libs/android.jar)" \
  -d javaoutX "$S/me/phh/ims/PhhMmTelFeatureProtected.java" > javacX.log 2>&1; then
  echo "javac FAILED:" >&2; grep -viE "^Note:|警告|warning" javacX.log >&2; exit 1
fi

CP="$(cygpath -w "$KOTLIN_STDLIB");$(cygpath -w ../ims-main/app/libs/android.jar);$(cygpath -w deps/android-system-shim.jar);$(cygpath -w ../ims-main/app/libs/ImsMediaFramework.jar);$(cygpath -w "$COR");$(cygpath -w javaoutX)"

rm -rf ktoutX && mkdir -p ktoutX
KT=$(ls "$S/me/phh/sip/"*.kt; ls "$S/me/phh/ims/"*.kt | grep -v MainActivity)
if ! kotlinc_jar -cp "$CP" -jvm-target 21 $KT -d ktoutX > kotlincX.log 2>&1; then
  echo "kotlinc FAILED:" >&2; grep -iE "error:" kotlincX.log >&2; exit 1
fi
# A compile that "succeeds" but emits nothing means the file list was wrong.
[ -d ktoutX/me/phh/sip ] || { echo "kotlinc produced no classes" >&2; exit 1; }

rm -rf outX && cp -r ktoutX outX
# All three are required, not optional: PhhMmTelFeatureProtected carries the
# capability reporting, SpillingKt is the Kotlin 2.2.21 stdlib class the bundled
# old stdlib lacks (NoClassDefFoundError at runtime without it), and the
# kotlin_module keeps the module metadata consistent.
cp javaoutX/me/phh/ims/PhhMmTelFeatureProtected.class outX/me/phh/ims/
mkdir -p outX/kotlin/coroutines/jvm/internal
cp shim7/kotlin/coroutines/jvm/internal/SpillingKt.class outX/kotlin/coroutines/jvm/internal/
mkdir -p outX/META-INF && cp out3/META-INF/main.kotlin_module outX/META-INF/

find outX -name "*.class" | while read -r f; do cygpath -w "$f"; done > clXwin.txt
rm -rf dexX && mkdir -p dexX
if ! d8w --min-api 30 --output "$(cygpath -w dexX)" --lib "$(cygpath -w ../ims-main/app/libs/android.jar)" \
  --classpath "$(cygpath -w "$KOTLIN_STDLIB")" --classpath "$(cygpath -w "$COR")" \
  --classpath "$(cygpath -w deps/android-system-shim.jar)" \
  "@$(cygpath -w clXwin.txt)" > d8X.log 2>&1; then
  echo "d8 FAILED:" >&2; grep -iE "error" d8X.log >&2; exit 1
fi
[ -s dexX/classes.dex ] || { echo "d8 produced no classes.dex" >&2; exit 1; }

python3 - "$VER" <<'PY'
import zipfile, os, sys
src, dst, newdex = "v28test/f17-unsigned.apk", "fX-unsigned.apk", "dexX/classes.dex"
if os.path.exists(dst): os.remove(dst)
data = open(newdex, "rb").read()
zin = zipfile.ZipFile(src); zout = zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED)
for item in zin.infolist():
    base = item.filename.split("/")[-1]
    if item.filename.startswith("META-INF/") and base.endswith((".RSA", ".SF", ".MF")): continue
    payload = data if item.filename == "classes.dex" else zin.read(item.filename)
    zi = zipfile.ZipInfo(item.filename, date_time=item.date_time)
    zi.compress_type = zipfile.ZIP_STORED if item.filename.endswith((".so", ".arsc")) else zipfile.ZIP_DEFLATED
    zi.external_attr = item.external_attr
    zout.writestr(zi, payload)
zout.close(); zin.close()
PY
zipalignw -p -f 4 fX-unsigned.apk fX-aligned.apk 2>&1 | head -1
apksignerw sign --ks /d/Code/Claude\ Code/ksu-work/qns-study/floss-ims/floss.keystore \
  --ks-pass pass:YOUR_KEYSTORE_PASSWORD --ks-key-alias floss --out "floss-ims-${VER}.apk" fX-aligned.apk 2>&1 | head -1
md5sum "floss-ims-${VER}.apk"