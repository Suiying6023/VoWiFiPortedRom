#!/system/bin/sh
set -u
DIR=/data/user_de/0/com.android.phone/files
PKG=com.voxi.minqns
CLS=com.voxi.minqns.MinQnsService

echo '=== sanity: MinQns installed? ==='
pm path "$PKG" || { echo 'MinQns NOT installed'; exit 1; }

echo '=== backup carrier configs once ==='
for F in "$DIR"/carrierconfig-*23415.xml; do
  case "$F" in *.bak.*) continue;; esac
  [ -f "$F" ] || continue
  if [ ! -f "$F.bak.minqns" ]; then
    cp -p "$F" "$F.bak.minqns"
    echo "backed up $F"
  fi
done

echo '=== inject QNS override into BOTH caches ==='
for F in "$DIR"/carrierconfig-com.android.carrierconfig-*23415.xml "$DIR"/carrierconfig-com.xiaomi.carrierconfig-*23415.xml; do
  case "$F" in *.bak.*) continue;; esac
  [ -f "$F" ] || continue
  TMP=/data/local/tmp/cc_minqns.xml
  sed -E -e '/name="carrier_qualified_networks_service_package_override_string"/d' \
         -e '/name="carrier_qualified_networks_service_class_override_string"/d' "$F" > "$TMP"
  sed -i 's#</bundle>#<string name="carrier_qualified_networks_service_package_override_string">'"$PKG"'</string>\
<string name="carrier_qualified_networks_service_class_override_string">'"$CLS"'</string>\
</bundle>#' "$TMP"
  cat "$TMP" > "$F"
  rm -f "$TMP"
  echo "$F -> $(grep -c 'qualified_networks_service_package_override' "$F")"
done

echo '=== restart phone, watch bind ==='
setprop log.tag.AccessNetworksManager VERBOSE 2>/dev/null || true
logcat -c 2>/dev/null
killall com.android.phone 2>/dev/null
echo 'waiting 35s...'
sleep 35

echo
echo '--- effective override (Phone Id=1) ---'
dumpsys carrier_config 2>/dev/null | sed -n '/^Phone Id = 1/,$p' \
  | grep -iE 'qualified_networks_service_(package|class)_override' | head -4

echo
echo '--- MinQns / bind logs ---'
logcat -b all -d -t 40000 2>/dev/null \
  | grep -iE 'MinQns|com.voxi.minqns|QualifiedNetworksService|AccessNetworksManager|Unable to start service' | tail -40

echo
echo '--- QTI QNS dumpsys tail ---'
dumpsys activity service vendor.qti.iwlan 2>/dev/null \
  | grep -E 'Pref network for apnType|apnMask|Calling updateQualifiedNetworkTypes' | tail -20

echo
echo '--- our service process/binding ---'
dumpsys activity services com.voxi.minqns 2>/dev/null | head -30
