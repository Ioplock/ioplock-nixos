# Stops the mic sender launched by mic-forward-send.ps1.
Stop-Process -Name "gst-launch-1.0" -Force -ErrorAction SilentlyContinue
