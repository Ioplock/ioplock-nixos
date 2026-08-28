# Windows mic forward to mimosa (Sunshine host)

Same transport as the Linux sender: capture the Windows default mic and stream
it as RTP/Opus to mimosa's virtual mic. Start it on the PC you are streaming
from — **one machine at a time** (Sunshine does not tell the host which client
connected, so there is no auto-trigger; concurrent senders would collide on
the receiver's single UDP socket and decode as garbage).

## Requirements per Windows PC
- [GStreamer](https://gstreamer.freedesktop.org/download/) for Windows (64-bit
  MSVC). The **runtime installer is sufficient** — it ships `gst-launch-1.0.exe`
  and the `opusenc`/`rtpopuspay`/`udpsink` plugins (base + good). Development
  headers are not needed.
  - `winget install gstreamerproject.gstreamer` (correct package ID), or the
    official installer; run it with `/TYPE=runtime` for an unattended runtime
    install.
  - Add the install's `bin` directory (e.g.
    `%LOCALAPPDATA%\Programs\gstreamer\1.0\msvc_x86_64\bin`) to `PATH`, and
    verify with `gst-launch-1.0 --version` in a fresh shell.
- The `.ps1` scripts, placed in a stable folder (e.g.
  `C:\Users\<you>\mic-forward\`).

## Files
- `mic-forward-send.ps1` — starts the sender
  (`autoaudiosrc → opus → RTP → udpsink mimosa:5004`). Runs in a console
  window; Ctrl+C or close the window to stop, or use the stop script.
- `mic-forward-stop.ps1` — kills any running `gst-launch-1.0` sender.

## Usage
1. Verify the receiver is live on mimosa: `wpctl list audio sources` should
   show the "Virtual Mic" source.
2. Start Moonlight to mimosa as usual, then on the PC you are streaming from:
   ```powershell
   powershell -ExecutionPolicy Bypass -File C:\Users\<you>\mic-forward\mic-forward-send.ps1
   ```
   Talk into the mic and watch mimosa's Virtual Mic meter (`wpctl status`,
   `pactl list sources`, or pavucontrol).
3. When done: Ctrl+C, close the window, or run `mic-forward-stop.ps1`.

Optional desktop shortcuts: "Mic ON" →
`powershell -ExecutionPolicy Bypass -File ...\mic-forward-send.ps1`, "Mic OFF"
→ `...\mic-forward-stop.ps1`.

## Tuning
- `$HostAddr`/`$SendPort` in the scripts must match `myMicForward.host` and
  `receivePort` on mimosa (defaults `192.168.1.92` / `5004`).
- Increase `-q` to `-v` on `gst-launch` to debug.

## Caveats
- Exactly **one** sender at a time — starting a second PC's sender while
  another is running corrupts the audio on mimosa.
- Inbound RTP on mimosa:5004 is unauthenticated; only use on a trusted home
  network.
