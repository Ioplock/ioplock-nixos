#![allow(dead_code, unused_variables)]
use anyhow::{Context, Result};
use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::SystemTime;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream, UdpSocket};
use tokio::sync::{broadcast, RwLock};
use tracing::{info, warn};

use crate::audio;
use crate::mdns::MdnsPublisher;
use crate::protocol::*;

#[derive(Debug, Clone)]
struct ClientRecord {
    info: ClientInfo,
    addr: SocketAddr,
}

#[derive(Debug)]
struct ServerState {
    clients: HashMap<String, ClientRecord>,
    active_id: Option<String>,
    start_time: SystemTime,
    source_ok: bool,
}

impl ServerState {
    fn new() -> Self {
        Self {
            clients: HashMap::new(),
            active_id: None,
            start_time: SystemTime::now(),
            source_ok: false,
        }
    }
    fn uptime_secs(&self) -> u64 {
        SystemTime::now()
            .duration_since(self.start_time)
            .unwrap_or_default()
            .as_secs()
    }
    fn snapshot(&self) -> (Vec<ClientInfo>, Option<String>) {
        let mut v: Vec<ClientInfo> = self.clients.values().map(|r| r.info.clone()).collect();
        v.sort_by(|a, b| a.name.cmp(&b.name));
        (v, self.active_id.clone())
    }
}

pub async fn run(control_port: u16, audio_port: u16, source_name: String) -> Result<()> {
    let state: Arc<RwLock<ServerState>> = Arc::new(RwLock::new(ServerState::new()));
    let (bcast_tx, _) = broadcast::channel::<ControlMessage>(128);

    // Try to create PipeWire virtual source; non-fatal if it fails (e.g. not running pipewire)
    {
        let ok = ensure_virtual_source(&source_name).await;
        state.write().await.source_ok = ok;
        if ok {
            info!(source=%source_name, "virtual source ready (monitor as game mic)");
        } else {
            warn!(source=%source_name, "virtual source creation failed — audio will be dropped, check pipewire/pactl");
        }
    }

    // mDNS advertisement (best-effort)
    let _mdns = match MdnsPublisher::new(&source_name, control_port) {
        Ok(p) => {
            info!("mDNS advertised as {} on :{}", p.service_name, control_port);
            Some(p)
        }
        Err(e) => {
            warn!(error=%e, "mDNS publish failed — clients must use explicit IP");
            None
        }
    };

    // Playback to virtual mic — via Pulse/pw-cat writer (never via cpal default sink,
    // which was routing mic to speakers/sunshine sink). Small ring + 20 ms latency.
    let playback_prod: std::sync::Arc<std::sync::Mutex<rtrb::Producer<f32>>> = {
        match audio::spawn_virtual_mic_writer(&source_name) {
            Ok(prod_arc) => {
                info!(source=%source_name, "pulse writer to virtual mic ready (sink -> remapped source)");
                prod_arc
            }
            Err(e) => {
                warn!(error=%e, source=%source_name, "pulse writer failed — trying legacy cpal path (will NOT fallback to default)");
                match audio::spawn_output_playback(&source_name) {
                    Ok((stream, prod)) => {
                        info!(source=%source_name, "legacy cpal stream ready (strict, no default fallback)");
                        std::mem::forget(stream);
                        std::sync::Arc::new(std::sync::Mutex::new(prod))
                    }
                    Err(e2) => {
                        warn!(error=%e2, source=%source_name, "all playback backends failed — audio will be decoded but not played");
                        let (prod, _cons) = rtrb::RingBuffer::new(1024);
                        std::sync::Arc::new(std::sync::Mutex::new(prod))
                    }
                }
            }
        }
    };

    // UDP audio task — receives Opus frames, forwards only from active client to virtual sink
    let audio_state = state.clone();
    let audio_bcast = bcast_tx.clone();
    let prod_clone = playback_prod.clone();
    let src_clone = source_name.clone();
    tokio::spawn(async move {
        if let Err(e) = audio_loop(audio_port, audio_state, audio_bcast, src_clone, prod_clone).await {
            warn!(error=%e, "audio loop exited");
        }
    });

    let listener = TcpListener::bind(("0.0.0.0", control_port))
        .await
        .context("bind control TCP")?;
    info!("control listening on 0.0.0.0:{}", control_port);
    info!("audio  listening on 0.0.0.0:{}", audio_port);

    loop {
        let (stream, addr) = listener.accept().await?;
        let st = state.clone();
        let tx = bcast_tx.clone();
        let rx = bcast_tx.subscribe();
        tokio::spawn(async move {
            if let Err(e) = handle_client(stream, addr, st, tx, rx).await {
                warn!(%addr, error=%e, "client handler error");
            }
        });
    }
}

