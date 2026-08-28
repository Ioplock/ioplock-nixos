# Sends this Windows PC's default mic to mimosa's virtual mic as RTP/Opus.
# Run this on the PC you are streaming from (one machine at a time); stop
# with Ctrl+C or windows-client/mic-forward-stop.ps1.
$HostAddr = "192.168.1.92"
$SendPort = 5004

$ErrorActionPreference = "Stop"
& gst-launch-1.0.exe -q `
  autoaudiosrc ! audioconvert ! audioresample ! audio/x-raw,rate=48000,channels=1 ! `
  opusenc ! rtpopuspay pt=96 ! `
  udpsink host=$HostAddr port=$SendPort auto-multicast=0
