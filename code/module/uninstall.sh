#!/system/bin/sh
# Restore the carrier config from the backup service.sh made on first run.
#
# Removing the module unmounts the three APKs, but the carrier-config overrides
# live in com.android.phone's runtime cache, NOT in anything we mounted -- so
# without this the framework keeps pointing at packages that no longer exist and
# the phone can end up with no working IMS at all.
DIR=/data/user_de/0/com.android.phone/files
for B in "$DIR"/carrierconfig-*.xml.bak.vowifi_stack; do
  case "$B" in *'*'*) continue;; esac
  [ -f "$B" ] || continue
  F="${B%.bak.vowifi_stack}"
  cp -p "$B" "$F" && rm -f "$B"
done

# Drop the idle exemptions we added.
for P in com.google.android.iwlan me.phh.ims com.voxi.minqns; do
  dumpsys deviceidle whitelist "-$P" >/dev/null 2>&1
done

# Stop the watchdog if this module started it, or it will keep force-stopping a
# package that is no longer the IMS provider.
for p in $(ps -A -o PID,ARGS 2>/dev/null | grep '^ *[0-9]* sh /data/local/tmp/phh_watchdog\.sh' | awk '{print $1}'); do
  kill -9 "$p" 2>/dev/null
done

rm -f /data/local/tmp/vowifi_stack_boot.log
