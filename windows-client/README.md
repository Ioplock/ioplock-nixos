# Mic forwarding to mimosa (Sunshine host) — client setup

Senders live on the client PCs; the receiver runs on mimosa as an `snd-aloop`
virtual mic. Start a sender on the PC you are streaming from — **one machine
at a time** (Sunshine does not tell the host which client connected, so there
is no auto-trigger; concurrent senders collide on the receiver's single UDP
socket and decode as garbage).

Transport is identical on every client: capture the default mic, encode Opus,
stream RTP/UDP to `mimosa:5004`.

---

## Linux client (acrux)

Everything is prebuilt: the `mic-forward-send` user unit and a toggle
shortcut ship with the config (`modules/features/mic-forward.nix`).

Start / stop:

```bash
# Mod+M on acrux toggles the sender (hotkey overlay entry:
# "Toggle Mic Forward"), or manually:
systemctl --user start mic-forward-send
systemctl --user stop mic-forward-send
systemctl --user status mic-forward-send   # is it running?
```

Host/port are set in `modules/hosts/acrux/configuration.nix`
(`myMicForward.host` / `receivePort`) — change them there, not in scripts.

---

## Windows client (any PC)

### One-time setup

1. Install [GStreamer](https://gstreamer.freedesktop.org/download/) for
   Windows (64-bit MSVC). The **runtime installer is sufficient** — it ships
   `gst-launch-1.0.exe` and the `opusenc`/`rtpopuspay`/`udpsink` plugins
   (base + good). Development headers are not needed.
   - `winget install gstreamerproject.gstreamer` (correct package ID), or the
     official installer; run it with `/TYPE=runtime` for an unattended
     runtime install.
   - Add the install's `bin` directory (e.g.
     `%LOCALAPPDATA%\Programs\gstreamer\1.0\msvc_x86_64\bin`) to `PATH`, and
     verify with `gst-launch-1.0 --version` in a fresh shell.
2. Copy `mic-forward-send.ps1` and `mic-forward-stop.ps1` from this folder to
   a stable folder on the PC (e.g. `C:\Users\<you>\mic-forward\`).

Start / stop:

```powershell
# start (leave the console window open while talking)
powershell -ExecutionPolicy Bypass -File C:\Users\<you>\mic-forward\mic-forward-send.ps1
# stop: Ctrl+C, close the window, or:
powershell -ExecutionPolicy Bypass -File C:\Users\<you>\mic-forward\mic-forward-stop.ps1
```

Optional desktop shortcuts: "Mic ON" → the send script, "Mic OFF" → the stop
script.

Host/port live in `$HostAddr`/`$SendPort` at the top of both scripts — they
must match `myMicForward.host` / `receivePort` on mimosa (defaults
`192.168.1.92` / `5004`).

---

## Verify (from any client)

The receiver runs on mimosa, so these checks run **on mimosa** — SSH works
from both Linux and Windows 10/11 (which ships an OpenSSH client):

```bash
ssh mimosa@192.168.1.92
wpctl list audio sources   # "Virtual Mic" source must be listed
pactl list sources short   # alternative listing
```

Then start Moonlight, start the sender, and talk — the Virtual Mic meter on
mimosa should move (watchable with `pavucontrol` on mimosa).

## Caveats

- Exactly **one** sender at a time — starting a second PC's sender while
  another is running corrupts the audio on mimosa.
- Inbound RTP on mimosa:5004 is unauthenticated; only use on a trusted home
  network.
- Debug a Windows sender by changing `-q` to `-v` on `gst-launch` in the
  script.
