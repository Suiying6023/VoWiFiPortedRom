#!/system/bin/sh
# Prove that vowifi_stack's service.sh can actually re-inject the carrier-config
# overrides, not just skip when they happen to already be there.
#
# On the first real boot the keys survived in the cache, so service.sh logged
# "already has all overrides, skipping" -- which means the injection path itself
# was still unproven. This strips the keys, runs the module's own service.sh, and
# checks they came back.
#
# Safe: the module keeps a .bak.vowifi_stack copy, and this script restores from
# its own snapshot if the injection fails.
set -u
DIR=/data/user_de/0/com.android.phone/files
SVC=/data/adb/modules/vowifi_stack/service.sh
SNAP=/data/local/tmp/.cc_test_snap
KEYS='config_ims_mmtel_package_override_string|carrier_data_service_wlan_package_override_string|carrier_data_service_wlan_class_override_string|carrier_network_service_wlan_package_override_string|carrier_network_service_wlan_class_override_string|carrier_qualified_networks_service_package_override_string|carrier_qualified_networks_service_class_override_string'

[ -f "$SVC" ] || { echo "FAIL: $SVC missing (module not installed?)"; exit 1; }
rm -rf "$SNAP"; mkdir -p "$SNAP"

echo "=== before ==="
N=0
for F in "$DIR"/carrierconfig-com.android.carrierconfig-*.xml "$DIR"/carrierconfig-com.xiaomi.carrierconfig-*.xml; do
  case "$F" in *'*'*) continue;; esac
  case "$F" in *.bak.*) continue;; esac
  [ -f "$F" ] || continue
  N=$((N+1))
  cp -p "$F" "$SNAP/$(basename "$F")"
  echo "  $(basename "$F"): $(grep -cE "$KEYS" "$F") keys"
done
[ "$N" != "0" ] || { echo "FAIL: no carrier config found"; exit 1; }

echo "=== stripping our keys ==="
for F in "$DIR"/carrierconfig-com.android.carrierconfig-*.xml "$DIR"/carrierconfig-com.xiaomi.carrierconfig-*.xml; do
  case "$F" in *'*'*) continue;; esac
  case "$F" in *.bak.*) continue;; esac
  [ -f "$F" ] || continue
  sed -E -e "/name=\"config_ims_mmtel_package_override_string\"/d" \
         -e "/name=\"config_ims_package_override_string\"/d" \
         -e "/name=\"carrier_data_service_wlan_package_override_string\"/d" \
         -e "/name=\"carrier_data_service_wlan_class_override_string\"/d" \
         -e "/name=\"carrier_network_service_wlan_package_override_string\"/d" \
         -e "/name=\"carrier_network_service_wlan_class_override_string\"/d" \
         -e "/name=\"carrier_qualified_networks_service_package_override_string\"/d" \
         -e "/name=\"carrier_qualified_networks_service_class_override_string\"/d" \
         "$F" > /data/local/tmp/.cc_strip && cat /data/local/tmp/.cc_strip > "$F"
  echo "  $(basename "$F"): now $(grep -cE "$KEYS" "$F") keys (want 0)"
done
rm -f /data/local/tmp/.cc_strip

echo "=== running the module's service.sh (skips its own boot wait) ==="
# service.sh waits for sys.boot_completed then sleeps 30s. Boot is long done, so
# the wait falls through immediately; the 30s sleep still applies.
sh "$SVC"

echo "=== after ==="
OK=1
for F in "$DIR"/carrierconfig-com.android.carrierconfig-*.xml "$DIR"/carrierconfig-com.xiaomi.carrierconfig-*.xml; do
  case "$F" in *'*'*) continue;; esac
  case "$F" in *.bak.*) continue;; esac
  [ -f "$F" ] || continue
  C=$(grep -cE "$KEYS" "$F")
  echo "  $(basename "$F"): $C keys (want 7)"
  [ "$C" = "7" ] || OK=0
done

if [ "$OK" = "1" ]; then
  echo "RESULT: PASS -- injection path works"
else
  echo "RESULT: FAIL -- restoring from snapshot"
  for B in "$SNAP"/*; do
    [ -f "$B" ] || continue
    cat "$B" > "$DIR/$(basename "$B")"
  done
  echo "  restored"
fi
