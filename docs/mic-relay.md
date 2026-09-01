# Mic Relay — LAN mic passthrough to mimosa

`mic-relay` solves the Sunshine/Moonlight mic problem: the host (`mimosa`,
`192.168.1.92`) is headless in another room, but games streamed via Sunshine
need a microphone. The client on your gaming machine (`acrux`,
`192.168.1.92`, Windows, or any LAN host) captures its local mic, encodes it
with Opus, and sends it over UDP to `mimosa`. `mimosa` exposes a virtual
PipeWire source `MicRelay.monitor` that games see as a normal mic. Only one
client is *Active* at a time (exclusive).

```
acrux / Windows / phone ──TCP 50051──► mimosa (mic-relay server)
        ──UDP 50052 Opus──►             ──► MicRelay (null-sink) ──► MicRelay.monitor
                                                          ▲
                                                          │ games select this
```

---

## How it works

### Pieces

| Piece | Where | Crate / module |
|---|---|---|
| Headless server + virtual mic | `mimosa` | `pkgs/mic-relay/src/server.rs`, `audio.rs:spawn_output_playback` |
| GUI client (Linux) | `acrux` | `pkgs/mic-relay/src/client.rs` + `gui.rs` (egui/eframe, lucide) |
| Windows GUI | Windows | same crate, cross-compiled (`client` feature) |
| Headless ctl CLI | anywhere | `pkgs/mic-relay/src/ctl.rs` (`mic-relay ctl …`) |
| mDNS discovery | LAN | `pkgs/mic-relay/src/mdns.rs` (`_mic-relay._tcp.local.`, `mdns-sd`) |

### Server (`mimosa`)

1. **Virtual source** – on start `server.rs:ensure_virtual_source` runs
   `pactl load-module module-null-sink sink_name=MicRelay` (fallback
   `pw-cli create … support.null-audio-sink`). The sink’s monitor
   `MicRelay.monitor` is the mic games select. If PipeWire isn’t ready it logs
   a warning and still serves control.
2. **mDNS** – `MdnsPublisher::new("MicRelay", 50051)` advertises
   `MicRelay-mimosa._mic-relay._tcp.local. → 192.168.1.92:50051`. Clients use
   `mdns::browse(1200ms)` or fall back to `192.168.1.92:50051`.
3. **Playback** – `audio::spawn_output_playback("MicRelay")` finds the output
   device whose name contains `MicRelay` (else default), builds a `cpal` output
   stream and a `rtrb::RingBuffer<f32>(48000*4)`. The stream’s callback pops
   `f32` mono and duplicates to all channels (F32/I16/U16 handled). The
   `Producer` is kept behind `Arc<Mutex<Producer>>` and `mem::forget`’d for the
   server lifetime.
4. **Audio loop** – `audio_loop` binds UDP `0.0.0.0:50052`, for each datagram
   checks `AudioHeader::decode` (12 bytes: `seq|timestamp_ms|client_id_hash`),
   drops frames whose `hash != hash(active_id)`, decodes Opus (`opus::Decoder`
   48k mono) and pushes `f32` to the ring. Without `opus` it just logs.
5. **Control** – `TcpListener` on `0.0.0.0:50051`. Each `handle_client` does:
   * `Hello {client_id,name,version}` → assigns `c-{port}-{hash(name)}` if empty,
     dedupes stale same-host `name+IP` entries, inserts `ClientInfo`,
     replies `HelloAck {assigned_id}` + initial `ClientList`, then broadcasts
     new list.
   * Writer task forwards `broadcast::channel` messages (`ClientList`,
     `ActiveChanged`, `VuUpdate`, `Pong`) to the TCP stream.
   * Reader loop handles `RequestActive` (Take: `client_id = your_id`; Release:
     `client_id = ""`), `VuUpdate`, `Mute`, `Kick`, `Ping` (which also
     rebroadcasts `ClientList` to heal missed initial lists). `RequestActive`
     drops the `RwLock` before `broadcast_list` to avoid deadlock.

`ServerState` (`server.rs:22`) holds `clients: HashMap<id, ClientRecord>`,
`active_id: Option<String>`, `source_ok`, `start_time`. `snapshot()` sorts by
name.

### Client (Linux GUI, Windows)

* `client.rs:run` resolves the server via `mdns::browse` or the explicit
  `--server` arg, then `gui::run_gui` (eframe `560×420`, glow).
* `gui.rs:network_task` connects TCP, sends `Hello`, stores `my_id` from
  `HelloAck`, then **offloads** `audio::spawn_input_capture` to
  `spawn_blocking` so the initial `ClientList` isn’t delayed (the old bug:
  “connected but no client list”). If no `ClientList` in 800 ms it sends
  `Ping` (server rebroadcasts).
* `spawn_input_capture` (`audio.rs`) probes `cpal::default_input_device`,
  prefers 48 kHz mono F32 (else device default), downmixes, naive resamples if
  needed, computes `rms_db` → `-100…0 dBFS` VU, encodes 960-sample (20 ms) Opus
  frames at 32 kbps VBR, and sends UDP `AudioHeader.encode() + opus` **only
  when `is_active()`** (`active_id == my_id`). On `cpal` error it falls back to
  synthetic VU jitter (still sends `VuUpdate` so the UI moves).
