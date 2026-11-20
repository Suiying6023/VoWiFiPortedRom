#!/system/bin/sh
# The complete override contract, shared by boot injection and regression checks.
cc_is_foreign() {
  PLMN=${1##*-}
  PLMN=${PLMN%.xml}
  case "$PLMN" in ''|*[!0-9]*|460*) return 1;; esac
  [ "${#PLMN}" -eq 5 ] || [ "${#PLMN}" -eq 6 ]
}

cc_enable_wfc() {
  content query --uri content://telephony/siminfo \
    --projection _id:sim_id:mcc_string:wfc_ims_enabled:wfc_ims_mode:wfc_ims_roaming_enabled:wfc_ims_roaming_mode 2>/dev/null |
  while IFS= read -r LINE; do
    ID=$(echo "$LINE" | sed -n 's/.*[ ,]_id=\([0-9]*\).*/\1/p')
    SIM=$(echo "$LINE" | sed -n 's/.*sim_id=\([-0-9]*\).*/\1/p')
    MCC=$(echo "$LINE" | sed -n 's/.*mcc_string=\([^, ]*\).*/\1/p')
    EN=$(echo "$LINE" | sed -n 's/.*wfc_ims_enabled=\([-0-9]*\).*/\1/p')
    MD=$(echo "$LINE" | sed -n 's/.*wfc_ims_mode=\([-0-9]*\).*/\1/p')
    ROAM_EN=$(echo "$LINE" | sed -n 's/.*wfc_ims_roaming_enabled=\([-0-9]*\).*/\1/p')
    ROAM_MD=$(echo "$LINE" | sed -n 's/.*wfc_ims_roaming_mode=\([-0-9]*\).*/\1/p')
    [ -n "$ID" ] || continue
    case "$SIM" in 0|1) ;; *) continue;; esac
    case "$MCC" in 460|''|*[!0-9]*) continue;; esac
    [ "${#MCC}" -eq 3 ] || continue
    if [ "$EN:$MD:$ROAM_EN:$ROAM_MD" != "1:0:1:0" ]; then
      if content update --uri "content://telephony/siminfo/$ID" \
        --bind wfc_ims_enabled:i:1 --bind wfc_ims_roaming_enabled:i:1 \
        --bind wfc_ims_mode:i:0 --bind wfc_ims_roaming_mode:i:0; then
        echo "  enabled WFC WIFI_ONLY on slot $SIM"
      else
        echo "  WFC update failed on slot $SIM" >&2
      fi
    fi
  done
}

cc_entries() {
  cat <<'ENTRIES'
config_ims_mmtel_package_override_string me.phh.ims
carrier_data_service_wlan_package_override_string com.google.android.iwlan
carrier_data_service_wlan_class_override_string com.google.android.iwlan.IwlanDataService
carrier_network_service_wlan_package_override_string com.google.android.iwlan
carrier_network_service_wlan_class_override_string com.google.android.iwlan.IwlanNetworkService
carrier_qualified_networks_service_package_override_string com.voxi.minqns
carrier_qualified_networks_service_class_override_string com.voxi.minqns.MinQnsService
ENTRIES
}

cc_wfc_bool_entries() {
  cat <<'BOOLS'
carrier_wfc_ims_available_bool true
carrier_wfc_supports_wifi_only_bool true
carrier_default_wfc_ims_enabled_bool true
carrier_default_wfc_ims_roaming_enabled_bool true
BOOLS
}

cc_wfc_int_entries() {
  cat <<'INTS'
carrier_default_wfc_ims_mode_int 0
carrier_default_wfc_ims_roaming_mode_int 0
INTS
}

cc_valid() {
  [ "$(grep -o '</bundle>' "$1" | wc -l)" = "1" ] || return 1
  [ "$(grep -c 'name="config_ims_package_override_string"' "$1")" = "0" ] || return 1
  cc_entries | while read -r KEY VALUE; do
    [ "$(grep -oF "name=\"$KEY\"" "$1" | wc -l)" = "1" ] || exit 1
    grep -Fq "<string name=\"$KEY\">$VALUE</string>" "$1" || exit 1
  done || return 1
  cc_wfc_bool_entries | while read -r KEY VALUE; do
    [ "$(grep -oF "name=\"$KEY\"" "$1" | wc -l)" = "1" ] || exit 1
    grep -Fq "<boolean name=\"$KEY\" value=\"$VALUE\"" "$1" || exit 1
  done || return 1
  cc_wfc_int_entries | while read -r KEY VALUE; do
    [ "$(grep -oF "name=\"$KEY\"" "$1" | wc -l)" = "1" ] || exit 1
    grep -Fq "<int name=\"$KEY\" value=\"$VALUE\"" "$1" || exit 1
  done
}

cc_render() {
  [ "$(grep -o '</bundle>' "$1" | wc -l)" = "1" ] || return 1
  {
    cc_entries | awk '{print "string", $1, $2}'
    cc_wfc_bool_entries | awk '{print "boolean", $1, $2}'
    cc_wfc_int_entries | awk '{print "int", $1, $2}'
  } | awk '
    NR == FNR { types[NR]=$1; keys[NR]=$2; vals[NR]=$3; n=NR; next }
    {
      if ($0 ~ /name="config_ims_package_override_string"/) next
      skip=0
      for (i=1; i<=n; i++) {
        if (index($0, "name=\"" keys[i] "\"") > 0) { skip=1; break }
      }
      if (skip) next
      if ($0 ~ /<\/bundle>/) {
        for (i=1; i<=n; i++) {
          if (types[i] == "string")
            printf "<string name=\"%s\">%s</string>\n", keys[i], vals[i]
          else if (types[i] == "boolean")
            printf "<boolean name=\"%s\" value=\"%s\" />\n", keys[i], vals[i]
          else if (types[i] == "int")
            printf "<int name=\"%s\" value=\"%s\" />\n", keys[i], vals[i]
        }
      }
      print
    }' - "$1" > "$2" || return 1
  cc_valid "$2" && [ "$(grep -o '</bundle>' "$2" | wc -l)" = "1" ]
}

cc_has_ours() {
  grep -qF 'me.phh.ims' "$1" || grep -qF 'com.google.android.iwlan' "$1" || grep -qF 'com.voxi.minqns' "$1"
}

cc_remove_ours() {
  [ "$(grep -o '</bundle>' "$1" | wc -l)" = "1" ] || return 1
  {
    cc_entries
    echo 'config_ims_package_override_string me.phh.ims'
  } | awk '
    NR == FNR { tokens[++n]="<string name=\"" $1 "\">" $2 "</string>"; next }
    {
      for (i=1; i<=n; i++) {
        while ((at=index($0, tokens[i])) > 0)
          $0=substr($0, 1, at-1) substr($0, at+length(tokens[i]))
      }
      if ($0 !~ /^[[:space:]]*$/) print
    }' - "$1" > "$2" || return 1
  [ "$(grep -o '</bundle>' "$2" | wc -l)" = "1" ]
}
