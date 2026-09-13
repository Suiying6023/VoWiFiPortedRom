#!/usr/bin/env bash
# Build floss-ims the v27 way: link a hand-written manifest with aapt2, compile
# our sources into one self-contained dex, and assemble the two with pack_apk.py.
#
# This replaces the v26 pipeline (build_floss.sh), which swapped classes.dex
# inside the upstream compiled APK and binary-patched its AXML. That could only
# replace strings in the manifest's string pool, never add them, so every new
# permission cost an existing one -- RECORD_AUDIO was sacrificed for INTERNET,
# which is what made outgoing calls impossible. Here the manifest is source, so
# permissions are just declared.
#
# Usage: bash build_floss_v27.sh <version-suffix>       e.g. 28  -> floss-ims-v28.apk
set -euo pipefail

VER="${1:?usage: build_floss_v27.sh <version-suffix>}"
cd "$(dirname "$0")"

source "/d/Code/Claude Code/tools/env/toolchain.sh"

S=../ims-main/app/src/main/java
KOTLIN_STDLIB=$(ls ~/.gradle/wrapper/dists/gradle-*/*/gradle-*/lib/kotlin-stdlib-*.jar | tail -1)
# Pinned, not globbed: the cache also holds 1.6.4/1.9.0, and picking a different
# one silently changes ~9 kotlinx classes in the dex. v26 pinned the same jar.
COR="/c/Users/26928/.gradle/caches/modules-2/files-2.1/org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm/1.10.2/4a9f78ef49483748e2c129f3d124b8fa249dafbf/kotlinx-coroutines-core-jvm-1.10.2.jar"
ANDROID_JAR=$(ls /c/Users/26928/AppData/Local/Android/Sdk/platforms/*/android.jar | tail -1)
AAPT2=$(ls /c/Users/26928/AppData/Local/Android/Sdk/build-tools/*/aapt2.exe | tail -1)

# Fail loudly if a build input is missing. These are all session leftovers with
# no download source: losing one silently produced APKs containing the previous
# build's classes, which looks exactly like "my patch did not take effect".
for f in manifest/AndroidManifest.xml manifest/lib/arm64-v8a/librnnoise_jni.so \
         out3/META-INF/main.kotlin_module deps/android-system-shim.jar \
         ../ims-main/app/libs/android.jar ../ims-main/app/libs/ImsMediaFramework.jar \
         ../floss.keystore pack_apk.py; do
  [ -e "$f" ] || { echo "BUILD INPUT MISSING: $f" >&2; exit 1; }
done
for f in "$KOTLIN_STDLIB" "$COR" "$ANDROID_JAR" "$AAPT2"; do
  [ -e "$f" ] || { echo "BUILD INPUT MISSING: $f" >&2; exit 1; }
done

echo "== 1/5 aapt2 link (manifest -> skeleton apk) =="
"$AAPT2" link -o "$(cygpath -w manifest/base.apk)" \
  -I "$(cygpath -w "$ANDROID_JAR")" \
  --manifest "$(cygpath -w manifest/AndroidManifest.xml)" \
  --min-sdk-version 32 --target-sdk-version 28

echo "== 2/5 javac (PhhMmTelFeatureProtected) =="
rm -rf javaoutV && mkdir -p javaoutV
if ! "$JDK_HOME/bin/javac" -source 21 -target 21 -nowarn \
  -cp "$(cygpath -w ../ims-main/app/libs/android.jar)" \
  -d javaoutV "$S/me/phh/ims/PhhMmTelFeatureProtected.java" > javacV.log 2>&1; then
  echo "javac FAILED:" >&2; grep -viE "^Note:|警告|warning" javacV.log >&2; exit 1
fi

echo "== 3/5 kotlinc =="
CP="$(cygpath -w "$KOTLIN_STDLIB");$(cygpath -w ../ims-main/app/libs/android.jar);$(cygpath -w deps/android-system-shim.jar);$(cygpath -w ../ims-main/app/libs/ImsMediaFramework.jar);$(cygpath -w "$COR");$(cygpath -w javaoutV)"
rm -rf ktoutV && mkdir -p ktoutV
KT=$(ls "$S/me/phh/sip/"*.kt; ls "$S/me/phh/ims/"*.kt | grep -v MainActivity)
if ! kotlinc_jar -cp "$CP" -jvm-target 21 $KT -d ktoutV > kotlincV.log 2>&1; then
  echo "kotlinc FAILED:" >&2; grep -iE "error:" kotlincV.log >&2; exit 1
fi
[ -d ktoutV/me/phh/sip ] || { echo "kotlinc produced no classes" >&2; exit 1; }

echo "== 4/5 d8 (self-contained dex: our classes + kotlin stdlib + coroutines) =="
rm -rf outV && cp -r ktoutV outV
cp javaoutV/me/phh/ims/PhhMmTelFeatureProtected.class outV/me/phh/ims/
mkdir -p outV/META-INF && cp out3/META-INF/main.kotlin_module outV/META-INF/
# No SpillingKt shim here, unlike the v26 build. That shim existed because the
# APK carried upstream's old stdlib dex, which lacked the class. We now dex the
# full Kotlin 2.2.21 stdlib ourselves, so copying it in again is a duplicate
# class and d8 refuses.

find outV -name "*.class" | while read -r f; do cygpath -w "$f"; done > clVwin.txt
rm -rf dexV && mkdir -p dexV
# Unlike the v26 build, the stdlib and coroutines go IN (--classpath -> input):
# the APK no longer carries upstream's dex files, so nothing else provides them.
if ! d8w --min-api 30 --output "$(cygpath -w dexV)" \
  --lib "$(cygpath -w ../ims-main/app/libs/android.jar)" \
  "$(cygpath -w "$KOTLIN_STDLIB")" "$(cygpath -w "$COR")" \
  "@$(cygpath -w clVwin.txt)" > d8V.log 2>&1; then
  echo "d8 FAILED:" >&2; grep -iE "error" d8V.log >&2; exit 1
fi
[ -s dexV/classes.dex ] || { echo "d8 produced no classes.dex" >&2; exit 1; }

echo "== 5/5 pack + align + sign =="
python3 pack_apk.py manifest/base.apk dexV manifest/lib "fV-unsigned.apk"
zipalignw -p -f 4 fV-unsigned.apk fV-aligned.apk > /dev/null
apksignerw sign --ks ../floss.keystore --ks-pass pass:YOUR_KEYSTORE_PASSWORD --ks-key-alias floss \
  --out "floss-ims-v${VER}.apk" fV-aligned.apk

md5sum "floss-ims-v${VER}.apk"
"$AAPT2" dump permissions "floss-ims-v${VER}.apk"
