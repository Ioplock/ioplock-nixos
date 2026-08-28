# Sends this Windows PC's default mic to mimosa's virtual mic as RTP/Opus.
# Run on the PC you are streaming from. Any sender already running on this
# PC (including one orphaned by a closed console window — closing Moonlight
# does NOT stop it) is killed first: two simultaneous senders corrupt the
# audio on mimosa.
$HostAddr = "192.168.1.92"
$SendPort = 5004

$ErrorActionPreference = "Continue"
$existing = Get-Process -Name "gst-launch-1.0" -ErrorAction SilentlyContinue
if ($existing) {
  $existing | Stop-Process -Force
  Write-Host "Killed $($existing.Count) leftover sender(s) on this PC."
}

Write-Host "Streaming mic to ${HostAddr}:${SendPort} — keep this window open."
Write-Host "Stop with Ctrl+C, by closing this window, or via mic-forward-stop.ps1."
$ErrorActionPreference = "Stop"
& gst-launch-1.0.exe -q `
  autoaudiosrc ! audioconvert ! audioresample ! audio/x-raw,rate=48000,channels=1 ! `
  opusenc ! rtpopuspay pt=96 ! `
  udpsink host=$HostAddr port=$SendPort auto-multicast=0
Write-Host "Sender exited."
