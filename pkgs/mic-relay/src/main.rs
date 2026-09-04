#![allow(dead_code, unused_imports, unused_variables)]
#![cfg_attr(target_os = "windows", windows_subsystem = "windows")]

mod ctl;
mod mdns;
mod protocol;
mod server;

mod audio;

#[cfg(feature = "client")]
mod gui;
mod client;

use anyhow::Result;
use clap::{Parser, Subcommand};
use tracing_subscriber::EnvFilter;

#[derive(Parser, Debug)]
#[command(name = "mic-relay", version, about = "LAN mic passthrough — headless server on mimosa, GUI client elsewhere, mDNS discoverable")]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,

    /// Control port (TCP) — used for `server` and `ctl` and `client`
    #[arg(long, default_value_t = 50051)]
    port: u16,

    /// Audio port (UDP)
    #[arg(long, default_value_t = 50052)]
    audio_port: u16,
}

#[derive(Subcommand, Debug)]
enum Commands {
    /// Run headless server (mimosa) — creates virtual mic `MicRelay`, advertises via mDNS
    Server {
        #[arg(long, default_value = "MicRelay")]
        source_name: String,
        #[arg(long, default_value_t = 50051)]
        port: u16,
        #[arg(long, default_value_t = 50052)]
        audio_port: u16,
    },
    /// Run GUI client (default if no subcommand and `client` feature enabled)
    Client {
        #[arg(long)]
        server: Option<String>,
        #[arg(long)]
        name: Option<String>,
    },
    /// CLI control for headless server: status/list/kick/active/mute/connections
    Ctl {
        #[arg(long, default_value = "127.0.0.1:50051")]
        server: String,
        #[command(subcommand)]
        ctl: CtlCmd,
    },
}

#[derive(Subcommand, Debug)]
enum CtlCmd {
    /// Show server status and active client
    Status,
    /// List clients
    List {
        #[arg(long)]
        json: bool,
    },
    /// Show active or set active `mic-relay ctl --server 192.168.1.92:50051 active <id>`
    Active {
        id: Option<String>,
    },
    /// Kick a client
    Kick {
        id: String,
    },
    /// Mute/unmute a client
    Mute {
        id: String,
        #[arg(long)]
        on: bool,
        #[arg(long)]
        off: bool,
    },
    /// Alias for status connections count
    Connections,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env().add_directive("info".parse().unwrap()))
        .init();

    let cli = Cli::parse();

    match cli.command {
        Some(Commands::Server { source_name, port, audio_port }) => {
            server::run(port, audio_port, source_name).await
        }
        Some(Commands::Client { server, name }) => {
            let srv = server.unwrap_or_else(|| {
                // Try mDNS discover first, fallback to mimosa default
                let found = mdns::browse(1200);
                if let Some((_, addr, p)) = found.first() {
                    format!("{addr}:{p}")
                } else {
                    format!("192.168.1.92:{}", cli.port)
                }
            });
            client::run(srv, name).await
        }
        Some(Commands::Ctl { server, ctl }) => {
            let cmd = match ctl {
                CtlCmd::Status => ctl::CtlCommand::Status,
                CtlCmd::List { json } => ctl::CtlCommand::List { json },
                CtlCmd::Active { id } => ctl::CtlCommand::Active { id },
                CtlCmd::Kick { id } => ctl::CtlCommand::Kick { id },
                CtlCmd::Mute { id, on, off } => ctl::CtlCommand::Mute { id, on: on || !off },
                CtlCmd::Connections => ctl::CtlCommand::Connections,
            };
            ctl::run(server, cmd).await
        }
        None => {
            // Default: client GUI if available, else hint
            #[cfg(feature = "client")]
            {
                let found = mdns::browse(800);
                let srv = if let Some((_, addr, p)) = found.first() {
                    format!("{addr}:{p}")
                } else {
                    format!("192.168.1.92:{}", cli.port)
                };
                client::run(srv, None).await
            }
            #[cfg(not(feature = "client"))]
            {
                eprintln!("No subcommand and client feature disabled. Use `mic-relay server` or `mic-relay ctl status`");
                std::process::exit(1);
            }
        }
    }
}
