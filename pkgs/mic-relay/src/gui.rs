#![cfg(feature = "client")]

use std::sync::{Arc, Mutex};

use crate::protocol::*;
use anyhow::Result;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;
use tracing::{info, warn};

#[derive(Clone)]
struct AppState {
    server: String,
    name: String,
    clients: Vec<ClientInfo>,
    active_id: Option<String>,
    my_id: Option<String>,
    status: String,
    vu_db: f32,
    server_input: String,
}

pub fn run_gui(server: String, name: String) -> Result<()> {
    let opts = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([420.0, 620.0])
            .with_title("Mic Relay"),
        ..Default::default()
    };

    let app_state = Arc::new(Mutex::new(AppState {
        server_input: server.clone(),
        server: server.clone(),
        name: name.clone(),
        clients: vec![],
        active_id: None,
        my_id: None,
        status: format!("connecting to {server}..."),
        vu_db: -100.0,
    }));

    // Spawn tokio runtime for network in background thread
    let bg_state = app_state.clone();
    std::thread::spawn(move || {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .unwrap();
        rt.block_on(async move {
            if let Err(e) = network_task(bg_state.clone()).await {
                let mut s = bg_state.lock().unwrap();
                s.status = format!("error: {e}");
            }
        });
    });

    eframe::run_simple_native("Mic Relay", opts, move |ctx, _frame| {
        ctx.request_repaint_after(std::time::Duration::from_millis(50));
        let mut st = app_state.lock().unwrap().clone();
        egui::CentralPanel::default().show(ctx, |ui| {
            ui.heading("Mic Relay");
            ui.label(format!("Mimosa discoverable via mDNS  ·  {}", st.status));
            ui.separator();

            ui.horizontal(|ui| {
                ui.label("Server:");
                ui.text_edit_singleline(&mut st.server_input);
                if ui.button("Connect").clicked() {
                    st.server = st.server_input.clone();
                    st.status = format!("reconnect to {}", st.server);
                }
                if ui.button("Discover").clicked() {
                    let found = crate::mdns::browse(1500);
                    if let Some((name, addr, port)) = found.first() {
                        let s = format!("{addr}:{port}");
                        st.server = s.clone();
                        st.server_input = s;
                        st.status = format!("discovered {name}");
                    } else {
                        st.status = "no mDNS peers found — enter 192.168.1.92:50051 manually".to_string();
                    }
                }
            });

            ui.separator();
            // You card
            egui::Frame::group(ui.style()).show(ui, |ui| {
                ui.label(format!("You: {}  ({})", st.name, st.my_id.as_deref().unwrap_or("unassigned")));
                ui.horizontal(|ui| {
                    let vu = st.vu_db;
                    let pct = ((vu + 60.0) / 60.0).clamp(0.0, 1.0);
                    ui.add(egui::ProgressBar::new(pct).text(format!("VU {vu:.0} dB")));
                    if ui.button("Take Mic").clicked() {
                        if let Some(id) = st.my_id.clone() {
                            let srv = st.server.clone();
                            tokio::spawn(async move {
                                let _ = request_active(srv, id).await;
                            });
                        }
                    }
                    if ui.button("Release").clicked() {
                        // release by requesting none — server clears if you were active
                        // For now just log
                        info!("release requested");
                    }
                });
            });

            ui.separator();
            // Active banner
            let active_name = st
                .active_id
                .as_ref()
                .and_then(|aid| st.clients.iter().find(|c| &c.id == aid).map(|c| c.name.clone()))
                .unwrap_or_else(|| "— none —".to_string());
            let banner = format!("● Active: {}", active_name);
            ui.colored_label(
                if st.active_id.is_some() {
                    egui::Color32::from_rgb(120, 220, 120)
                } else {
                    egui::Color32::GRAY
                },
                banner,
            );
            ui.separator();

            egui::ScrollArea::vertical().show(ui, |ui| {
                for c in &st.clients {
                    let is_active = Some(&c.id) == st.active_id.as_ref();
                    let is_me = Some(&c.id) == st.my_id.as_ref();
                    egui::Frame::group(ui.style())
                        .fill(if is_active {
                            egui::Color32::from_rgba_unmultiplied(80, 120, 80, 40)
                        } else {
                            egui::Color32::TRANSPARENT
                        })
                        .show(ui, |ui| {
                            ui.horizontal(|ui| {
                                let dot = match c.state {
                                    ClientState::Active => "●",
                                    ClientState::Muted => "◐",
                                    ClientState::Connected => "○",
                                    ClientState::Idle => "◌",
                                };
                                ui.label(dot);
                                ui.label(format!("{} {}", c.name, if is_me { "(you)" } else { "" }));
                                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                                    ui.label(format!("{}  {}", c.ip, c.state));
                                });
                            });
                            let pct = ((c.vu_db + 60.0) / 60.0).clamp(0.0, 1.0);
                            ui.add(egui::ProgressBar::new(pct).show_percentage());
                        });
                }
                if st.clients.is_empty() {
                    ui.label("No clients yet — waiting for server ClientList…");
                }
            });

            ui.separator();
            ui.collapsing("Debug / Status", |ui| {
                ui.label(format!("server: {}", st.server));
                ui.label(format!("connected clients: {}", st.clients.len()));
                if let Some(id) = &st.active_id {
                    ui.label(format!("active_id: {id}"));
                }
            });
        });
        // write back server_input changes
        let mut g = app_state.lock().unwrap();
        g.server_input = st.server_input;
    })
    .map_err(|e| anyhow::anyhow!("{e}"))?;
    Ok(())
}

