#!/system/bin/sh
# Capture everything about the next INCOMING call, for verifying the inbound path.
#
# The inbound path has never been exercised end to end. It is the one part of the
# stack where "reviewed and hardened" is all we can claim. This records the whole
# chain so a single ring is enough to judge it:
#
#   network INVITE -> handleCall -> notifyIncomingCall -> Telecom rings
#   -> user declines -> rejectCall -> SIP 486 -> callSessionTerminated
#
# Declining is deliberate: an answered call on this SIM costs GBP 0.36/min in ROW1
# (with a one-minute minimum), while a declined one should not connect at all.
#
# Usage: run it, then trigger the call. Ctrl-C or let it time out.
#   su -c 'sh /data/local/tmp/watch_incoming_call.sh 300'
TIMEOUT=${1:-300}
LOG=/data/local/tmp/incoming_call_test.log

: > "$LOG"
echo "=== watching for incoming call, ${TIMEOUT}s ===" | tee -a "$LOG"
echo "state before: $(sh /data/local/tmp/phh_health.sh 2>/dev/null)" | tee -a "$LOG"
PID_BEFORE=$(pgrep -f me.phh.ims | head -1)
echo "pid before  : $PID_BEFORE" | tee -a "$LOG"
echo | tee -a "$LOG"

logcat -b radio -c 2>/dev/null
logcat -b crash -c 2>/dev/null

# Follow the radio log for the inbound-path markers. Include the failure
# signatures, not just the happy path: if handleCall throws or the process dies,
# silence would otherwise look identical to "no call arrived".
logcat -b radio -v time 2>/dev/null | grep --line-buffered -aE \
  'Incoming call from|handleCall|notifyIncomingCall|Setting CallListener|Accepting call|Rejecting call|Terminating call|acceptCall with no|rejectCall with no|UPDATE with no call|Sending SIP/2.0 (180|183|200|486)|RTP stream started|thread ending|Got exception|FATAL' \
  >> "$LOG" &
GREP_PID=$!

# Poll for the call state changing, so we notice the ring even if the log markers
# are named differently than expected.
i=0
SAW=0
while [ $i -lt "$TIMEOUT" ]; do
  CS=$(dumpsys telephony.registry 2>/dev/null | grep -am1 mCallState | grep -oE '[0-9]+$')
  [ -n "$CS" ] || CS=0
  if [ "$CS" != "0" ] && [ "$SAW" = "0" ]; then
    echo "[$(date '+%H:%M:%S')] CALL STATE -> $CS (1=ringing, 2=offhook)" | tee -a "$LOG"
    SAW=1
    dumpsys telecom 2>/dev/null | grep -F '[Call id=TC' | head -2 >> "$LOG"
  fi
  if [ "$CS" = "0" ] && [ "$SAW" = "1" ]; then
    echo "[$(date '+%H:%M:%S')] call ended" | tee -a "$LOG"
    break
  fi
  sleep 2
  i=$((i+2))
done

sleep 3
kill "$GREP_PID" 2>/dev/null

echo | tee -a "$LOG"
echo "=== after ===" | tee -a "$LOG"
PID_AFTER=$(pgrep -f me.phh.ims | head -1)
echo "pid after   : $PID_AFTER" | tee -a "$LOG"
if [ "$PID_BEFORE" != "$PID_AFTER" ]; then
  echo "!! PROCESS RESTARTED -- inbound path crashed or was force-stopped" | tee -a "$LOG"
  logcat -b crash -d 2>/dev/null | grep -aA12 'FATAL' | head -16 | tee -a "$LOG"
else
  echo "process survived (good)" | tee -a "$LOG"
fi
echo "media held  : $(ls /proc/$PID_AFTER/task/*/comm 2>/dev/null | xargs grep -lE 'AudioRec|AudioTrack' 2>/dev/null | wc -l) audio threads (0 = torn down)" | tee -a "$LOG"
echo "state after : $(sh /data/local/tmp/phh_health.sh 2>/dev/null)" | tee -a "$LOG"
echo | tee -a "$LOG"
echo "full log: $LOG"
if [ "$SAW" = "0" ]; then
  echo "NOTE: no call state change seen -- either no call arrived, or the ring"
  echo "      never reached Telecom (which is itself the finding)."
fi
