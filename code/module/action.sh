#!/system/bin/sh
# Runs when you press "Action" on this module in the KernelSU manager.
# Read-only: prints the state of the whole stack. Nothing here changes anything,
# so it is safe to press at any time, including during a call.
MODDIR=${0%/*}

echo "VoWiFi stack status"
echo "==================="
echo

if [ -f /data/local/tmp/phh_status.sh ]; then
  sh /data/local/tmp/phh_status.sh
else
  # Fall back to the copy inside the module, in case /data/local/tmp was wiped.
  if [ -f "$MODDIR/tools/phh_status.sh" ]; then
    sh "$MODDIR/tools/phh_status.sh"
  else
    echo "phh_status.sh not found -- reinstall the module."
  fi
fi

echo
echo "--- last boot injection ---"
if [ -f /data/local/tmp/vowifi_stack_boot.log ]; then
  # Only the most recent run; the file keeps a few boots of history.
  awk '/^=== /{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}' \
    /data/local/tmp/vowifi_stack_boot.log
else
  echo "no boot log yet (has the device rebooted since installing?)"
fi

echo
echo "--- reading the numbers ---"
echo "healthy idle: >=1 estab socket + 1 listening, SAs in two UID groups,"
echo "dangling=0, recent registration grant, one watchdog."
echo
echo "SAs=0        -> no tunnel. Is WiFi calling enabled in Settings?"
echo "A local health check does not verify calls, delivery, or billed account activity."
echo "dangling>0   -> an xfrm policy points at a dead SA. Usually transient right"
echo "                after a network change; only a leak if it persists."
