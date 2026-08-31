#![allow(dead_code, unused_imports)]
use anyhow::Result;
use tracing::info;

#[cfg(feature = "client")]
pub async fn run(server: String, name: Option<String>) -> Result<()> {
    let name = name.unwrap_or_else(|| {
        hostname::get()
            .ok()
            .and_then(|h| h.into_string().ok())
            .unwrap_or_else(|| "unknown".to_string())
    });
    info!(server=%server, name=%name, "starting client GUI");
    // GUI runs on main thread; we block here and spawn network tasks inside eframe.
    crate::gui::run_gui(server, name)
}

#[cfg(not(feature = "client"))]
pub async fn run(_server: String, _name: Option<String>) -> Result<()> {
    anyhow::bail!("client feature not enabled in this build (use myMicRelay, not myMicRelayServer)");
}
