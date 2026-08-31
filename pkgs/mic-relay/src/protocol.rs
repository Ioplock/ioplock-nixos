use serde::{Deserialize, Serialize};

pub const DEFAULT_CONTROL_PORT: u16 = 50051;
pub const DEFAULT_AUDIO_PORT: u16 = 50052;
pub const MDNS_SERVICE_TYPE: &str = "_mic-relay._tcp.local.";
pub const MDNS_SERVICE_NAME: &str = "mimosa-mic-relay";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Hello {
    pub client_id: String,
    pub name: String,
    pub version: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClientInfo {
    pub id: String,
    pub name: String,
    pub ip: String,
    pub state: ClientState,
    pub vu_db: f32,
    pub connected_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ClientState {
    Connected,
    Active,
    Idle,
    Muted,
}

impl std::fmt::Display for ClientState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Connected => write!(f, "connected"),
            Self::Active => write!(f, "active"),
            Self::Idle => write!(f, "idle"),
            Self::Muted => write!(f, "muted"),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ControlMessage {
    Hello(Hello),
    HelloAck { assigned_id: String },
    ClientList { clients: Vec<ClientInfo>, active_id: Option<String> },
    RequestActive { client_id: String },
    ActiveChanged { active_id: Option<String>, active_name: Option<String> },
    VuUpdate { client_id: String, vu_db: f32 },
    Mute { client_id: String, muted: bool },
    Kick { client_id: String },
    Status { active_id: Option<String>, source_ok: bool, uptime_secs: u64 },
    Error { message: String },
    Ping,
    Pong,
}

#[derive(Debug, Clone)]
pub struct AudioHeader {
    pub seq: u32,
    pub timestamp_ms: u32,
    pub client_id_hash: u32,
}

impl AudioHeader {
    pub const SIZE: usize = 12;
    pub fn encode(&self) -> [u8; Self::SIZE] {
        let mut b = [0u8; Self::SIZE];
        b[0..4].copy_from_slice(&self.seq.to_be_bytes());
        b[4..8].copy_from_slice(&self.timestamp_ms.to_be_bytes());
        b[8..12].copy_from_slice(&self.client_id_hash.to_be_bytes());
        b
    }
    pub fn decode(b: &[u8]) -> Option<Self> {
        if b.len() < Self::SIZE {
            return None;
        }
        Some(Self {
            seq: u32::from_be_bytes([b[0], b[1], b[2], b[3]]),
            timestamp_ms: u32::from_be_bytes([b[4], b[5], b[6], b[7]]),
            client_id_hash: u32::from_be_bytes([b[8], b[9], b[10], b[11]]),
        })
    }
}

pub fn hash_client_id(s: &str) -> u32 {
    let mut h: u32 = 5381;
    for b in s.bytes() {
        h = h.wrapping_mul(33).wrapping_add(b as u32);
    }
    h
}