async fn ensure_virtual_source(source_name: &str) -> bool {
    // We need a real Audio/Source that games see as a mic — NOT just the null-sink's
    // monitor (media.class Audio/Sink, `MicRelay.monitor`) which many apps hide and
    // which cpal's ALSA layer routes to the default speaker (audible speakers bug).
    // Steps:
    // 1) Ensure null-sink `MicRelay` exists (its monitor is MicRelay.monitor).
    // 2) Create a remapped source `MicRelay` (or `MicRelayMic` if name collides)
    //    via `module-remap-source master=MicRelay.monitor`. That source is
    //    Audio/Source, appears in `wpctl status Sources` / pactl sources, and is
    //    what games should select. Playback then goes via pacat/pw-cat to the sink
    //    (not cpal default), so it never becomes audible.
    let sink = source_name;

    // --- 1) null-sink ---
    let sink_exists = {
        let out = tokio::process::Command::new("pactl")
            .args(["list", "sinks", "short"])
            .output()
            .await;
        match out {
            Ok(o) => {
                let stdout = String::from_utf8_lossy(&o.stdout);
                stdout.lines().any(|l| l.split_whitespace().nth(1) == Some(sink))
            }
            Err(_) => false,
        }
    };
    if sink_exists {
        info!(sink, "sink already exists");
    } else {
        let desc = format!("MicRelay virtual mic ({sink})");
        let try_pactl = tokio::process::Command::new("pactl")
            .args([
                "load-module",
                "module-null-sink",
                &format!("sink_name={sink}"),
                &format!("sink_properties=device.description=\"{desc}\""),
            ])
            .output()
            .await;
        match try_pactl {
            Ok(o) if o.status.success() => {
                info!(sink, id=%String::from_utf8_lossy(&o.stdout).trim(), "created null sink");
            }
            Ok(o) => {
                warn!(sink, stderr=%String::from_utf8_lossy(&o.stderr), "pactl null-sink failed, trying pw-cli");
                let pw = tokio::process::Command::new("pw-cli")
                    .args(["create", "node", "adapter", &format!("{{ factory.name=support.null-audio-sink node.name={sink} media.class=Audio/Sink }}")])
                    .output()
                    .await;
                match pw {
                    Ok(o2) if o2.status.success() => info!(sink, "created via pw-cli"),
                    Ok(o2) => {
                        warn!(sink, stderr=%String::from_utf8_lossy(&o2.stderr), "pw-cli failed");
                        return false;
                    }
                    Err(e) => {
                        warn!(sink, error=%e, "pw-cli not found");
                        return false;
                    }
                }
            }
            Err(e) => {
                warn!(sink, error=%e, "pactl not found, trying pw-cli");
                let pw = tokio::process::Command::new("pw-cli")
                    .args(["create", "node", "adapter", &format!("{{ factory.name=support.null-audio-sink node.name={sink} media.class=Audio/Sink }}")])
                    .output()
                    .await;
                match pw {
                    Ok(o2) if o2.status.success() => info!(sink, "created via pw-cli"),
                    _ => return false,
                }
            }
        }
        // Small wait for sink to appear
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    }

    // --- 2) remapped source (real mic) ---
    // Check if a non-monitor source with our desired name already exists.
    let source_candidate = sink.to_string(); // try exact name first
    let alt_source = format!("{sink}Mic");
    // Helper to check real source exists (not monitor)
    async fn source_exists(name: &str) -> bool {
        let out = tokio::process::Command::new("pactl")
            .args(["list", "sources", "short"])
            .output()
            .await;
        match out {
            Ok(o) => {
                let stdout = String::from_utf8_lossy(&o.stdout);
                stdout.lines().any(|l| {
                    let parts: Vec<&str> = l.split_whitespace().collect();
                    parts.get(1) == Some(&name) && !name.ends_with(".monitor")
                })
            }
            Err(_) => false,
        }
    }
    // If sink == source name collides (Pulse allows same string for sink vs source,
    // but PipeWire via pactl may reject), we will fallback to alt.
    if source_exists(&source_candidate).await {
        info!(source=%source_candidate, "virtual source already exists");
        return true;
    }
    if source_exists(&alt_source).await {
        info!(source=%alt_source, "virtual source already exists (alt name)");
        return true;
    }
    let mut final_source: String;

    // Try to create remapped source: prefer exact name, fallback to alt
    for try_name in [source_candidate.clone(), alt_source.clone()] {
        let out = tokio::process::Command::new("pactl")
            .args([
                "load-module",
                "module-remap-source",
                &format!("master={sink}.monitor"),
                &format!("source_name={try_name}"),
                &format!("source_properties=device.description=\"{try_name} virtual mic\""),
            ])
            .output()
            .await;
        match out {
            Ok(o) if o.status.success() => {
                let id = String::from_utf8_lossy(&o.stdout).trim().to_string();
                info!(source=%try_name, master=%format!("{sink}.monitor"), id=%id, "created remapped source (real mic)");
                // Verify
                tokio::time::sleep(std::time::Duration::from_millis(150)).await;
                if source_exists(&try_name).await {
                    if try_name != source_candidate {
                        warn!(source=%try_name, wanted=%source_candidate, "created alt source — select this in games (PipeWire disallows same name as sink)");
                    }
                    final_source = try_name;
                    // Also try to set default source to it (best-effort)
                    let _ = tokio::process::Command::new("pactl")
                        .args(["set-default-source", &final_source])
                        .output()
                        .await;
                    return true;
                }
            }
            Ok(o) => {
                let stderr = String::from_utf8_lossy(&o.stderr).to_string();
                warn!(source=%try_name, stderr=%stderr, "remap-source failed, trying next name");
                // If error is about already exists, consider it success
                if stderr.contains("already exists") || stderr.contains("Name already") {
                    return true;
                }
            }
            Err(e) => warn!(source=%try_name, error=%e, "pactl not found for remap"),
        }
    }
    // If remap failed, at least the sink+monitor exists — still usable but hidden in some UIs.
    // Report sink ok but warn.
    warn!(sink=%sink, "remapped source creation failed — fallback to sink monitor {}.monitor (some games hide monitors)", sink);
    // Consider sink alone as half-success: playback will still work via pacat to sink,
    // but user must select .monitor and it may not appear in all apps.
    // Check sink still exists.
    let sink_ok = {
        let out = tokio::process::Command::new("pactl")
            .args(["list", "sinks", "short"])
            .output()
            .await;
        matches!(out, Ok(o) if String::from_utf8_lossy(&o.stdout).contains(sink))
    };
    sink_ok
}

