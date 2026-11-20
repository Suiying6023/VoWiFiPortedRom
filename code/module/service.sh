#!/system/bin/sh
# Auto-slot VoWiFi stack boot script:
# - Injects VoWiFi overrides ONLY for non-CN (MCC != 460) SIM carrier configs
# - Restores stock IMS for CN (460*) SIMs so dual-SIM works regardless of slot
# - Enables WFC + WIFI_ONLY mode on active non-CN subscriptions
MODDIR=${0%/*}
. "$MODDIR/carrier-config.sh" || exit 1
LOG=/data/local/tmp/vowifi_stack_boot.log
DIR=/data/user_de/0/com.android.phone/files
PKGS="com.google.android.iwlan me.phh.ims com.voxi.minqns"

if [ -f "$LOG" ] && [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 400 ]; then
  tail -100 "$LOG" > "$LOG.trim" 2>/dev/null && mv "$LOG.trim" "$LOG"
fi

exec >> "$LOG" 2>&1
echo "=== $(date '+%m-%d %H:%M:%S') vowifi_stack service.sh ==="

i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 150 ]; do sleep 2; i=$((i+1)); done

i=0
while [ $i -lt 120 ]; do
  set -- "$DIR"/carrierconfig-*.xml
  [ -f "$1" ] && break
  sleep 2; i=$((i+1))
done
sleep 8

FOUND=0
CHANGED=0
for F in "$DIR"/carrierconfig-*.xml; do
  case "$F" in *'*'*) continue;; esac
  case "$F" in *.bak.*) continue;; esac
  [ -f "$F" ] || continue
  [ "$(grep -c '</bundle>' "$F")" != "0" ] || { echo "  skip $(basename "$F"): no </bundle>"; continue; }
  FOUND=$((FOUND+1))

  if [ ! -f "$F.bak.vowifi_stack" ]; then
    cp -p "$F" "$F.bak.vowifi_stack" || { echo "  backup failed; skipping cache"; continue; }
  fi

  BASE=$(basename "$F")
  if ! cc_is_foreign "$BASE"; then
      if cc_has_ours "$F"; then
        TMP=/data/local/tmp/.cc_vowifi.$$.xml
        if cc_remove_ours "$F" "$TMP" && cat "$TMP" > "$F"; then
          echo "  $BASE: cleaned overrides (CN/unassigned SIM -> stock IMS)"
          CHANGED=1
        fi
        rm -f "$TMP"
      else
        echo "  $BASE: CN/unassigned SIM, keeping stock IMS"
      fi
      continue
  fi

  if cc_valid "$F"; then
    echo "  $BASE: already has all overrides, skipping"
    continue
  fi

  TMP=/data/local/tmp/.cc_vowifi.$$.xml
  if cc_render "$F" "$TMP" && cat "$TMP" > "$F"; then
    echo "  $BASE: injected VoWiFi overrides (non-CN SIM)"
    CHANGED=1
  else
    echo "  $BASE: REFUSED invalid override result"
  fi
  rm -f "$TMP"
done

if [ "$FOUND" = "0" ]; then
  echo "  no carrier config cache found -- SIM not ready? overrides NOT applied"
fi

cc_enable_wfc

if [ "$CHANGED" = "1" ]; then
  PHONE_PID=$(pidof com.android.phone 2>/dev/null)
  . "$MODDIR/tools/phh_common.sh" || exit 1
  if [ -n "$PHONE_PID" ] && [ "$(phh_incall)" = "0" ]; then
    kill "$PHONE_PID" >/dev/null 2>&1
    echo "  restarted com.android.phone to reload carrier config"
  fi
fi

for P in $PKGS; do
  dumpsys deviceidle whitelist "+$P" >/dev/null 2>&1
done
echo "  deviceidle whitelist: $(dumpsys deviceidle whitelist 2>/dev/null | grep -cE 'phh\.ims|android\.iwlan|minqns')/3"

for P in $PKGS; do
  if [ "$(pm path "$P" 2>/dev/null | grep -c .)" = "0" ]; then
    echo "  !! $P NOT INSTALLED -- check priv-app SELinux label (must be system_file)"
  fi
done
if [ "$(dumpsys package me.phh.ims 2>/dev/null | grep -c 'CONNECTIVITY_USE_RESTRICTED_NETWORKS: granted=true')" = "0" ]; then
  echo "  !! IMS service lacks CONNECTIVITY_USE_RESTRICTED_NETWORKS"
fi

for TOOL in "$MODDIR"/tools/*.sh; do
  [ -f "$TOOL" ] || continue
  cp "$TOOL" "/data/local/tmp/$(basename "$TOOL")"
  chmod 755 "/data/local/tmp/$(basename "$TOOL")"
done

if [ ! -f "$MODDIR/watchdog.disabled" ] &&
   [ -f /data/local/tmp/phh_watchdog.sh ] &&
   [ "$(ps -A -o ARGS 2>/dev/null | grep -c '^sh /data/local/tmp/phh_watchdog\.sh')" = "0" ]; then
  setsid sh /data/local/tmp/phh_watchdog.sh >/dev/null 2>&1 < /dev/null &
  echo "  watchdog started"
fi

if [ -f /data/local/tmp/wifi_ps_off.sh ] &&
   [ "$(ps -A -o ARGS 2>/dev/null | grep -c '^sh /data/local/tmp/wifi_ps_off\.sh')" = "0" ]; then
  setsid sh /data/local/tmp/wifi_ps_off.sh >/dev/null 2>&1 < /dev/null &
  echo "  wifi powersave guard started"
fi
echo "  done"
