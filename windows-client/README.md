# Mic forwarding to mimosa (Sunshine host) — client setup

Senders live on the client PCs; the receiver runs on mimosa. Start a sender
on the PC you are streaming from — **one machine at a time** (Sunshine does
not tell the host which client connected, so there is no auto-trigger).

Two transport paths exist:

- **Windows → VoiceMeeter/VBAN** (recommended): PCM over UDP 6980, received
  natively by mimosa's PipeWire as a "Virtual Mic (VBAN)" source. No
  scripting on Windows.
- **Any Linux client → RTP/Opus** (acrux, Mod+M): Opus over UDP 5004, decoded
  by a GStreamer receiver into the snd-aloop "Virtual Mic". The Windows
  GStreamer scripts below are a fallback for the same path.

Only one sender may stream at a time; concurrent senders produce garbage.

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

### Recommended: VoiceMeeter + VBAN (no scripts)

1. Install [VoiceMeeter](https://vb-audio.com/Voicemeeter/) (Basic, free) and
   reboot — it installs a virtual audio driver.
2. Run VoiceMeeter:
   - Click **Hardware Input 1**, select your physical microphone.
   - On that input strip click **B1** (routes the mic to the virtual bus; do
     not enable A1 unless you want to hear yourself locally).
   - Open the **VBAN** dialog (button top-right) → *Outgoing Streams*:
     enable a slot, Name `mic`, IP `192.168.1.92`, Port `6980`, SR `48000`,
     Format `PCM 16 bits`, Source `B1`, tick **On**.
3. Keep VoiceMeeter running while streaming — Menu → *System Tray* and
   *Run on Windows Startup* make this automatic.
4. Windows Settings → Privacy & security → Microphone → allow desktop apps.

While a VBAN stream arrives, mimosa's default input becomes **Virtual Mic
(VBAN)**; when it stops, the node vanishes and the snd-aloop **Virtual Mic**
(acrux path) becomes the default again. No start/stop commands needed.

### Alternative: GStreamer scripts (same RTP path as Linux)

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
   a stable folder on the PC (e.g. `C:\mic-forward\`).

Start / stop:

```powershell
# start (leave the console window open while talking)
powershell -ExecutionPolicy Bypass -File C:\mic-forward\mic-forward-send.ps1
# stop: Ctrl+C, close the window, or:
powershell -ExecutionPolicy Bypass -File C:\mic-forward\mic-forward-stop.ps1
```

Gotcha: the sender is independent of Moonlight — closing Moonlight does
**not** stop it. A leftover sender plus a new one on another PC collides on
mimosa's single RTP socket and decodes as garbage. The send script kills
leftovers on its own PC first; always stop it on the machine you are leaving.

Host/port live in `$HostAddr`/`$SendPort` at the top of both scripts — they
must match `myMicForward.host` / `receivePort` on mimosa (defaults
`192.168.1.92` / `5004`).

---

## Verify (from any client)

The receiver runs on mimosa, so these checks run **on mimosa** — SSH works
from both Linux and Windows 10/11 (which ships an OpenSSH client):

```bash
ssh mimosa@192.168.1.92
wpctl status   # Sources: which virtual mic is default (the * marker)
```

Then start Moonlight, start the sender, and talk — the active virtual mic's
meter should move (watchable with `pavucontrol` on mimosa):

- VBAN path: a **Virtual Mic (VBAN)** source appears under *Sources* while
  VoiceMeeter streams and carries the `*` default marker.
- RTP path: a `gst-launch-1.0` entry appears under *Streams*, connected to
  *Loopback PCM*, while the sender runs.

## Troubleshooting

1. **Exactly one sender must exist in total.** RTP path on Windows:
   `Get-Process gst-launch-1.0`, kill strays with
   `Stop-Process -Name gst-launch-1.0 -Force`. VBAN path: only one
   VoiceMeeter should have its outgoing stream On.
2. **RTP receiver sees the stream?** On mimosa: `wpctl status` — while you
   talk there must be **exactly one** `gst-launch-1.0` entry under *Streams*
   connected to *Loopback PCM*, and `Virtual Mic` must be the default (the
   `*` under *Sources*). Zero entries → sender not sending; two → collision
   (kill all senders, start one).
3. **VBAN node missing?** Check the slot is ticked **On** with the right IP
   and Port 6980, VoiceMeeter is running, and the strip is routed to the
   bus chosen as the stream Source (B1).
4. **Windows blocks the mic?** Settings → Privacy & security → Microphone →
   *Let desktop apps access your microphone* must be on.
5. **RTP sender captures anything?** Local sanity check on Windows:
   `gst-launch-1.0 -v autoaudiosrc ! level ! fakesink` — the printed RMS
   values should move when you speak (Ctrl+C to stop).

## Caveats

- Exactly **one** sender at a time — starting a second PC's sender while
  another is running corrupts the audio on mimosa.
- Inbound RTP on mimosa:5004 and VBAN on :6980 are unauthenticated; only use
  on a trusted home network.
- Debug the RTP path by changing `-q` to `-v` on `gst-launch` in the script.