async fn audio_loop(
    port: u16,
    state: Arc<RwLock<ServerState>>,
    _bcast: broadcast::Sender<ControlMessage>,
    source_name: String,
    prod: std::sync::Arc<std::sync::Mutex<rtrb::Producer<f32>>>,
) -> Result<()> {
    let sock = UdpSocket::bind(("0.0.0.0", port)).await?;
    let mut buf = vec![0u8; 8192];
    #[cfg(feature = "opus")]
    let mut decoders: HashMap<u32, opus::Decoder> = HashMap::new();

    loop {
        let (n, addr) = sock.recv_from(&mut buf).await?;
        if n < AudioHeader::SIZE {
            continue;
        }
        let hdr = match AudioHeader::decode(&buf[..AudioHeader::SIZE]) {
            Some(h) => h,
            None => continue,
        };
        let payload = &buf[AudioHeader::SIZE..n];

        // Only forward audio from the active client
        let active_hash = {
            let s = state.read().await;
            s.active_id.as_ref().map(|id| hash_client_id(id))
        };
        if active_hash != Some(hdr.client_id_hash) {
            continue;
        }

        #[cfg(feature = "opus")]
        {
            let decoder = decoders.entry(hdr.client_id_hash).or_insert_with(|| {
                opus::Decoder::new(48000, opus::Channels::Mono).expect("opus decoder")
            });
            let mut pcm = vec![0i16; 960 * 2];
            let decoded = match decoder.decode(payload, &mut pcm, false) {
                Ok(n) => n,
                Err(e) => {
                    warn!(%addr, error=%e, "opus decode failed");
                    continue;
                }
            };
            pcm.truncate(decoded);
            // Push decoded f32 mono to ring buffer for cpal playback
            if let Ok(mut p) = prod.lock() {
                for s in pcm.iter() {
                    let f = *s as f32 / 32768.0;
                    // If ring full, newest sample is dropped (Producer::push fails). That's acceptable for low-latency.
                    let _ = p.push(f);
                }
            }
            if hdr.seq % 200 == 0 {
                info!(seq=hdr.seq, samples=decoded, sink=%source_name, "decoded+queued opus frame");
            }
        }
        #[cfg(not(feature = "opus"))]
        {
            if hdr.seq % 200 == 0 {
                info!(seq=hdr.seq, bytes=payload.len(), sink=%source_name, addr=%addr, "audio frame (no opus decode, raw forward)");
            }
            // Without opus, payload is assumed raw f32 little-endian PCM — not yet played.
        }
    }
}