async fn request_active(server: String, id: String) -> Result<()> {
    let mut s = TcpStream::connect(&server).await?;
    let hello = Hello { client_id: id.clone(), name: "gui-take".into(), version: env!("CARGO_PKG_VERSION").into() };
    s.write_all((serde_json::to_string(&hello)? + "\n").as_bytes()).await?;
    let msg = ControlMessage::RequestActive { client_id: id };
    s.write_all((serde_json::to_string(&msg)? + "\n").as_bytes()).await?;
    Ok(())
}

async fn network_task(state: Arc<Mutex<AppState>>) -> Result<()> {
    let (server, name) = {
        let s = state.lock().unwrap();
        (s.server.clone(), s.name.clone())
    };
    let mut stream = TcpStream::connect(&server).await?;
    {
        let mut s = state.lock().unwrap();
        s.status = format!("connected to {server}");
    }
    let hello = Hello {
        client_id: "".to_string(),
        name: name.clone(),
        version: env!("CARGO_PKG_VERSION").to_string(),
    };
    stream
        .write_all((serde_json::to_string(&hello)? + "\n").as_bytes())
        .await?;
    let (r, _w) = stream.into_split();
    let mut reader = BufReader::new(r);
    let mut line = String::new();

    // HelloAck
    reader.read_line(&mut line).await?;
    let ack: ControlMessage = serde_json::from_str(line.trim()).unwrap_or(ControlMessage::Error { message: "bad ack".into() });
    if let ControlMessage::HelloAck { assigned_id } = ack {
        state.lock().unwrap().my_id = Some(assigned_id);
    }
    line.clear();
    // Start VU / audio sender in background (stub: synthetic VU)
    let vu_state = state.clone();
    let vu_server = server.clone();
    tokio::spawn(async move {
        // Real impl would capture cpal input, encode opus, send UDP to server audio port,
        // and send VuUpdate over TCP periodically.
        // Placeholder: send fake VU every 200ms
        let mut interval = tokio::time::interval(std::time::Duration::from_millis(200));
        loop {
            interval.tick().await;
            let my_id = vu_state.lock().unwrap().my_id.clone();
            if let Some(id) = my_id {
                let vu = -20.0 + (rand_simple() % 20) as f32 - 10.0;
                vu_state.lock().unwrap().vu_db = vu;
                // Ideally write to `w` but we don't have it here — would need shared writer.
                let _ = vu_server.clone();
                let _ = id;
            }
        }
    });

    loop {
        line.clear();
        let n = reader.read_line(&mut line).await?;
        if n == 0 {
            state.lock().unwrap().status = "disconnected".to_string();
            break;
        }
        let msg: Result<ControlMessage, _> = serde_json::from_str(line.trim());
        match msg {
            Ok(ControlMessage::ClientList { clients, active_id }) => {
                let mut s = state.lock().unwrap();
                s.clients = clients;
                s.active_id = active_id;
                s.status = "connected".to_string();
            }
            Ok(ControlMessage::ActiveChanged { active_id, .. }) => {
                state.lock().unwrap().active_id = active_id;
            }
            Ok(ControlMessage::VuUpdate { client_id, vu_db }) => {
                let mut s = state.lock().unwrap();
                if let Some(c) = s.clients.iter_mut().find(|c| c.id == client_id) {
                    c.vu_db = vu_db;
                }
            }
            Ok(m) => {
                info!(?m, "gui got msg");
            }
            Err(e) => warn!(error=%e, line=%line.trim(), "bad msg"),
        }
    }
    Ok(())
}

fn rand_simple() -> u32 {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    let mut h = DefaultHasher::new();
    std::time::SystemTime::now().hash(&mut h);
    h.finish() as u32
}
