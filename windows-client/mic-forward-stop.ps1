# Stops all mic senders on this PC (run on the machine you are done with).
# Note: closing Moonlight does NOT stop the sender — always stop it here.
$procs = Get-Process -Name "gst-launch-1.0" -ErrorAction SilentlyContinue
if ($procs) {
  $procs | Stop-Process -Force
  Write-Host "Stopped $($procs.Count) mic sender(s)."
} else {
  Write-Host "No mic sender running on this PC."
}
