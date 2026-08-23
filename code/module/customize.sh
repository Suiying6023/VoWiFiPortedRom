#!/system/bin/sh
# Install-time checks and setup for the VoWiFi stack module.
SKIPUNZIP=0

ui_print " "
ui_print "  VoWiFi stack: Iwlan + floss-ims + MinQns"
ui_print " "

# --- Compatibility check -------------------------------------------------
# This module was built and tested on exactly ONE target:
#   Redmi K50 Ultra / 12T Pro (diting, 22081212C)
#   HyperOS 4 port by Coolapk @江南烟雨断桥殇, Android 17 (API 37)
#
# It is NOT generic. The pieces that are device/ROM specific:
#   * the IMS APK reflects HyperOS's notifyCapabilitiesStatusChanged, whose
#     signature differs from AOSP's -- on a different ROM this call fails and the
#     framework never learns the stack can do WiFi calling
#   * it is compiled against Android 17 APIs (Android 17 removed the hidden
#     ServerSocket.getFileDescriptor$ this code used to reflect on)
#   * the carrier-config keys are injected for whatever SIM is present, but the
#     ePDG/IMS values themselves come from your carrier
#
# So: warn loudly on a mismatch, but do not refuse. Someone on a similar port may
# well want to try it, and the guide explains what to change if it does not work.
DEV=$(getprop ro.product.device)
MODEL=$(getprop ro.product.model)
API=$(getprop ro.build.version.sdk)
OSVER=$(getprop ro.mi.os.version.name)

ui_print "- Device : $MODEL ($DEV)"
ui_print "- Android: API $API   HyperOS: ${OSVER:-unknown}"
ui_print " "

MATCH=1
[ "$DEV" = "diting" ] || MATCH=0
[ "$API" = "37" ] || MATCH=0

if [ "$MATCH" = "1" ]; then
  ui_print "- Target matches (diting / API 37). This is the tested combination."
else
  ui_print "*********************************************************"
  ui_print "! NOT the tested device/ROM."
  ui_print "!"
  ui_print "! Tested ONLY on: Redmi K50 Ultra / 12T Pro (diting),"
  ui_print "! HyperOS 4 port by Coolapk \@江南烟雨断桥殇, API 37."
  ui_print "!"
  ui_print "! Installing anyway is safe to TRY -- it does not modify any"
  ui_print "! partition, and the module can be removed again. But expect it"
  ui_print "! not to work, most likely with the framework never reporting"
  ui_print "! isVowifiEnabled=true."
  ui_print "!"
  ui_print "! To adapt it, see README.md in the repo: you will at least need"
  ui_print "! to rebuild the IMS APK against YOUR ROM's framework.jar."
  ui_print "*********************************************************"
  ui_print " "
fi

# A KernelSU/Magisk-style module is required (we mount into /system_ext).
if [ ! -d /data/adb/modules ]; then
  abort "! /data/adb/modules missing -- is this KernelSU/Magisk?"
fi

# Disable earlier separate modules that shipped the same packages under different
# priv-app directory names. Two priv-app directories carrying the same package name
# is undefined for the package manager -- one silently wins, and which one is not
# something to leave to chance. Disabled rather than deleted, so it is reversible.
for OLD in phhimspriv iwlanpriv; do
  if [ -d "/data/adb/modules/$OLD" ] && [ ! -f "/data/adb/modules/$OLD/disable" ]; then
    touch "/data/adb/modules/$OLD/disable"
    ui_print "- Disabled superseded module: $OLD (this module replaces it)"
  fi
done

# The three APKs must land as priv-app with the right SELinux label. An apk left
# as adb_data_file is silently ignored by the package manager at boot -- that cost
# a full debugging round earlier in this project.
ui_print "- Setting permissions and SELinux labels"
set_perm_recursive "$MODPATH/system" 0 0 0755 0644
for D in PhhIms IwlanAosp MinQns; do
  chcon -R u:object_r:system_file:s0 "$MODPATH/system/system_ext/priv-app/$D" 2>/dev/null
done
chcon -R u:object_r:system_file:s0 "$MODPATH/system/system_ext/etc/permissions" 2>/dev/null

# Ship the diagnostics where the docs say they live, but do not start anything.
if [ -d "$MODPATH/tools" ]; then
  ui_print "- Installing diagnostics to /data/local/tmp"
  for F in "$MODPATH"/tools/*.sh; do
    [ -f "$F" ] || continue
    cp "$F" "/data/local/tmp/$(basename "$F")"
    chmod 755 "/data/local/tmp/$(basename "$F")"
  done
  ui_print "  run: su -c 'sh /data/local/tmp/phh_status.sh'"
fi

ui_print " "
ui_print "- Installed. REBOOT is required:"
ui_print "  privileged permissions are evaluated from the priv-app"
ui_print "  manifest at scan time, so they only take effect on boot."
ui_print " "
ui_print "- After reboot, carrier-config overrides are re-injected by"
ui_print "  service.sh about 30s after boot completes. Check:"
ui_print "    /data/local/tmp/vowifi_stack_boot.log"
ui_print " "
ui_print "! This does NOT configure your carrier's ePDG address or APN."
ui_print "  Those come from the SIM/carrier config. See the project notes."
ui_print " "
