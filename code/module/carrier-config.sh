#!/system/bin/sh
# The complete override contract, shared by boot injection and regression checks.
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

cc_valid() {
  # Presence alone is insufficient: a stock value or one missing class breaks binding.
  [ "$(grep -o '</bundle>' "$1" | wc -l)" = "1" ] || return 1
  [ "$(grep -c 'name="config_ims_package_override_string"' "$1")" = "0" ] || return 1
  cc_entries | while read -r KEY VALUE; do
    [ "$(grep -oF "name=\"$KEY\"" "$1" | wc -l)" = "1" ] || exit 1
    grep -Fq "<string name=\"$KEY\">$VALUE</string>" "$1" || exit 1
  done
}

cc_render() {
  # Only the flat carrier-cache bundle used on the tested ROM is supported.
  [ "$(grep -o '</bundle>' "$1" | wc -l)" = "1" ] || return 1
  cc_entries | awk '
    NR == FNR { keys[$1]=$2; order[++n]=$1; next }
    {
      if ($0 ~ /name="config_ims_package_override_string"/) next
      for (key in keys) if (index($0, "name=\"" key "\"")) next
      if ($0 ~ /<\/bundle>/) {
        for (i=1; i<=n; i++)
          printf "<string name=\"%s\">%s</string>\n", order[i], keys[order[i]]
      }
      print
    }' - "$1" > "$2" || return 1
  cc_valid "$2" && [ "$(grep -o '</bundle>' "$2" | wc -l)" = "1" ]
}

cc_remove_ours() {
  # Legacy backups can already contain our values. Remove those references
  # while preserving any original stock provider and unrelated carrier settings.
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
