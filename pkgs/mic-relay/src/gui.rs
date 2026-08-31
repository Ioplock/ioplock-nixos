#![cfg(feature = "client")]
#![allow(dead_code, unused_imports, unused_variables, unused_mut)]

use std::sync::{Arc, Mutex};

use crate::protocol::*;
use anyhow::Result;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tracing::{info, warn};

// Lucide helpers — lucide font is added as fallback to Proportional, so we don't need Name("lucide").
// Using Name("lucide") directly panics on first frame before set_fonts takes effect.
#[cfg(feature = "client")]
fn lucide(icon: lucide_icons::Icon) -> String {
    char::from(icon).to_string()
}
#[cfg(feature = "client")]
fn lucide_rich(icon: lucide_icons::Icon, size: f32) -> egui::RichText {
    egui::RichText::new(char::from(icon).to_string()).size(size)
}

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

// Shared sender for UI -> network
type ControlTx = mpsc::UnboundedSender<ControlMessage>;

pub fn run_gui(server: String, name: String) -> Result<()> {
    let opts = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([560.0, 420.0])
            .with_min_inner_size([480.0, 360.0])
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
    let control_tx_holder: Arc<Mutex<Option<ControlTx>>> = Arc::new(Mutex::new(None));

    // Spawn tokio runtime for network in background thread
    let bg_state = app_state.clone();
    let bg_tx_holder = control_tx_holder.clone();
    std::thread::spawn(move || {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .unwrap();
        rt.block_on(async move {
            if let Err(e) = network_task(bg_state.clone(), bg_tx_holder.clone()).await {
                let mut s = bg_state.lock().unwrap();
                s.status = format!("error: {e}");
            }
        });
    });

    let mut fonts_initialized = false;

    eframe::run_simple_native("Mic Relay", opts, move |ctx, _frame| {
        // Install Lucide font as fallback to Proportional/Monospace once
        if !fonts_initialized {
            let mut fonts = egui::FontDefinitions::default();
            fonts.font_data.insert(
                "lucide".to_owned(),
                egui::FontData::from_static(lucide_icons::LUCIDE_FONT_BYTES),
            );
            // Add as fallback so any lucide char falls back to lucide font
            if let Some(proportional) = fonts.families.get_mut(&egui::FontFamily::Proportional) {
                proportional.push("lucide".to_owned());
            }
            if let Some(monospace) = fonts.families.get_mut(&egui::FontFamily::Monospace) {
                monospace.push("lucide".to_owned());
            }
            ctx.set_fonts(fonts);
            fonts_initialized = true;
        }

        ctx.request_repaint_after(std::time::Duration::from_millis(80));
        let mut st = app_state.lock().unwrap().clone();
        let tx_opt = control_tx_holder.lock().unwrap().clone();
        egui::CentralPanel::default().show(ctx, |ui| {
            // Header
            ui.horizontal(|ui| {
                ui.label(lucide_rich(lucide_icons::Icon::Mic, 18.0));
                ui.heading("Mic Relay");
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    let status_color = if st.status.contains("connected") {
                        egui::Color32::from_rgb(120, 220, 120)
                    } else if st.status.contains("connecting") {
                        egui::Color32::YELLOW
                    } else {
                        egui::Color32::GRAY
                    };
                    ui.colored_label(status_color, &st.status);
                    ui.label(lucide_rich(lucide_icons::Icon::Radio, 14.0));
                });
            });
            ui.label(
                egui::RichText::new("Mimosa discoverable via mDNS · headless server")
                    .small()
                    .weak(),
            );
            ui.separator();

            // Server row — use Grid to avoid overflow
            egui::Grid::new("server_grid")
                .num_columns(4)
                .spacing([6.0, 4.0])
                .show(ui, |ui| {
                    ui.label(egui::RichText::new("Server:").weak());
                    // TextEdit fills remaining width via available_width
                    let avail = ui.available_width() - 160.0; // reserve for buttons
                    let edit_w = avail.max(120.0);
                    ui.add_sized(
                        [edit_w, 20.0],
                        egui::TextEdit::singleline(&mut st.server_input)
                            .hint_text("192.168.1.92:50051"),
                    );
                    if ui
                        .add_sized([70.0, 20.0], egui::Button::new("Connect"))
                        .clicked()
                    {
                        st.server = st.server_input.clone();
                        st.status = format!("reconnect to {}", st.server);
                    }
                    if ui
                        .add_sized([70.0, 20.0], egui::Button::new("Discover"))
                        .clicked()
                    {
                        let found = crate::mdns::browse(1200);
                        if let Some((name, addr, port)) = found.first() {
                            let s = format!("{addr}:{port}");
                            st.server = s.clone();
                            st.server_input = s;
                            st.status = format!("discovered {name}");
                        } else {
                            st.status =
                                "no mDNS peers — enter 192.168.1.92:50051 manually".to_string();
                        }
                    }
                    ui.end_row();
                });

            ui.add_space(6.0);
            // You card — compact, no overflow
            egui::Frame::group(ui.style())
                .inner_margin(egui::Margin::symmetric(8.0, 6.0))
                .show(ui, |ui| {
                    ui.set_width(ui.available_width());
                    ui.horizontal(|ui| {
                        ui.label(lucide_rich(lucide_icons::Icon::UserRound, 14.0));
                        ui.label(format!(
                            "You: {}",
                            st.name.clone()
                        ));
                        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                            let id_short = st
                                .my_id
                                .as_deref()
                                .map(|s| format!("{}…", &s[..8.min(s.len())]))
                                .unwrap_or_else(|| "unassigned".into());
                            ui.weak(format!("({id_short})"));
                        });
                    });
                    ui.add_space(4.0);
                    // VU row
                    ui.horizontal(|ui| {
                        ui.label(lucide_rich(lucide_icons::Icon::Volume2, 14.0));
                        let vu = st.vu_db;
                        let pct = ((vu + 60.0) / 60.0).clamp(0.0, 1.0);
                        let text = if vu <= -90.0 {
                            "VU — silent".to_string()
                        } else {
                            format!("VU {vu:.0} dB")
                        };
                        // ProgressBar fills available width
                        let bar_w = ui.available_width() - 150.0;
                        ui.add(
                            egui::ProgressBar::new(pct)
                                .text(text)
                                .desired_width(bar_w.max(80.0)),
                        );
                        // Take/Release stacked
                        let is_active = st
                            .active_id
                            .as_ref()
                            .zip(st.my_id.as_ref())
                            .map(|(a, m)| a == m)
                            .unwrap_or(false);
                        if is_active {
                            if ui
                                .button(format!(
                                    "{} Release",
                                    lucide(lucide_icons::Icon::MicOff)
                                ))
                                .clicked()
                            {
                                if let Some(tx) = tx_opt.clone() {
                                    let _ = tx.send(ControlMessage::RequestActive {
                                        client_id: "".to_string(),
                                    });
                                }
                            }
                        } else if ui
                            .button(format!(
                                "{} Take Mic",
                                lucide(lucide_icons::Icon::Mic)
                            ))
                            .clicked()
                        {
                            if let Some(id) = st.my_id.clone() {
                                if let Some(tx) = tx_opt.clone() {
                                    let _ = tx.send(ControlMessage::RequestActive {
                                        client_id: id,
                                    });
                                }
                            }
                        }
                    });
                    // VU explanation
                    ui.weak(
                        egui::RichText::new("VU = mic level (dBFS); Take Mic makes you Active (exclusive)")
                            .small(),
                    );
                });

            ui.add_space(6.0);
            // Active banner with lucide
            let active_name = st
                .active_id
                .as_ref()
                .and_then(|aid| {
                    st.clients
                        .iter()
                        .find(|c| &c.id == aid)
                        .map(|c| c.name.clone())
                })
                .unwrap_or_else(|| "— none —".to_string());
            egui::Frame::group(ui.style())
                .fill(if st.active_id.is_some() {
                    egui::Color32::from_rgba_unmultiplied(80, 140, 80, 30)
                } else {
                    egui::Color32::from_rgba_unmultiplied(40, 40, 40, 20)
                })
                .inner_margin(egui::Margin::symmetric(8.0, 4.0))
                .show(ui, |ui| {
                    ui.set_width(ui.available_width());
                    ui.horizontal(|ui| {
                        ui.label(lucide_rich(lucide_icons::Icon::Activity, 16.0));
                        let txt = format!("Active: {}", active_name);
                        ui.colored_label(
                            if st.active_id.is_some() {
                                egui::Color32::from_rgb(160, 255, 160)
                            } else {
                                egui::Color32::GRAY
                            },
                            egui::RichText::new(txt).strong(),
                        );
                    });
                });

            // Clients list — handle overflow: use Grid-like rows with available_width
            ui.add_space(4.0);
            ui.label(
                egui::RichText::new(format!("Clients ({})", st.clients.len()))
                    .weak()
                    .small(),
            );
            egui::ScrollArea::vertical()
                .max_height(160.0)
                .show(ui, |ui| {
                    if st.clients.is_empty() {
                        ui.weak("No clients yet — waiting for server ClientList…");
                    } else {
                        for c in &st.clients {
                            let is_active = Some(&c.id) == st.active_id.as_ref();
                            let is_me = Some(&c.id) == st.my_id.as_ref();
                            let fill = if is_active {
                                egui::Color32::from_rgba_unmultiplied(70, 110, 70, 40)
                            } else {
                                egui::Color32::TRANSPARENT
                            };
                            egui::Frame::group(ui.style())
                                .fill(fill)
                                .inner_margin(egui::Margin::symmetric(6.0, 4.0))
                                .show(ui, |ui| {
                                    ui.set_width(ui.available_width());
                                    // Row 1: icon + name (with truncation) + right side ip/state
                                    ui.horizontal(|ui| {
                                        // State icon via lucide
                                        let (icon, col) = match c.state {
                                            ClientState::Active => (
                                                lucide_icons::Icon::Mic,
                                                egui::Color32::from_rgb(120, 220, 120),
                                            ),
                                            ClientState::Muted => (
                                                lucide_icons::Icon::MicOff,
                                                egui::Color32::GRAY,
                                            ),
                                            ClientState::Connected => (
                                                lucide_icons::Icon::Circle,
                                                egui::Color32::from_rgb(130, 170, 255),
                                            ),
                                            ClientState::Idle => (
                                                lucide_icons::Icon::CircleDashed,
                                                egui::Color32::GRAY,
                                            ),
                                        };
                                        ui.colored_label(
                                            col,
                                            egui::RichText::new(char::from(icon).to_string()).size(14.0),
                                        );
                                        // Name with truncation
                                        let name_txt = if is_me {
                                            format!("{} (you)", c.name)
                                        } else {
                                            c.name.clone()
                                        };
                                        ui.label(
                                            egui::RichText::new(name_txt)
                                                .strong()
                                                .size(13.0),
                                        );
                                        // Right side — use remaining width, align right, elide IP
                                        ui.with_layout(
                                            egui::Layout::right_to_left(egui::Align::Center),
                                            |ui| {
                                                // State label small
                                                ui.small(format!("{}", c.state));
                                                // IP with truncation: show full but weak, elide if needed
                                                let ip_display = if c.ip.len() > 15 {
                                                    format!("{}…", &c.ip[..12])
                                                } else {
                                                    c.ip.clone()
                                                };
                                                ui.weak(ip_display);
                                                ui.label(lucide_rich(
                                                    lucide_icons::Icon::MonitorSmartphone,
                                                    12.0,
                                                ));
                                            },
                                        );
                                    });
                                    // Row 2: VU bar
                                    let pct = ((c.vu_db + 60.0) / 60.0).clamp(0.0, 1.0);
                                    let vu_label = if c.vu_db <= -90.0 {
                                        "silent".into()
                                    } else {
                                        format!("{:.0} dB", c.vu_db)
                                    };
                                    ui.add(
                                        egui::ProgressBar::new(pct)
                                            .text(format!("{} {}", vu_label, if is_active { "●" } else { "" }))
                                            .desired_width(ui.available_width()),
                                    );
                                });
                        }
                    }
                });

            ui.add_space(6.0);
            ui.collapsing("Debug / Status", |ui| {
                ui.horizontal(|ui| {
                    ui.label(lucide_rich(lucide_icons::Icon::Settings, 12.0));
                    ui.small(format!("server: {}", st.server));
                });
                ui.small(format!("connected clients: {}", st.clients.len()));
                if let Some(id) = &st.active_id {
                    ui.small(format!("active_id: {id}"));
                } else {
                    ui.small("active_id: none");
                }
                if let Some(id) = &st.my_id {
                    ui.small(format!("my_id: {id}"));
                }
                ui.small(format!("vu: {:.1} dB", st.vu_db));
            });
        });
        // write back server_input changes
        let mut g = app_state.lock().unwrap();
        g.server_input = st.server_input;
    })
    .map_err(|e| anyhow::anyhow!("{e}"))?;
    Ok(())
}

