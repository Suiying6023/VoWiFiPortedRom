#!/system/bin/sh
# Restore carrier caches, including legacy backups which already contained us.
MODDIR=${0%/*}
. "$MODDIR/carrier-config.sh" || exit 1
DIR=/data/user_de/0/com.android.phone/files
RESULT=0

for P in $(ps -A -o PID,ARGS 2>/dev/null | awk '$2 == "sh" && $3 == "/data/local/tmp/phh_watchdog.sh" {print $1}'); do
  kill -9 "$P" 2>/dev/null
done

for F in "$DIR"/carrierconfig-*.xml; do
  [ -f "$F" ] || continue
  SOURCE=$F
  B=$F.bak.vowifi_stack
  [ ! -f "$B" ] || SOURCE=$B
  TMP=$F.vowifi-restore.$$
  if cc_remove_ours "$SOURCE" "$TMP" && cat "$TMP" > "$F"; then
    rm -f "$B"
  else
    echo 'VoWiFi: carrier restore failed; retain backup for manual recovery' >&2
    RESULT=1
  fi
  rm -f "$TMP"
done

for P in com.google.android.iwlan me.phh.ims com.voxi.minqns; do
  dumpsys deviceidle whitelist "-$P" >/dev/null 2>&1
done
exit "$RESULT"