* VU is sent as `VuUpdate {client_id, vu_db}` over TCP; server rebroadcasts it
  so all clients see live meters. The “You” card shows local VU instantly,
  the peers list shows the last broadcast VU (progress bar `0…1` from `-60…0 dB`).
* Take/Release are `RequestActive` via an `mpsc::UnboundedSender` (`ControlTx`);
  the UI shows **Take Mic** when `active_id != my_id`, **Release** when active.

Filtering: the peers list is `st.clients` filtered by `id != my_id` so the
“You” card is the single source for self – fixes the “me and also me in
clients” duplicate.

### Protocol (`protocol.rs`)

* Control TCP: newline-delimited JSON `ControlMessage` (serde `tag="type"`):

  ```json
  {"type":"hello","client_id":"","name":"acrux","version":"0.1.0"}
  {"type":"hello_ack","assigned_id":"c-54321-12345"}
  {"type":"client_list","clients":[…],"active_id":"c-…"}
  {"type":"request_active","client_id":"c-…"}   // "" = release
  {"type":"active_changed","active_id":"c-…","active_name":"acrux"}
  {"type":"vu_update","client_id":"c-…","vu_db":-24.0}
  {"type":"mute","client_id":"c-…","muted":true}
  {"type":"kick","client_id":"c-…"}
  {"type":"ping"} / {"type":"pong"}
  ```

  `ClientInfo {id,name,ip,state: connected|active|muted|idle, vu_db, connected_at}`.
* Audio UDP: `AudioHeader` 12 bytes big-endian `seq:u32 | timestamp_ms:u32 |
  client_id_hash:u32` (`hash_client_id` = djb2 `h=5381; h=h*33+b`) + Opus payload.
  Server drops non-active hashes, decodes, ring-queues.
* Feature flags: `client` enables `eframe/egui/lucide/cpal/opus/rtrb`,
  `server` enables `cpal/opus/rtrb`, `cli` is always present.

---

## NixOS module (`modules/features/mic-relay.nix`)

Dendritic flake-parts module exposing `flake.nixosModules.micRelay`:

```nix
myMicRelay.enable = true;
myMicRelay.role = "server"; # "server" | "client" | "both"
myMicRelay.server = {
  port = 50051; audioPort = 50052;
  sourceName = "MicRelay"; # games see MicRelay.monitor
  openFirewall = true;      # TCP port + UDP audioPort+5353
  mdns = true;
};
myMicRelay.client.autoStart = false;
```

* `role == "server"` (mimosa) – `systemd.user.services.mic-relay-server`
  (`after pipewire.service`, `wantedBy default.target`, `path = [pipewire pulseaudio]`,
  `ExecStart = mic-relay server …`, `Restart=always`, `RUST_LOG=info`),
  `myUser.linger = mkDefault true`, `services.avahi` + `networking.firewall`,
  `environment.systemPackages` includes `myMicRelayServer` + `pipewire`.
* `role == "client"` (acrux) – `environment.systemPackages` includes
  `myMicRelay` (full GUI), optional `systemd.user.services.mic-relay-client`
  for autostart.
* `perSystem.packages`:
  `myMicRelay` (`rustPlatform.buildRustPackage`, `client,cli,server`,
  `LD_LIBRARY_PATH` wrap for `wayland`), `myMicRelayServer`
  (`--no-default-features --features server,cli`, no GUI deps),
  `myMicRelayWindowsCross` (`pkgsCross.mingwW64`, `x86_64-pc-windows-gnu`),
  `myMicRelayBuildWindows` (`writeShellApplication` docker helper).

Host wiring: `modules/hosts/mimosa/configuration.nix:8`,
`modules/hosts/acrux/configuration.nix:8` import `self.nixosModules.micRelay`.

Builds live in `pkgs/mic-relay` (outside `modules/` so `import-tree` ignores them;
Nix references `../../pkgs/mic-relay`).

---

## Using it

### On NixOS (acrux/mimosa)

```bash
nix flake check --no-build
nixos-rebuild dry-build --flake .#acrux   # or .#mimosa
nix build .#myMicRelay        # GUI + ctl + server in one binary
nix build .#myMicRelayServer  # headless only, smaller closure
```

Run manually:

```bash
nix run .#myMicRelayServer -- server --source-name MicRelay --port 50051 --audio-port 50052
nix run .#myMicRelay -- client --server 192.168.1.92:50051 --name acrux
nix run .#myMicRelayServer -- ctl --server 192.168.1.92:50051 status
nix run .#myMicRelayServer -- ctl --server 192.168.1.92:50051 list --json
nix run .#myMicRelayServer -- ctl --server 127.0.0.1:50051 active <client-id>  # take
# release is RequestActive with "" — use the GUI Release button or:
printf '{"type":"request_active","client_id":""}\n' | nc 192.168.1.92 50051
```

