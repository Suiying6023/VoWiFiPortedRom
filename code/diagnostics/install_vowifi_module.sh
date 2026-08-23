#!/system/bin/sh
# Install the unified vowifi_stack module and disable the two modules it replaces.
#
# Why the old ones must be disabled, not just left alone: the new module ships
# me.phh.ims at priv-app/PhhIms and Iwlan at priv-app/IwlanAosp, while
# phhimspriv ships the same package at priv-app/PhhImsJ and iwlanpriv at
# priv-app/IwlanN. Two priv-app directories carrying the same package name is an
# undefined situation for the package manager -- one silently wins, and which one
# is not something to leave to chance.
#
# They are DISABLED, not deleted, so the previous working setup can be restored
# by removing the `disable` files if the unified module turns out worse.
#
# imsfix_cn and ims_impersonate are deliberately left alone: imsfix_cn provides
# /system_ext/priv-app/ims (org.codeaurora.ims), which is still installed and
# running, and this module does not replace it.
set -u
ZIP=/data/local/tmp/vowifi-stack-v1.zip
[ -f "$ZIP" ] || { echo "FAIL: $ZIP missing"; exit 1; }

echo "=== before ==="
for m in phhimspriv iwlanpriv vowifi_stack; do
  if [ -d /data/adb/modules/$m ]; then
    [ -f /data/adb/modules/$m/disable ] && echo "  $m: present (disabled)" || echo "  $m: present (enabled)"
  else
    echo "  $m: absent"
  fi
done

echo "=== installing ==="
# ksud is KernelSU's own installer; it runs customize.sh and sets contexts.
if command -v ksud >/dev/null 2>&1; then
  ksud module install "$ZIP" || { echo "FAIL: ksud install"; exit 1; }
else
  echo "FAIL: ksud not found -- flash the zip from the KernelSU manager instead"
  exit 1
fi

echo "=== disabling superseded modules ==="
for m in phhimspriv iwlanpriv; do
  if [ -d /data/adb/modules/$m ]; then
    touch /data/adb/modules/$m/disable && echo "  $m -> disabled"
  fi
done

echo "=== after (takes effect on reboot) ==="
for m in phhimspriv iwlanpriv vowifi_stack; do
  if [ -d /data/adb/modules/$m ]; then
    [ -f /data/adb/modules/$m/disable ] && echo "  $m: disabled" || echo "  $m: ENABLED"
  else
    echo "  $m: absent"
  fi
done
echo
echo "REBOOT required. To roll back before rebooting:"
echo "  rm /data/adb/modules/phhimspriv/disable /data/adb/modules/iwlanpriv/disable"
echo "  touch /data/adb/modules/vowifi_stack/disable"
