#!/system/bin/sh
set -u
DIR=/data/user_de/0/com.android.phone/files

echo '=== restore carrier configs from .bak.minqns ==='
for F in "$DIR"/carrierconfig-*23415.xml.bak.minqns; do
  [ -f "$F" ] || continue
  ORIG=$(echo "$F" | sed 's/\.bak\.minqns$//')
  cat "$F" > "$ORIG"
  rm -f "$F"
  echo "restored $ORIG"
done

echo '=== restart phone to reload ==='
killall com.android.phone 2>/dev/null
sleep 25

echo '--- override keys should be clean ---'
dumpsys carrier_config 2>/dev/null | sed -n '/^Phone Id = 1/,$p' \
  | grep -icE 'qualified_networks_service_(package|class)_override.*com.voxi.minqns' || echo '0 (clean)'

echo '--- WFC keys still present? ---'
dumpsys carrier_config 2>/dev/null | sed -n '/^Phone Id = 1/,$p' \
  | grep -iE 'carrier_wfc_ims_available_bool =' | head -2