async fn network_task(
    state: Arc<Mutex<AppState>>,
    tx_holder: Arc<Mutex<Option<ControlTx>>>,
) -> Result<()> {
    let (server, name) = {
        let s = state.lock().unwrap();
        (s.server.clone(), s.name.clone())
    };
    let stream = TcpStream::connect(&server).await?;
    {
        let mut s = state.lock().unwrap();
        s.status = format!("connected to {server}");
    }
    let hello = Hello {
        client_id: "".to_string(),
        name: name.clone(),
        version: env!("CARGO_PKG_VERSION").to_string(),
    };
    let (r, mut w) = stream.into_split();
    // channel for UI -> network
    let (tx, mut rx) = mpsc::unbounded_channel::<ControlMessage>();
    *tx_holder.lock().unwrap() = Some(tx.clone());
    w.write_all((serde_json::to_string(&hello)? + "\n").as_bytes())
        .await?;
    let mut reader = BufReader::new(r);
    let mut line = String::new();

    // HelloAck
    reader.read_line(&mut line).await?;
    let ack: ControlMessage =
        serde_json::from_str(line.trim()).unwrap_or(ControlMessage::Error { message: "bad ack".into() });
    if let ControlMessage::HelloAck { assigned_id } = ack {
        state.lock().unwrap().my_id = Some(assigned_id);
    }
    line.clear();

    // VU sender — now via control channel
    let vu_state = state.clone();
    let vu_tx = tx.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_millis(300));
        let mut last_vu: f32 = -100.0;
        loop {
            interval.tick().await;
            let (my_id, vu_db) = {
                let s = vu_state.lock().unwrap();
                (s.my_id.clone(), s.vu_db)
            };
            if let Some(id) = my_id {
                // Smooth synthetic VU for now (real cpal later)
                // Add small jitter + smoothing to avoid jumping
                let jitter = (rand_simple() % 7) as f32 - 3.0;
                let target = -24.0 + jitter; // centered around -24 dB
                // Smooth towards target
                let smoothed = last_vu * 0.7 + target * 0.3;
                last_vu = smoothed;
                // Update local state
                vu_state.lock().unwrap().vu_db = smoothed;
                let _ = vu_tx.send(ControlMessage::VuUpdate {
                    client_id: id,
                    vu_db: smoothed,
                });
            }
        }
    });

    // Writer task: forwards channel messages to TCP
    let mut w2 = w;
    tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            if let Ok(s) = serde_json::to_string(&msg) {
                let _ = w2.write_all((s + "\n").as_bytes()).await;
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
                // also update own VU if echo
                if s.my_id.as_ref() == Some(&client_id) {
                    s.vu_db = vu_db;
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
