#![allow(dead_code, unused_imports)]
use anyhow::Result;

pub struct MdnsPublisher {
    pub service_name: String,
    _svc: mdns_sd::ServiceDaemon,
}

impl MdnsPublisher {
    pub fn new(source_name: &str, port: u16) -> Result<Self> {
        let daemon = mdns_sd::ServiceDaemon::new()?;
        let host = hostname::get()
            .ok()
            .and_then(|h| h.into_string().ok())
            .unwrap_or_else(|| "mimosa".to_string());
        let service_name = format!("{source_name}-{host}");
        let service_type = crate::protocol::MDNS_SERVICE_TYPE;
        let hostname = format!("{host}.local.");
        let props: Vec<(&str, &str)> = vec![("version", env!("CARGO_PKG_VERSION")), ("source", source_name)];
        let svc_info = mdns_sd::ServiceInfo::new(
            service_type,
            &service_name,
            &hostname,
            "",
            port,
            &props[..],
        )?
        .enable_addr_auto();
        daemon.register(svc_info)?;
        Ok(Self {
            service_name,
            _svc: daemon,
        })
    }
}

pub fn browse(timeout_ms: u64) -> Vec<(String, String, u16)> {
    let daemon = match mdns_sd::ServiceDaemon::new() {
        Ok(d) => d,
        Err(_) => return vec![],
    };
    let receiver = match daemon.browse(crate::protocol::MDNS_SERVICE_TYPE) {
        Ok(r) => r,
        Err(_) => return vec![],
    };
    let mut out = Vec::new();
    let deadline = std::time::Instant::now() + std::time::Duration::from_millis(timeout_ms);
    while std::time::Instant::now() < deadline {
        let timeout = deadline.saturating_duration_since(std::time::Instant::now());
        match receiver.recv_timeout(timeout) {
            Ok(mdns_sd::ServiceEvent::ServiceResolved(info)) => {
                let name = info.get_fullname().to_string();
                let addr = info.get_addresses().iter().next().map(|a| a.to_string()).unwrap_or_default();
                let port = info.get_port();
                out.push((name, addr, port));
            }
            Ok(_) => {}
            Err(_) => break,
        }
    }
    out
}
