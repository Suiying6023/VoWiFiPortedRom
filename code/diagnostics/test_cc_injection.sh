#!/system/bin/sh
# Exercise injection on private COPIES of live caches. Live configuration is read-only.
SVC=${VOWIFI_MODULE_DIR:-/data/adb/modules/vowifi_stack}
. "$SVC/carrier-config.sh" || exit 1
TMP=$(mktemp -d /data/local/tmp/cc-test.XXXXXX) || exit 1
trap 'rm -f "$TMP/input" "$TMP/output" "$TMP/again" "$TMP/partial" "$TMP/restored"; rmdir "$TMP"' EXIT
trap 'exit 130' INT TERM HUP

N=0
for F in /data/user_de/0/com.android.phone/files/carrierconfig-*.xml; do
  [ -f "$F" ] || continue
  N=$((N+1))
  cp "$F" "$TMP/input" || exit 1
  cc_render "$TMP/input" "$TMP/output" || { echo "FAIL cache#$N: injection"; exit 1; }
  cc_render "$TMP/output" "$TMP/again" || exit 1
  cmp -s "$TMP/output" "$TMP/again" || { echo "FAIL cache#$N: idempotence"; exit 1; }
  sed '/name="carrier_network_service_wlan_class_override_string"/d' "$TMP/output" > "$TMP/partial"
  if cc_valid "$TMP/partial"; then
    echo "FAIL cache#$N: accepted missing class"; exit 1
  fi
  cc_render "$TMP/partial" "$TMP/again" || { echo "FAIL cache#$N: partial repair"; exit 1; }
  cc_remove_ours "$TMP/output" "$TMP/restored" || { echo "FAIL cache#$N: restore"; exit 1; }
  if grep -qE '>(me.phh.ims|com.google.android.iwlan[^<]*|com.voxi.minqns[^<]*)</string>' "$TMP/restored"; then
    echo "FAIL cache#$N: restored provider still points at module"; exit 1
  fi
  echo "PASS cache#$N: complete values, idempotence, missing-class repair"
  if [ -f "$F.bak.vowifi_stack" ]; then
    cc_remove_ours "$F.bak.vowifi_stack" "$TMP/restored" || exit 1
    if grep -qE '>(me.phh.ims|com.google.android.iwlan[^<]*|com.voxi.minqns[^<]*)</string>' "$TMP/restored"; then
      echo "FAIL backup#$N: module reference remains"; exit 1
    fi
    echo "PASS backup#$N: uninstall removes module references"
  fi
done
[ "$N" -gt 0 ] || { echo 'FAIL: no carrier caches'; exit 1; }
echo 'PASS: live caches unchanged'
