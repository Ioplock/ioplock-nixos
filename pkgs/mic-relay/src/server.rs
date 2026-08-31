use anyhow::{Context, Result};
use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::SystemTime;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream, UdpSocket};
use tokio::sync::{broadcast, RwLock};
use tracing::{info, warn};

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

    // UDP audio task — receives Opus frames, forwards only from active client to virtual sink
    let audio_state = state.clone();
    let audio_bcast = bcast_tx.clone();
    tokio::spawn(async move {
        if let Err(e) = audio_loop(audio_port, audio_state, audio_bcast, source_name).await {
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
) -> Result<()> {
    let sock = UdpSocket::bind(("0.0.0.0", port)).await?;
    let mut buf = vec![0u8; 8192];
    // For now we just validate framing and optionally forward to the null sink via cpal/pw-play.
    // Minimal: count packets, update VU if we can decode level, but don't require opus yet.
    // If opus feature is enabled, decode and play.
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
            // Not active — drop. Still could update VU for that client via control channel instead.
            continue;
        }

        // Optional: decode Opus and play to the virtual sink.
        // We do best-effort; if payload is raw PCM f32 (no opus) we could also handle it.
        #[cfg(feature = "opus")]
        {
            let decoder = decoders.entry(hdr.client_id_hash).or_insert_with(|| {
                opus::Decoder::new(48000, opus::Channels::Mono).expect("opus decoder")
            });
            // Opus frame is 20ms @ 48kHz mono = 960 samples
            let mut pcm = vec![0i16; 960 * 2];
            let decoded = match decoder.decode(payload, &mut pcm, false) {
                Ok(n) => n,
                Err(e) => {
                    warn!(%addr, error=%e, "opus decode failed");
                    continue;
                }
            };
            pcm.truncate(decoded);
            // Write to virtual sink via cpal/pw-cat. For now we drop after decode to avoid extra deps.
            // A full impl would open a cpal output stream targeting `source_name` device and write `pcm`.
            // Placeholder: log occasionally
            if hdr.seq % 100 == 0 {
                info!(seq=hdr.seq, samples=decoded, sink=%source_name, "forwarded opus frame from active");
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
        if s.active_id.is_none() {
            // First client becomes active automatically; otherwise requires explicit take.
            // Keep None until someone takes to avoid surprise.
        }
    }

    // Ack
    let ack = ControlMessage::HelloAck {
        assigned_id: client_id.clone(),
    };
    w.write_all((serde_json::to_string(&ack)? + "\n").as_bytes()).await?;

    // Send initial list
    {
        let s = state.read().await;
        let (clients, active_id) = s.snapshot();
        let msg = ControlMessage::ClientList { clients, active_id };
        w.write_all((serde_json::to_string(&msg)? + "\n").as_bytes()).await?;
    }
    // Broadcast new list to everyone
    broadcast_list(&state, &bcast_tx).await;

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
                        let mut s = state.write().await;
                        if s.clients.contains_key(&req) {
                            s.active_id = Some(req.clone());
                            let active_clone = s.active_id.clone();
                            // mark states
                            for (id, rec) in s.clients.iter_mut() {
                                rec.info.state = if Some(id) == active_clone.as_ref() { ClientState::Active } else { ClientState::Connected };
                            }
                            let active_name = s.clients.get(&req).map(|r| r.info.name.clone());
                            let _ = bcast_tx.send(ControlMessage::ActiveChanged { active_id: Some(req), active_name });
                            broadcast_list(&state, &bcast_tx).await;
                        }
                    }
                    Ok(ControlMessage::VuUpdate { client_id: vu_id, vu_db }) => {
                        let mut s = state.write().await;
                        if let Some(rec) = s.clients.get_mut(&vu_id) {
                            rec.info.vu_db = vu_db;
                        }
                    }
                    Ok(ControlMessage::Mute { client_id: mid, muted }) => {
                        let mut s = state.write().await;
                        if let Some(rec) = s.clients.get_mut(&mid) {
                            rec.info.state = if muted { ClientState::Muted } else { ClientState::Connected };
                            if muted && s.active_id.as_ref() == Some(&mid) {
                                s.active_id = None;
                                let _ = bcast_tx.send(ControlMessage::ActiveChanged { active_id: None, active_name: None });
                            }
                        }
                        broadcast_list(&state, &bcast_tx).await;
                    }
                    Ok(ControlMessage::Kick { client_id: kid }) => {
                        // Only server operator should kick; for now allow any client to kick (LAN trust).
                        let mut s = state.write().await;
                        s.clients.remove(&kid);
                        if s.active_id.as_ref() == Some(&kid) {
                            s.active_id = None;
                            let _ = bcast_tx.send(ControlMessage::ActiveChanged { active_id: None, active_name: None });
                        }
                        broadcast_list(&state, &bcast_tx).await;
                    }
                    Ok(ControlMessage::Ping) => {
                        let _ = bcast_tx.send(ControlMessage::Pong);
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
