clean() {
  printf '%s' "${1:-}" | tr '\t\r\n' '   '
}

workspace="$(
  niri msg -j workspaces 2>/dev/null |
    jq -r 'map(select(.is_focused))[0] | .name // (.idx | tostring) // "?"' 2>/dev/null ||
    printf '?'
)"

title="$(
  niri msg -j focused-window 2>/dev/null |
    jq -r '.title // "Desktop"' 2>/dev/null ||
    printf 'Desktop'
)"

language="$(
  niri msg -j keyboard-layouts 2>/dev/null |
    jq -r '.names[.current_idx] // "unknown"' 2>/dev/null ||
    printf 'unknown'
)"

volume="$(
  wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null |
    awk '{
      if ($0 ~ /MUTED/) {
        print "muted"
      } else {
        printf "%d%%\n", ($2 * 100) + 0.5
      }
    }' ||
    printf 'unknown'
)"

wifi="$(
  nmcli -t -f TYPE,STATE,CONNECTION device status 2>/dev/null |
    awk -F: '$1 == "wifi" && $2 == "connected" { print $3; found = 1; exit } END { if (!found) print "disconnected" }'
)"

if bluetoothctl show 2>/dev/null | grep -q $'^\tPowered: yes$'; then
  bluetooth_count="$(bluetoothctl devices Connected 2>/dev/null | wc -l)"
  if [ "$bluetooth_count" -gt 0 ]; then
    bluetooth="${bluetooth_count} connected"
  else
    bluetooth="on"
  fi
else
  bluetooth="off"
fi

battery="AC"
for battery_path in /sys/class/power_supply/BAT*; do
  if [ -d "$battery_path" ]; then
    battery="$(cat "$battery_path/capacity")% $(cat "$battery_path/status")"
    break
  fi
done

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$(clean "$workspace")" \
  "$(clean "$title")" \
  "$(clean "$language")" \
  "$(clean "$volume")" \
  "$(clean "$wifi")" \
  "$(clean "$bluetooth")" \
  "$(clean "$battery")"
