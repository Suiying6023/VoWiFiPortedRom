#!/system/bin/sh
# Keep WiFi power save off: reconnect restores the driver default, and the
# IWLAN socket can be dropped while the radio sleeps between health checks.
while true; do
  iw dev wlan0 set power_save off 2>/dev/null
  sleep 300
done