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

    // Playback to virtual sink (MicRelay) — keep stream alive
    let playback_prod: std::sync::Arc<std::sync::Mutex<rtrb::Producer<f32>>> = {
        match audio::spawn_output_playback(&source_name) {
            Ok((stream, prod)) => {
                info!(source=%source_name, "playback stream to virtual sink ready");
                // Keep stream alive for the lifetime of the server
                std::mem::forget(stream);
                std::sync::Arc::new(std::sync::Mutex::new(prod))
            }
            Err(e) => {
                warn!(error=%e, source=%source_name, "playback failed — audio will be decoded but not played");
                let (prod, _cons) = rtrb::RingBuffer::new(1024);
                std::sync::Arc::new(std::sync::Mutex::new(prod))
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
    // Create a null sink whose monitor is usable as a mic.
    // `pactl load-module module-null-sink sink_name=... sink_properties=device.description=...`
    // The monitor source will be `<sink_name>.monitor` — games select that.
    // We try pactl first, then pw-cli fallback.
    let sink = source_name;
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
            return true;
        }
        Ok(o) => warn!(sink, stderr=%String::from_utf8_lossy(&o.stderr), "pactl null-sink failed"),
        Err(e) => warn!(sink, error=%e, "pactl not found"),
    }
    // fallback: pw-cli (pipewire)
    let pw = tokio::process::Command::new("pw-cli")
        .args(["create", "node", "adapter", &format!("{{ factory.name=support.null-audio-sink node.name={sink} media.class=Audio/Sink }}")])
        .output()
        .await;
    match pw {
        Ok(o) if o.status.success() => {
            info!(sink, "created via pw-cli");
            true
        }
        Ok(o) => {
            warn!(sink, stderr=%String::from_utf8_lossy(&o.stderr), "pw-cli failed");
            false
        }
        Err(e) => {
            warn!(sink, error=%e, "pw-cli not found");
            false
        }
    }
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
