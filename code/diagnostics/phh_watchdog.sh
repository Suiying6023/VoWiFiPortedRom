#!/system/bin/sh
# Self-healing watchdog for the phh IMS registration.
#
# v29 fixed the main-socket spin at the source (the read loop honours
# parseMessage's return value and rebuilds the connection), and v34 fixed three
# reconnect-only defects on top. This is the net for what those do not cover,
# and it covers THREE distinct failures:
#
#  1. The spin: phh_health.sh reports log-spin, or the process is gone.
#  2. Silent expiry: the registration lapses with NO log and NO socket change.
#     Vodafone grants 3590s and phh refreshes at half that, so a successful
#     refresh must appear well within an hour. If none has, the registration is
#     either dead or about to be -- and downlink SMS is dropped by the network
#     with nothing logged locally, which is why this needs an active check.
#  3. Missing listener: the P-CSCF connects back on (local port + 1). If that
#     listener is gone, inbound SUBSCRIBE/NOTIFY and incoming SMS cannot arrive
#     while the outbound control socket still looks perfectly healthy.
#
# force-stop is safe recovery: it does NOT tear down the ePDG tunnel (that
# belongs to the Iwlan uid) and the service re-registers in ~100s. Verified.
LOG=/data/local/tmp/phh_watchdog.log
STAMP=/data/local/tmp/phh_last_grant

note() { echo "$(date '+%m-%d %H:%M:%S') $*" >> $LOG; }

recover() {
  # Never force-stop during a call. The health script no longer reports a spin while
  # a call is up, but this is the backstop for every other BAD reason: killing the
  # IMS service mid-call drops the call, and no fault this watchdog detects is worth
  # that. It cost us a real one -- a connected 3m35s call to 191 was force-stopped
  # because the per-RTP-packet logging looked like the main-socket spin.
  if [ "$(echo "$2" | grep -c 'incall=1')" != "0" ]; then
    note "-> NOT force-stopping ($1): call in progress"
    return
  fi
  note "-> force-stop ($1)"
  am force-stop me.phh.ims
  sleep 150
  note "after: $(sh /data/local/tmp/phh_health.sh 2>/dev/null)"
  date +%s > $STAMP
}

# Seed the stamp so a fresh watchdog does not immediately think it is stale.
[ -f $STAMP ] || date +%s > $STAMP

while true; do
  R=$(sh /data/local/tmp/phh_health.sh 2>/dev/null)

  # Track the most recent successful registration grant. Only bump the stamp when
  # we actually see one, so a quiet log means the stamp goes stale -- which is the
  # signal we want.
  if logcat -b radio -d -t 400 2>/dev/null | grep -aq "granted for"; then
    date +%s > $STAMP
  fi

  case "$R" in
    OK*)
      NOW=$(date +%s); LAST=$(cat $STAMP 2>/dev/null || echo $NOW)
      AGE=$((NOW - LAST))
      # 3900s > the 3590s grant, so a healthy refresh cycle can never trip this.
      if [ "$AGE" -gt 3900 ]; then
        note "BAD(silent) no grant seen for ${AGE}s: $R"
        recover "stale-registration" "$R"
      fi
      ;;
    *)
      note "$R"
      case "$R" in
        *log-spin*|*not-running*) recover "spin-or-dead" "$R" ;;
        # A reconnect rebuilds the listener, so it is legitimately absent for a
        # few seconds. Confirm before acting -- a false alarm here costs a
        # force-stop and ~100s of downtime, and false alarms train you to ignore
        # the log, which is worse than the bug.
        *no-listener*)
          sleep 20
          R2=$(sh /data/local/tmp/phh_health.sh 2>/dev/null)
          case "$R2" in
            *no-listener*) note "confirmed: $R2"; recover "no-listener" "$R2" ;;
            *) note "transient no-listener, recovered on its own: $R2" ;;
          esac
          ;;
        # Deliberately NOT acting on sockets=0 alone: a reconnect in progress can
        # legitimately show zero sockets for a moment.
        # Deliberately NOT acting on dangling-policies either: a leaked xfrm
        # policy is not a registration fault, force-stop would not reclaim it
        # (the SAs belong to the transforms, not the process), and treating it as
        # an outage would force-stop a working registration every 120s.
      esac
      ;;
  esac
  sleep 120
done