async fn handle_client(
    stream: TcpStream,
    addr: SocketAddr,
    state: Arc<RwLock<ServerState>>,
    bcast_tx: broadcast::Sender<ControlMessage>,
    mut bcast_rx: broadcast::Receiver<ControlMessage>,
) -> Result<()> {
    let (r, mut w) = stream.into_split();
    let mut reader = BufReader::new(r);
    let mut line = String::new();

    // Expect Hello as first line
    let n = reader.read_line(&mut line).await?;
    if n == 0 {
        return Ok(());
    }
    let hello: Hello = serde_json::from_str(line.trim()).context("parse Hello")?;
    let client_id = if hello.client_id.is_empty() {
        format!("c-{}-{}", addr.port(), hash_client_id(&hello.name))
    } else {
        hello.client_id.clone()
    };
    let name = hello.name.clone();
    info!(%client_id, %name, %addr, "hello");

    {
        let mut s = state.write().await;
        // Deduplicate stale entries from same host (same name+IP) that may linger after abrupt close.
        // Without this, a quick reconnect creates a duplicate "you" entry (user reported bug).
        let dup_keys: Vec<String> = s
            .clients
            .iter()
            .filter(|(_, rec)| rec.info.name == name && rec.addr.ip() == addr.ip())
            .map(|(k, _)| k.clone())
            .collect();
        for k in dup_keys {
            if k != client_id {
                info!(%k, %name, %addr, "removing stale duplicate for same host before insert");
                s.clients.remove(&k);
                if s.active_id.as_ref() == Some(&k) {
                    s.active_id = None;
                }
            }
        }
        // Also handle case where client provided an explicit id that already exists (reconnect with same id)
        // — then we will overwrite it below, but ensure stale port mapping is updated.
        let rec = ClientRecord {
            info: ClientInfo {
                id: client_id.clone(),
                name: name.clone(),
                ip: addr.ip().to_string(),
                state: ClientState::Connected,
                vu_db: -100.0,
                connected_at: format!("{}", humantime::format_rfc3339(SystemTime::now())),
            },
            addr,
        };
        s.clients.insert(client_id.clone(), rec);
    }

    // Ack
    let ack = ControlMessage::HelloAck {
        assigned_id: client_id.clone(),
    };
    info!(%client_id, "sending HelloAck");
    w.write_all((serde_json::to_string(&ack)? + "\n").as_bytes()).await?;
    w.flush().await?;
    info!(%client_id, "HelloAck sent");

    // Send initial list
    {
        let s = state.read().await;
        let (clients, active_id) = s.snapshot();
        let n = clients.len();
        let msg = ControlMessage::ClientList { clients, active_id };
        info!(%client_id, n, "sending initial ClientList");
        w.write_all((serde_json::to_string(&msg)? + "\n").as_bytes()).await?;
        w.flush().await?;
        info!(%client_id, "initial ClientList sent");
    }
    // Broadcast new list to everyone
    info!(%client_id, "broadcasting list");
    broadcast_list(&state, &bcast_tx).await;
    info!(%client_id, "broadcast done");

    // Spawn writer for broadcasts
    let mut w2 = w;
    let cid_clone = client_id.clone();
    let mut bcast_rx2 = bcast_tx.subscribe();
    let writer_handle = tokio::spawn(async move {
        while let Ok(msg) = bcast_rx2.recv().await {
            let s = match serde_json::to_string(&msg) {
                Ok(v) => v + "\n",
                Err(_) => continue,
            };
            if w2.write_all(s.as_bytes()).await.is_err() {
                break;
            }
        }
    });

    // Reader loop
    loop {
        line.clear();
        tokio::select! {
            n = reader.read_line(&mut line) => {
                let n = n?;
                if n == 0 { break; }
                let msg: Result<ControlMessage, _> = serde_json::from_str(line.trim());
                match msg {
                    Ok(ControlMessage::RequestActive { client_id: req }) => {
                        // Avoid deadlock: do not hold write lock across broadcast_list (which needs read lock)
                        let (do_broadcast, active_changed) = {
                            let mut s = state.write().await;
                            if req.is_empty() {
                                info!(%cid_clone, "release requested");
                                if s.active_id.is_some() {
                                    let prev = s.active_id.clone();
                                    s.active_id = None;
                                    for rec in s.clients.values_mut() {
                                        if rec.info.state == ClientState::Active {
                                            rec.info.state = ClientState::Connected;
                                        }
                                    }
                                    info!(prev=?prev, "active cleared");
                                    (true, Some(ControlMessage::ActiveChanged { active_id: None, active_name: None }))
                                } else {
                                    info!("release requested but no active holder");
                                    (false, None)
                                }
                            } else if s.clients.contains_key(&req) {
                                info!(%cid_clone, req=%req, "take requested");
                                s.active_id = Some(req.clone());
                                let active_clone = s.active_id.clone();
                                for (id, rec) in s.clients.iter_mut() {
                                    rec.info.state = if Some(id) == active_clone.as_ref() { ClientState::Active } else { ClientState::Connected };
                                }
                                let active_name = s.clients.get(&req).map(|r| r.info.name.clone());
                                info!(active=?active_clone, name=?active_name, "active set");
                                (true, Some(ControlMessage::ActiveChanged { active_id: Some(req.clone()), active_name }))
                            } else {
                                warn!(%cid_clone, req=%req, "take requested for unknown client");
                                (false, None)
                            }
                        };
                        if let Some(msg) = active_changed {
                            let _ = bcast_tx.send(msg);
                        }
                        if do_broadcast {
                            broadcast_list(&state, &bcast_tx).await;
                        }
                    }
                    Ok(ControlMessage::VuUpdate { client_id: vu_id, vu_db }) => {
                        {
                            let mut s = state.write().await;
                            if let Some(rec) = s.clients.get_mut(&vu_id) {
                                rec.info.vu_db = vu_db;
                            }
                        }
                        // Broadcast VU so all clients see live meters
                        let _ = bcast_tx.send(ControlMessage::VuUpdate {
                            client_id: vu_id,
                            vu_db,
                        });
                    }
                    Ok(ControlMessage::Mute { client_id: mid, muted }) => {
                        let need_broadcast = {
                            let mut s = state.write().await;
                            let mut need = false;
                            if let Some(rec) = s.clients.get_mut(&mid) {
                                rec.info.state = if muted { ClientState::Muted } else { ClientState::Connected };
                                if muted && s.active_id.as_ref() == Some(&mid) {
                                    s.active_id = None;
                                    let _ = bcast_tx.send(ControlMessage::ActiveChanged { active_id: None, active_name: None });
                                }
                                need = true;
                            }
                            need
                        };
                        if need_broadcast {
                            broadcast_list(&state, &bcast_tx).await;
                        }
                    }
                    Ok(ControlMessage::Kick { client_id: kid }) => {
                        {
                            let mut s = state.write().await;
                            s.clients.remove(&kid);
                            if s.active_id.as_ref() == Some(&kid) {
                                s.active_id = None;
                                let _ = bcast_tx.send(ControlMessage::ActiveChanged { active_id: None, active_name: None });
                            }
                        }
                        broadcast_list(&state, &bcast_tx).await;
                    }
                    Ok(ControlMessage::Ping) => {
                        let _ = bcast_tx.send(ControlMessage::Pong);
                        // Also rebroadcast current list — helps clients that missed initial ClientList after reconnect
                        broadcast_list(&state, &bcast_tx).await;
                    }
                    Ok(_) => {}
                    Err(e) => warn!(%cid_clone, error=%e, line=%line.trim(), "bad control msg"),
                }
            }
            _ = bcast_rx.recv() => {
                // consumed in writer task; keep loop alive
            }
        }
    }

    writer_handle.abort();
    {
        let mut s = state.write().await;
        s.clients.remove(&client_id);
        if s.active_id.as_ref() == Some(&client_id) {
            s.active_id = None;
            let _ = bcast_tx.send(ControlMessage::ActiveChanged { active_id: None, active_name: None });
        }
    }
    broadcast_list(&state, &bcast_tx).await;
    info!(%client_id, "disconnected");
    Ok(())
}

async fn broadcast_list(state: &Arc<RwLock<ServerState>>, tx: &broadcast::Sender<ControlMessage>) {
    let (clients, active_id) = state.read().await.snapshot();
    let _ = tx.send(ControlMessage::ClientList { clients, active_id });
}
