#!/system/bin/sh
# Shared, read-only probes. Output excludes SIP identities and IPsec keys.

phh_pid() {
  pidof me.phh.ims 2>/dev/null | awk '{print $1}'
}

phh_incall() {
  # Check every SIM. Unknown state vetoes recovery just like an ongoing call.
  dumpsys telephony.registry 2>/dev/null | awk '
    /^[[:space:]]*mCallState=/ {
      split($0, a, "="); gsub(/[[:space:]]/, "", a[2])
      if (a[2] ~ /^[012]$/) { seen++; if (a[2] != "0") busy=1 }
      else invalid=1
    }
    END {
      if (busy) print 1
      else if (!seen || invalid) print "unknown"
      else print 0
    }'
}

phh_wifi_ready() {
  ip -o addr show wlan0 scope global 2>/dev/null | grep -q ' inet'
}

phh_grant() {
  [ -n "$1" ] || return
  # Preserve the EVENT timestamp. Re-reading an old line is not a renewal.
  logcat -b radio -d -v epoch --pid="$1" \
    -e 'registration granted for [0-9]+s' 2>/dev/null | awk '
    $1 ~ /^[0-9]+[.][0-9]+$/ && /registration granted for [0-9]+s/ {
      stamp=int($1); duration=$0
      sub(/^.*registration granted for /, "", duration)
      sub(/s.*$/, "", duration)
    }
    END { if (stamp > 0 && duration > 0) printf "%.0f %d\n", stamp, duration }'
}

phh_watchdogs() {
  ps -A -o ARGS 2>/dev/null | awk '
    $1 == "sh" && $2 == "/data/local/tmp/phh_watchdog.sh" { n++ }
    END { print n+0 }'
}

phh_dangling() {
  # Each invocation owns its awk map; concurrent probes share no temporary files.
  {
    ip xfrm state 2>/dev/null | grep -oE 'spi 0x[0-9a-f]+' | sed 's/^/sa /'
    ip xfrm policy 2>/dev/null | grep -oE 'spi 0x[0-9a-f]+' | sed 's/^/policy /'
  } | awk '
    $1 == "sa" { sa[$3]=1 }
    $1 == "policy" { policy[$3]=1 }
    END { for (spi in policy) if (!(spi in sa)) n++; print n+0 }'
}
