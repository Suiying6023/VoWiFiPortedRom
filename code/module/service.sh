#!/system/bin/sh
# Re-inject the carrier-config overrides that point the framework at our three
# components. Runs late in boot (KernelSU service.sh) once per boot.
#
# WHY A SCRIPT AND NOT A FILE OVERLAY: these seven keys do not live in a file we
# can mount over. They live in com.android.phone's *runtime cache* of the
# resolved carrier config, under /data/user_de/0/com.android.phone/files, in a
# file whose name contains the SIM's ICCID. The cache is rebuilt by the platform,
# so the keys have to be re-inserted after it settles. Everything else in this
# module (the three APKs, the privapp allowlists) is a plain overlay.
#
# The seven keys and what each one does:
#   carrier_data_service_wlan_{package,class}_override_string     -> Iwlan builds the tunnel
#   carrier_network_service_wlan_{package,class}_override_string  -> Iwlan reports WLAN reg state
#   carrier_qualified_networks_service_{package,class}_override   -> MinQns says "IMS over IWLAN"
#   config_ims_mmtel_package_override_string                      -> floss-ims becomes MMTEL
# They are (package, class) PAIRS -- injecting one half of a pair silently leaves
# the framework pointing at the stock component.
MODDIR=${0%/*}
. "$MODDIR/carrier-config.sh" || exit 1
LOG=/data/local/tmp/vowifi_stack_boot.log
DIR=/data/user_de/0/com.android.phone/files

# The three components. Change these (and the sed block below) if you swap a
# component out -- e.g. a different QualifiedNetworksService implementation.
PKGS="com.google.android.iwlan me.phh.ims com.voxi.minqns"

# Keep only the last few boots of log. Left alone this grows forever on a device
# that reboots often, and nobody ever reads the old entries.
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 400 ]; then
  tail -100 "$LOG" > "$LOG.trim" 2>/dev/null && mv "$LOG.trim" "$LOG"
fi

exec >> "$LOG" 2>&1
echo "=== $(date '+%m-%d %H:%M:%S') vowifi_stack service.sh ==="

# Wait for boot to complete AND for the carrier config cache to exist. Injecting
# before the platform has written the cache means our edit is simply overwritten.
i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 150 ]; do sleep 2; i=$((i+1)); done

# Then wait for the cache FILE to appear, rather than sleeping a fixed 30s and
# hoping. A cold boot with an eSIM to provision can take much longer than 30s, and
# a fixed sleep that expires early means we inject nothing and log "no carrier
# config found" -- which reads like a broken module. Poll up to 4 minutes.
i=0
while [ $i -lt 120 ]; do
  set -- "$DIR"/carrierconfig-*.xml
  [ -f "$1" ] && break
  sleep 2; i=$((i+1))
done
# Small settle once it exists: the platform may still be writing it.
sleep 8

# Match ANY vendor's carrier config package, not just com.android + com.xiaomi.
# Every OEM ships its own (com.xiaomi.carrierconfig here, but Samsung/Oppo/etc use
# their own names) and the resolved config is the union, so a vendor cache we skip
# can keep pointing the framework at the stock components. The ICCID in the
# filename is derived by glob, never hardcoded -- it changes with the SIM.
FOUND=0
for F in "$DIR"/carrierconfig-*.xml; do
  case "$F" in *'*'*) continue;; esac   # unmatched glob
  case "$F" in *.bak.*) continue;; esac
  [ -f "$F" ] || continue
  # Only touch files that look like a real carrier config bundle.
  [ "$(grep -c '</bundle>' "$F")" != "0" ] || { echo "  skip $(basename "$F"): no </bundle>"; continue; }
  FOUND=$((FOUND+1))

  # Keep one pristine copy so the stack can be backed out without a factory reset.
  if [ ! -f "$F.bak.vowifi_stack" ]; then
    cp -p "$F" "$F.bak.vowifi_stack" || { echo "  backup failed; skipping cache"; continue; }
  fi

  # Already injected (cache survived the reboot)? Then leave it alone -- rewriting
  # it while the phone process holds it open has no upside.
  if cc_valid "$F"; then
    echo "  $(basename "$F"): already has all overrides, skipping"
    continue
  fi

  TMP=/data/local/tmp/.cc_vowifi.$$.xml
  if cc_render "$F" "$TMP"; then
    cat "$TMP" > "$F" && echo "  carrier cache: injected and verified all 7 values"
  else
    echo "  carrier cache: REFUSED invalid override result"
  fi
  rm -f "$TMP"
done

if [ "$FOUND" = "0" ]; then
  echo "  no carrier config cache found -- SIM not ready? overrides NOT applied"
fi

# Exempt all three from vendor idle freezing. A frozen IMS service misses the
# registration-refresh alarm and the binding lapses silently -- with no local error,
# because it is the NETWORK that then drops incoming SMS.
for P in $PKGS; do
  dumpsys deviceidle whitelist "+$P" >/dev/null 2>&1
done
echo "  deviceidle whitelist: $(dumpsys deviceidle whitelist 2>/dev/null | grep -cE 'phh\.ims|android\.iwlan|minqns')/3"

# Report whether the packages actually got their privileged permissions. This is
# the single most common failure after a flash (wrong SELinux label, or the package
# manager reusing a cached manifest), and it is silent: the service starts, then
# requestNetwork is refused with no error the user ever sees.
for P in $PKGS; do
  if [ "$(pm path "$P" 2>/dev/null | grep -c .)" = "0" ]; then
    echo "  !! $P NOT INSTALLED -- check priv-app SELinux label (must be system_file)"
  fi
done
if [ "$(dumpsys package me.phh.ims 2>/dev/null | grep -c 'CONNECTIVITY_USE_RESTRICTED_NETWORKS: granted=true')" = "0" ]; then
  echo "  !! IMS service lacks CONNECTIVITY_USE_RESTRICTED_NETWORKS"
  echo "     -> requestNetwork(NET_CAPABILITY_IMS) will be SILENTLY refused."
  echo "     Check the privapp-permissions XML landed and the base was re-scanned."
fi

# Restore the bundled diagnostic helpers if /data/local/tmp was cleaned.
# Runtime logs and registration timestamps are preserved.
for TOOL in "$MODDIR"/tools/*.sh; do
  [ -f "$TOOL" ] || continue
  cp "$TOOL" "/data/local/tmp/$(basename "$TOOL")"
  chmod 755 "/data/local/tmp/$(basename "$TOOL")"
done

# The module includes its watchdog. A persistent opt-out is available via
# /data/adb/modules/vowifi_stack/watchdog.disabled. Its own flock enforces one copy.
if [ ! -f "$MODDIR/watchdog.disabled" ] &&
   [ -f /data/local/tmp/phh_watchdog.sh ] &&
   [ "$(ps -A -o ARGS 2>/dev/null | grep -c '^sh /data/local/tmp/phh_watchdog\.sh')" = "0" ]; then
  setsid sh /data/local/tmp/phh_watchdog.sh >/dev/null 2>&1 < /dev/null &
  echo "  watchdog started"
fi

echo "  done"
