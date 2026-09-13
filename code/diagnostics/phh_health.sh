#!/system/bin/sh
# One-line local registration health, not proof of SMS delivery or billing.
. "${0%/*}/phh_common.sh" || exit 1

INCALL=$(phh_incall)
if ! phh_wifi_ready; then
  echo "WAIT wifi-unavailable incall=$INCALL"
  exit 0
fi
PID=$(phh_pid)
if [ -z "$PID" ]; then
  echo "BAD phh-not-running incall=$INCALL"
  exit 0
fi

ESTAB=$(ss -tnp 2>/dev/null | grep "pid=$PID," | grep -c ESTAB)
LISTEN=$(ss -tnlp 2>/dev/null | grep -c "pid=$PID,")
TICKS=$(awk '{print $14 + $15}' /proc/$PID/stat 2>/dev/null)

# Count recent records from this process, not the size of a rotating log buffer.
SINCE=$(date +%s).000
sleep 3
DELTA=$(logcat -b radio -d -v epoch --pid="$PID" -T "$SINCE" 2>/dev/null |
  awk '$1 ~ /^[0-9]+[.][0-9]+$/ { n++ } END { print n+0 }')
INCALL=$(phh_incall)
if [ "$(phh_pid)" != "$PID" ]; then
  echo "WAIT process-changed incall=$INCALL"
  exit 0
fi

# Alarm dumps include history. Actual registration grants determine expiration.
ALARM=$(dumpsys alarm 2>/dev/null | grep -c 'me.phh.ims')
DANGLING=$(phh_dangling)
WD=$(phh_watchdogs)
GRANT=$(phh_grant "$PID")
GRANT_AGE=unknown
if [ -n "$GRANT" ]; then
  set -- $GRANT
  GRANT_AGE=$(( $(date +%s) - $1 ))
fi

STATUS=OK
REASON=
[ "$ESTAB" -ge 1 ] || { STATUS=BAD; REASON="$REASON sockets=$ESTAB(want>=1)"; }
[ "$LISTEN" -ge 1 ] || { STATUS=BAD; REASON="$REASON no-listener"; }
if [ "$INCALL" = "0" ] && [ "$DELTA" -ge 300 ]; then
  STATUS=BAD; REASON="$REASON log-spin=$DELTA/3s"
fi
[ "$DANGLING" -eq 0 ] || { STATUS=BAD; REASON="$REASON dangling-policies=$DANGLING"; }

echo "$STATUS pid=$PID estab=$ESTAB listen=$LISTEN ticks=$TICKS logdelta=$DELTA alarm_refs=$ALARM grant_age=$GRANT_AGE dangling=$DANGLING wd=$WD incall=$INCALL$REASON"
