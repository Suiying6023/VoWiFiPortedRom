#!/system/bin/sh
# Recover local registration faults, with calls and unavailable WiFi as vetoes.
BASE=${PHH_RUNTIME_DIR:-/data/local/tmp}
. "${0%/*}/phh_common.sh" || exit 1
LOG=$BASE/phh_watchdog.log
STAMP=$BASE/phh_last_grant

# Kernel-held lock: concurrent starts exit, and a dead process leaves no stale lock.
exec 9> "$BASE/.phh_watchdog.lock"
# Android mksh closes non-standard descriptors on exec unless passed explicitly.
flock -n 9 9>&9 || exit 0

note() {
  if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 65536 ]; then
    tail -200 "$LOG" > "$LOG.trim" && mv "$LOG.trim" "$LOG"
  fi
  echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"
}

LAST_RECOVERY=0
recover() {
  # The earlier sample can be stale: re-read all SIMs immediately before acting.
  CALL=$(phh_incall)
  if [ "$CALL" != "0" ]; then
    note "-> NOT force-stopping ($1): incall=$CALL"
    return
  fi
  phh_wifi_ready || return
  NOW=$(date +%s)
  if [ "$LAST_RECOVERY" -gt 0 ] && [ $((NOW - LAST_RECOVERY)) -lt 900 ]; then
    note "-> recovery deferred ($1): 900s cooldown"
    return
  fi
  LAST_RECOVERY=$NOW
  note "-> force-stop ($1)"
  am force-stop me.phh.ims
  sleep 150 9>&-
  OWNER=
  LAST_GRANT=0
  note "after: $(sh "$BASE/phh_health.sh" 9>&- 2>/dev/null)"
}

OWNER=
LAST_GRANT=0
LEASE=3590
FIRST_SEEN=$(date +%s)
note "watchdog started (event timestamps, all-SIM call guard)"
while true; do
  R=$(sh "$BASE/phh_health.sh" 9>&- 2>/dev/null)
  PID=$(phh_pid)
  START_TICKS=
  [ -z "$PID" ] || START_TICKS=$(awk '{print $22}' /proc/$PID/stat 2>/dev/null)
  NOW=$(date +%s)
  if [ "$PID:$START_TICKS" != "$OWNER" ]; then
    OWNER=$PID:$START_TICKS
    FIRST_SEEN=$NOW
    LAST_GRANT=0
    LEASE=3590
  fi
  GRANT=$(phh_grant "$PID")
  if [ -n "$GRANT" ]; then
    set -- $GRANT
    if [ "$1" -gt "$LAST_GRANT" ] && [ "$1" -le "$NOW" ]; then
      LAST_GRANT=$1
      LEASE=$2
      printf '%s\n' "$LAST_GRANT" > "$STAMP.tmp" && mv "$STAMP.tmp" "$STAMP"
    fi
  fi

  case "$R" in
    OK*)
      REF=$LAST_GRANT
      [ "$REF" -gt 0 ] || REF=$FIRST_SEEN
      AGE=$((NOW - REF))
      if [ "$AGE" -gt $((LEASE + 310)) ]; then
        note "BAD(silent) grant age=${AGE}s lease=${LEASE}s: $R"
        recover stale-registration
      fi
      ;;
    BAD*)
      note "$R"
      case "$R" in
        *log-spin*|*phh-not-running*) recover spin-or-dead ;;
        *no-listener*)
          sleep 20 9>&-
          R2=$(sh "$BASE/phh_health.sh" 9>&- 2>/dev/null)
          case "$R2" in
            BAD*no-listener*) note "confirmed: $R2"; recover no-listener ;;
            *) note "listener recheck: $R2" ;;
          esac
          ;;
        # Transient socket/policy rebuilds alone do not justify a force-stop.
      esac
      ;;
    WAIT*) ;;
    *) note "health probe unavailable; no recovery attempted" ;;
  esac
  sleep 120 9>&-
done