GUI: Discover finds mDNS peers, otherwise enter `192.168.1.92:50051`.
**Take Mic** makes you exclusive Active (green banner), **Release** clears it.
Select **`MicRelay.monitor`** as the mic in the game / Discord / etc. Verify:

```bash
pactl list sinks | grep -A2 MicRelay
pactl list sources | grep MicRelay
pw-record --target MicRelay.monitor --format f32 /tmp/test.wav  # speak, Ctrl-C, aplay
```

Systemd: `systemctl --user status mic-relay-server` on mimosa,
`journalctl --user -u mic-relay-server -f`.

### Logs

`RUST_LOG=info` (default), `RUST_LOG=debug` for `handle_client` “hello”,
“sending HelloAck”, “take/release requested”, “active set/cleared”,
“removing stale duplicate”.

---

## Compiling for Windows

The crate is `cpal` (WASAPI on Windows) + `opus` + `egui` – all cross-compilable.
Two paths are exposed; **Docker is the reliable one** (avoids mingw `libopus`
mismatches).

### 1. Docker builder (recommended) — `Dockerfile.windows`

Prereqs: Docker with BuildKit (NixOS `virtualisation.docker.enable = true`).

```bash
# Via the Nix helper (wraps docker build + cp)
nix run .#micRelayBuildWindows -- pkgs/mic-relay result-win
# → result-win/mic-relay.exe  (ls -lh shown)

# Or manually:
docker build -f pkgs/mic-relay/Dockerfile.windows -t mic-relay-windows-builder .
docker create --name tmp mic-relay-windows-builder
docker cp tmp:/out/mic-relay.exe ./mic-relay.exe
docker rm tmp
```

`Dockerfile.windows` (`FROM rust:1.82-bookworm`) installs
`mingw-w64 pkg-config cmake clang libopus-dev`, `cargo install cargo-xwin`,
`rustup target add x86_64-pc-windows-gnu`, then
`cargo build --release --target x86_64-pc-windows-gnu --features client,cli`.
The exe is at `/out/mic-relay.exe` (also `/mic-relay.exe`). Copy to Windows and
run `mic-relay.exe` (or `mic-relay.exe client --server 192.168.1.92:50051`);
it uses WASAPI, no extra DLLs.

To build MSVC instead of GNU, edit the `RUN cargo build …` line to
`cargo xwin build --release --target x86_64-pc-windows-msvc --features client,cli`
(the `cargo-xwin` install is already in the image).

### 2. Nix cross (`pkgsCross.mingwW64`) — best-effort

```bash
nix build .#myMicRelayWindowsCross --print-out-paths
# → /nix/store/…-mic-relay-windows-0.1.0/bin/mic-relay.exe
# (actually x86_64-pc-windows-gnu/mic-relay.exe under the store)
```

`mic-relay.nix:243` defines
`pkgs.pkgsCross.mingwW64.rustPlatform.buildRustPackage` with
`--target x86_64-pc-windows-gnu --features client,cli`, `doCheck = false`,
`buildInputs = [windows.pthreads]`. It’s faster (no Docker) but can fail on
`audiopus_sys`/`libopus` pkg-config differences; if it fails, use Docker.

For both, the Windows binary is a normal GUI app: double-click, or

```powershell
.\mic-relay.exe --help
.\mic-relay.exe client --server 192.168.1.92:50051 --name windows-pc
```

No firewall changes on Windows; only `mimosa` needs `openFirewall = true`
(TCP 50051, UDP 50052 + 5353 mDNS).

### Troubleshooting Windows

* `wayland`/`vulkan` errors don’t exist on Windows (WASAPI backend).
* If `opus` fails to link with mingw, use Docker – it has `libopus-dev` + `clang`.
* Anti-virus may flag the unsigned exe – allow it.
* mDNS may not reach Windows – enter `192.168.1.92:50051` manually and use
  **Connect**.

---

## Security & LAN trust

All control messages are LAN-trust (any client can `Take`/`Release`/`Kick`/
`Mute`). For home LAN this is intentional. If you expose beyond LAN, put it
behind WireGuard/Tailscale and don’t set `openFirewall = true` to WAN.

## Files

* Crate: `pkgs/mic-relay/Cargo.toml` (features `client`/`server`/`cli`), `src/{main,protocol,server,client,gui,audio,mdns,ctl}.rs`, `Dockerfile.windows`
* Nix: `modules/features/mic-relay.nix` (`flake.nixosModules.micRelay`, `perSystem` packages/apps), host wiring in `modules/hosts/{mimosa,acrux}/configuration.nix`
* Docs: this file, `docs/remote-gaming.md` (mic section)

## Gotchas fixed

* Deadlock: `RequestActive`/`Mute`/`Kick` held `RwLock` write across
  `broadcast_list` read – now drop write before broadcast.
* Duplicate self + stale `c-…` after quick reconnect – dedup `name+IP` on hello
  and filter self from peers list.
* `HelloAck` not sent for 3 s after `Take` – same deadlock.
* `wayland` `LD_LIBRARY_PATH` wrap for `eframe`, `pactl`/`pw-cli` in `PATH`,
  synthetic VU fallback when `cpal` probe fails.
