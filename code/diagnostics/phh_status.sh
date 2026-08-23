#!/system/bin/sh
# One-shot full status of the VoWiFi stack. Read-only, safe to run any time.
#
# Device-side on purpose: every one of these checks contains $, ^ or nested
# quotes, and passing them through `adb shell "su -c '...'"` from a Windows host
# silently loses them -- that produced a bogus "cpu=" (awk $2 eaten), a bogus
# "SA=0" that looked like the tunnel had dropped, and a cp that wrote to /.
# Host side should only ever read this script's output.
PID=$(pgrep -f me.phh.ims | head -1)
echo "== phh IMS =="
if [ -z "$PID" ]; then
  echo "  process   : NOT RUNNING"
else
  UP=$(cut -d' ' -f1 /proc/uptime | cut -d. -f1)
  # Field 22 of /proc/<pid>/stat is starttime in clock ticks since boot. Do NOT
  # use `stat /proc/<pid>` -- that is the inode mtime and changes as the process
  # runs, which once made a process look like it had silently restarted.
  ST=$(awk '{print $22}' /proc/$PID/stat 2>/dev/null)
  TICKS=$(awk '{print $14 + $15}' /proc/$PID/stat 2>/dev/null)
  THR=$(awk '/Threads/{print $2}' /proc/$PID/status 2>/dev/null)
  echo "  pid       : $PID  (up $(( UP - ST/100 ))s, ${TICKS} ticks cpu, ${THR} threads)"
  # ~30 threads idle, ~44 during a call. Our own media threads log
  # "Decode/Encode thread ending" when they exit; a couple of MediaCodec_loop
  # threads legitimately outlive release() (Android's codec pool, not our leak),
  # so judge by our OWN threads and by CPU, not by the raw count.
  echo "  our media : $(ls /proc/$PID/task/*/comm 2>/dev/null | xargs grep -lE 'AudioRec|AudioTrack' 2>/dev/null | wc -l) audio (0 = torn down)"
  echo "  apk       : $(md5sum /data/app/*/me.phh.ims*/base.apk 2>/dev/null | cut -c1-32)"
  echo "  sockets   : $(ss -tnp 2>/dev/null | grep "pid=$PID," | grep -c ESTAB) estab, $(ss -tnlp 2>/dev/null | grep -c "pid=$PID,") listening"
fi

echo "== tunnel (ePDG) =="
# reqid identifies the owning uid: the Iwlan one carries the tunnel, phh's the
# sec-agree transport SAs. This split is the single most useful diagnostic here
# and it is exactly what merging the three packages would destroy.
echo "  SAs       : $(ip xfrm state 2>/dev/null | grep -c '^src')"
echo "  policies  : $(ip xfrm policy 2>/dev/null | grep -c '^src')"
ip xfrm state 2>/dev/null | grep -oE 'reqid [0-9]+' | sort | uniq -c | sed 's/^/  by reqid : /'
# Real leak test: a policy whose SPI has no live SA. Never compare totals --
# they move for benign reasons (v4/v6 dual policies, sockets rebuilt on
# reconnect), and treating that as a leak cost two rounds chasing nothing.
ip xfrm state  2>/dev/null | grep -oE 'spi 0x[0-9a-f]+' | sort -u > /data/local/tmp/.st_sa
ip xfrm policy 2>/dev/null | grep -oE 'spi 0x[0-9a-f]+' | sort -u > /data/local/tmp/.st_pol
echo "  dangling  : $(comm -13 /data/local/tmp/.st_sa /data/local/tmp/.st_pol | wc -l) (0 = no leak)"

echo "== registration =="
echo "  last grant: $(logcat -b radio -d 2>/dev/null | grep -a 'granted for' | tail -1 | sed 's/.*granted/granted/')"
echo "  reconnects: $(logcat -b radio -d 2>/dev/null | grep -ac 'Reconnected after peer closed')"
echo "  stale-rdr : $(logcat -b radio -d 2>/dev/null | grep -ac 'Not reconnecting: stale')"
# Ask the framework rather than scraping the log: the radio buffer rotates, so
# after a quiet spell the grep finds nothing and prints an empty value that reads
# like "vowifi is off" when it is actually fine.
echo "  vowifi    : $(dumpsys telephony.registry 2>/dev/null | grep -c 'accessNetworkTechnology=IWLAN') IWLAN reg entries (>=1 = registered over wifi)"
echo "  capabil.  : $(logcat -b radio -d 2>/dev/null | grep -a 'notifyCapabilities' | tail -1 | grep -oE '[0-9]+$') (11 = Voice|Video|SMS)"

echo "== calls =="
echo "  connected : $(logcat -b radio -d 2>/dev/null | grep -ac 'Invite got SUCCESS')"
echo "  failed    : $(logcat -b radio -d 2>/dev/null | grep -acE 'Invite got status (4|5)[0-9][0-9]')"
echo "  rtp lines : $(logcat -b radio -d 2>/dev/null | grep -ac 'Received RTP data') (should stay ~0: one line per stream, not per packet)"
# Read the live call state, not `dumpsys telecom | grep state=` -- that also
# matches the historical session log at the bottom of the dump and reported
# DIALING long after the call was gone (it fooled me once).
# A DIALING/live state here with no call actually in progress is the ghost-call
# symptom: clear with `am force-stop me.phh.ims; am force-stop com.android.phone`.
CS=$(dumpsys telephony.registry 2>/dev/null | grep -am1 mCallState | grep -oE '[0-9]+$')
echo "  callstate : ${CS:-?} (0 = idle, 2 = offhook)"
# Android's toybox grep has no \s -- use a literal bracket match instead.
echo "  live calls: $(dumpsys telecom 2>/dev/null | grep -cF '[Call id=TC')"

echo "== monitors =="
echo "  watchdog  : $(ps -A -o ARGS 2>/dev/null | grep -c '^sh /data/local/tmp/phh_watchdog\.sh')"
echo "  last act  : $(grep 'force-stop' /data/local/tmp/phh_watchdog.log 2>/dev/null | tail -1)"
echo "  refused   : $(grep -c 'NOT force-stopping' /data/local/tmp/phh_watchdog.log 2>/dev/null) (declined to kill during a call)"
