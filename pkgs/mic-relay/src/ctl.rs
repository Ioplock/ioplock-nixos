#![allow(dead_code, unused_imports)]
use anyhow::{Context, Result};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;

use crate::protocol::*;

pub async fn run(server: String, cmd: CtlCommand) -> Result<()> {
    let mut stream = TcpStream::connect(&server)
        .await
        .with_context(|| format!("connect {server}"))?;
    // We need a temporary hello to get a ClientList. Use ctl pseudo-client.
    let hello = Hello {
        client_id: "ctl".to_string(),
        name: "ctl".to_string(),
        version: env!("CARGO_PKG_VERSION").to_string(),
    };
    stream
        .write_all((serde_json::to_string(&hello)? + "\n").as_bytes())
        .await?;
    let (r, mut w) = stream.into_split();
    let mut reader = BufReader::new(r);
    let mut line = String::new();

    // drain HelloAck + initial ClientList
    reader.read_line(&mut line).await?;
    line.clear();
    reader.read_line(&mut line).await?;
    let initial: ControlMessage = serde_json::from_str(line.trim()).unwrap_or(ControlMessage::Error {
        message: "no initial".into(),
    });

    match cmd {
        CtlCommand::Status => {
            println!("server: {server}");
            match initial {
                ControlMessage::ClientList { clients, active_id } => {
                    println!("active: {}", active_id.as_deref().unwrap_or("none"));
                    println!("clients: {}", clients.len());
                    for c in &clients {
                        let star = if Some(&c.id) == active_id.as_ref() { "*" } else { " " };
                        println!("{star} {}  {}  {}  {}  vu={:.1}dB", c.id, c.name, c.ip, c.state, c.vu_db);
                    }
                }
                _ => println!("{initial:?}"),
            }
        }
        CtlCommand::List { json } => match initial {
            ControlMessage::ClientList { clients, active_id } => {
                if json {
                    println!(
                        "{}",
                        serde_json::to_string_pretty(&serde_json::json!({ "active_id": active_id, "clients": clients }))?
                    );
                } else {
                    for c in clients {
                        let star = if Some(&c.id) == active_id.as_ref() { "*" } else { " " };
                        println!("{star} {}  {}  {}  {}", c.id, c.name, c.ip, c.state);
                    }
                }
            }
            _ => println!("{initial:?}"),
        },
        CtlCommand::Active { id } => {
            if let Some(id) = id {
                let msg = ControlMessage::RequestActive { client_id: id };
                w.write_all((serde_json::to_string(&msg)? + "\n").as_bytes()).await?;
                println!("requested active");
            } else {
                match initial {
                    ControlMessage::ClientList { active_id, .. } => {
                        println!("{}", active_id.unwrap_or_else(|| "none".into()))
                    }
                    _ => {}
                }
            }
            // wait one broadcast
            line.clear();
            reader.read_line(&mut line).await?;
            println!("update: {}", line.trim());
        }
        CtlCommand::Kick { id } => {
            let msg = ControlMessage::Kick { client_id: id };
            w.write_all((serde_json::to_string(&msg)? + "\n").as_bytes()).await?;
            println!("kicked");
        }
        CtlCommand::Mute { id, on } => {
            let msg = ControlMessage::Mute {
                client_id: id,
                muted: on,
            };
            w.write_all((serde_json::to_string(&msg)? + "\n").as_bytes()).await?;
            println!("mute set");
        }
        CtlCommand::Connections => {
            // alias for status
            match initial {
                ControlMessage::ClientList { clients, active_id } => {
                    println!("connections: {}", clients.len());
                    for c in clients {
                        println!("{} {} {} {}", c.id, c.name, c.ip, if Some(&c.id)==active_id.as_ref() {"ACTIVE"} else {""});
                    }
                }
                _ => {}
            }
        }
    }
    Ok(())
}

#[derive(Debug)]
pub enum CtlCommand {
    Status,
    List { json: bool },
    Active { id: Option<String> },
    Kick { id: String },
    Mute { id: String, on: bool },
    Connections,
}
