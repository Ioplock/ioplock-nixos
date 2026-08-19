if bluetoothctl show 2>/dev/null | grep -q 'Powered: yes'; then
  bluetoothctl power off
else
  rfkill unblock bluetooth
  sleep 0.5
  bluetoothctl power on
fi
