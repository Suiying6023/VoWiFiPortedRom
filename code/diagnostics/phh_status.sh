#!/system/bin/sh
# Read-only status; neither a healthy tunnel nor RP-ACK proves a billed SMS.
. "${0%/*}/phh_common.sh" || exit 1
PID=$(phh_pid)
echo "== phh IMS =="
if [ -z "$PID" ]; then
  echo "  process   : NOT RUNNING"
else
  UP=$(cut -d' ' -f1 /proc/uptime | cut -d. -f1)
  ST=$(awk '{print $22}' /proc/$PID/stat 2>/dev/null)
  HZ=$(getconf CLK_TCK 2>/dev/null)
  [ -n "$HZ" ] || HZ=100
  TICKS=$(awk '{print $14 + $15}' /proc/$PID/stat 2>/dev/null)
  THR=$(awk '/Threads/{print $2}' /proc/$PID/status 2>/dev/null)
  echo "  pid       : $PID (up $((UP - ST/HZ))s, $TICKS CPU ticks, $THR threads)"
  APK=$(pm path me.phh.ims 2>/dev/null | sed -n 's/^package://p' | head -1)
  echo "  apk sha256: $(sha256sum "$APK" 2>/dev/null | awk '{print $1}')"
  echo "  sockets   : $(ss -tnp 2>/dev/null | grep "pid=$PID," | grep -c ESTAB) estab, $(ss -tnlp 2>/dev/null | grep -c "pid=$PID,") listening"
fi

echo "== IPsec =="
echo "  SAs       : $(ip xfrm state 2>/dev/null | grep -c '^src')"
echo "  policies  : $(ip xfrm policy 2>/dev/null | grep -c '^src')"
ip xfrm state 2>/dev/null | grep -oE 'reqid [0-9]+' | sort | uniq -c | sed 's/^/  by reqid : /'
echo "  dangling  : $(phh_dangling) (persistent nonzero values need investigation)"

echo "== registration =="
GRANT=$(phh_grant "$PID")
if [ -n "$GRANT" ]; then
  set -- $GRANT
  echo "  last grant: $(( $(date +%s) - $1 ))s ago; lease=$2 s"
else
  echo "  last grant: unknown (event absent from current process log)"
fi
echo "  IWLAN     : $(dumpsys telephony.registry 2>/dev/null | grep -c 'accessNetworkTechnology=IWLAN') entries"
echo "  incall    : $(phh_incall) (all SIMs; unknown vetoes recovery)"

echo "== monitor =="
echo "  watchdogs : $(phh_watchdogs)"
echo "  last act  : $(grep 'force-stop' /data/local/tmp/phh_watchdog.log 2>/dev/null | tail -1)"
sh "${0%/*}/phh_health.sh"
echo "Local health does not validate voice calls, SMS delivery, or account activity."
