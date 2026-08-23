#!/system/bin/sh
# One-shot health check for the phh floss-ims SIP registration.
# Prints a single line: OK ... / BAD ... plus the reason.
#
# Why several signals together: a dead registration does NOT drop the process and
# does NOT crash, so "the process is running" proves nothing. The failure mode we
# actually hit (the main-socket loop discarding parseMessage's return value)
# presents as: sockets in CLOSE-WAIT, one core pinned, and the radio log filling
# with the same three lines forever. Only the log-spin signal caught it the first
# time, so keep all of them -- the next failure may show up in a different one.
PID=$(pgrep -f me.phh.ims | head -1)
if [ -z "$PID" ]; then
  echo "BAD phh-not-running"
  exit 0
fi

# Socket state, counted from the process's own sockets rather than by grepping a
# port literal. Both endpoints move: the local port is ephemeral (43665 on this
# boot, 50600-something on others) and the P-CSCF address changes between
# reconnects (.240 / .145 / .243 seen), with the SIP bearer having been both IPv4
# and IPv6. An IP- or port-based grep silently returns nothing and looks exactly
# like a broken script.
# Filter on ESTAB explicitly: `ss -tn` also lists CLOSE-WAIT, and this failure
# leaves the sockets in CLOSE-WAIT -- counting matching lines instead of
# established ones reported a healthy "estab=2" while the registration was dead.
ESTAB=$(ss -tnp 2>/dev/null | grep "pid=$PID," | grep -c ESTAB)
# The listener the P-CSCF connects back on (local port + 1). Its absence means
# inbound SUBSCRIBE/NOTIFY and incoming SMS cannot arrive at all, even while the
# outbound control socket still looks fine.
LISTEN=$(ss -tnlp 2>/dev/null | grep -c "pid=$PID,")

# CPU: read the counter directly instead of parsing top, whose column layout
# varies -- and whose $2 gets eaten by the escaping layers of
# `adb shell "su -c '...'"`, which produced a false alarm every minute.
# utime+stime, in clock ticks since process start.
TICKS=$(awk '{print $14 + $15}' /proc/$PID/stat 2>/dev/null)

# Log spin: the spin emits thousands of lines a second. A healthy idle
# registration emits none.
A=$(logcat -b radio -d 2>/dev/null | wc -l)
sleep 3
B=$(logcat -b radio -d 2>/dev/null | wc -l)
DELTA=$((B - A))

# Is a call up? An active call legitimately produces a lot of radio log, and the
# spin threshold below must not fire on it. This cost us a real call: a connected,
# working 3m35s call to 191 logged ~100 lines/second of per-RTP-packet debug, the
# watchdog read logdelta=312/3s as the main-socket spin, and force-stopped it. The
# app side now logs the RTP stream once instead of per packet, but keep this guard:
# any future chatty-during-call code would trip the same wire.
CALLSTATE=$(dumpsys telephony.registry 2>/dev/null | grep -am1 "mCallState" | grep -oE "[0-9]+$")
[ -n "$CALLSTATE" ] || CALLSTATE=0
if [ "$CALLSTATE" != "0" ]; then
  INCALL=1
else
  INCALL=0
fi

# Refresh alarm must be queued, or the registration lapses silently at the 3590s
# expiry with no error logged anywhere. Derive the uid instead of hardcoding
# u0a268: the appid changes on reinstall, and a stale literal silently reports
# alarm=0 forever.
UID_N=$(stat -c %u /proc/$PID 2>/dev/null)
if [ -n "$UID_N" ] && [ "$UID_N" -ge 10000 ] 2>/dev/null; then
  APPID=$((UID_N - 10000))
  ALARM=$(dumpsys alarm 2>/dev/null | grep -c "u0a${APPID}:")
else
  ALARM=$(dumpsys alarm 2>/dev/null | grep -c "me.phh.ims")
fi

# Watchdog presence. Count it here, inside the device-side script, and count it
# from ps output rather than with `pgrep -f`: any pgrep pattern passed down
# through `adb shell "su -c '...'"` also matches the shell running that very
# command, so `pgrep -f phh_watchdog.sh | wc -l` reported 3 when exactly one was
# running. Matching on the leading "sh " restricts it to real interpreters.
WD=$(ps -A -o ARGS 2>/dev/null | grep -c "^sh /data/local/tmp/phh_watchdog\.sh")

# Real leak test: an xfrm policy whose SPI has no live SA behind it. Do NOT
# compare totals -- they move for benign reasons (v4/v6 dual policies, sockets
# rebuilt on reconnect), and treating that as a leak cost two rounds of chasing
# a leak that did not exist.
ip xfrm state 2>/dev/null | grep -oE 'spi 0x[0-9a-f]+' | sort -u > /data/local/tmp/.hs_sa
ip xfrm policy 2>/dev/null | grep -oE 'spi 0x[0-9a-f]+' | sort -u > /data/local/tmp/.hs_pol
DANGLING=$(comm -13 /data/local/tmp/.hs_sa /data/local/tmp/.hs_pol 2>/dev/null | wc -l)

STATUS=OK
REASON=
# At least one ESTABLISHED, not exactly two. Two is the usual steady state (the
# plain control socket plus the sec-agree-protected one), but a healthy
# registration can sit on one -- seen right after reconnecting onto a different
# P-CSCF, and again on a fresh start before the peer connects back. Demanding
# exactly two reported BAD on a registration that had just returned 200 OK.
[ "$ESTAB" -ge 1 ] || { STATUS=BAD; REASON="$REASON sockets=$ESTAB(want >=1)"; }
[ "$LISTEN" -ge 1 ] || { STATUS=BAD; REASON="$REASON no-listener"; }
# Skip the spin test during a call -- see the INCALL note above. A spin that starts
# during a call is still caught on the next poll after it ends.
if [ "$INCALL" = "0" ]; then
  [ "$DELTA" -lt 300 ] || { STATUS=BAD; REASON="$REASON log-spin=$DELTA/3s"; }
fi
[ "$ALARM" -ge 1 ] || { STATUS=BAD; REASON="$REASON no-refresh-alarm"; }
[ "$DANGLING" -eq 0 ] || { STATUS=BAD; REASON="$REASON dangling-policies=$DANGLING"; }

# The watchdog count is reported but does NOT set STATUS=BAD: its absence is not
# a registration fault, and conflating the two would make a healthy registration
# look broken. Callers that care can grep for "wd=0" (no safety net) or "wd=2+"
# (duplicates, which fight each other by force-stopping in turn).
echo "$STATUS pid=$PID estab=$ESTAB listen=$LISTEN ticks=$TICKS logdelta=$DELTA alarm=$ALARM dangling=$DANGLING wd=$WD incall=$INCALL$REASON"
