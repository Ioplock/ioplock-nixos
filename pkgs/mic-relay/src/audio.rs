#![allow(dead_code, unused_imports)]
use anyhow::{Context, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::sync::{Arc, Mutex};
use tracing::{info, warn};

/// Compute VU in dBFS from f32 samples (-100 silent .. 0 loud)
pub fn rms_db(samples: &[f32]) -> f32 {
    if samples.is_empty() {
        return -100.0;
    }
    let sum_sq: f32 = samples.iter().map(|s| s * s).sum();
    let rms = (sum_sq / samples.len() as f32).sqrt();
    if rms <= 1e-6 {
        -100.0
    } else {
        (20.0 * rms.log10()).clamp(-100.0, 0.0)
    }
}

#[cfg(feature = "client")]
pub fn spawn_input_capture(
    hash_fn: impl Fn() -> u32 + Send + Sync + 'static,
    server_audio_addr: String,
    is_active_fn: impl Fn() -> bool + Send + Sync + 'static,
    vu_callback: impl Fn(f32) + Send + Sync + 'static,
) -> Result<cpal::Stream> {
    let host = cpal::default_host();
    let device = host
        .default_input_device()
        .context("no default input device")?;
    let dev_name = device.name().unwrap_or_else(|_| "unknown".into());
    info!(device=%dev_name, server=%server_audio_addr, "starting cpal capture");

    // Prefer 48k mono F32; fallback to device default
    let default_cfg = device.default_input_config().context("no default input config")?;
    let mut sample_format = default_cfg.sample_format();
    let mut config = default_cfg.config();
    if config.channels != 1 || config.sample_rate.0 != 48000 || sample_format != cpal::SampleFormat::F32 {
        if let Ok(supported) = device.supported_input_configs() {
            for cfg in supported {
                if cfg.channels() == 1
                    && cfg.min_sample_rate().0 <= 48000
                    && 48000 <= cfg.max_sample_rate().0
                    && cfg.sample_format() == cpal::SampleFormat::F32
                {
                    config = cfg.with_sample_rate(cpal::SampleRate(48000)).config();
                    sample_format = cfg.sample_format();
                    break;
                }
            }
        }
    }
    // Low-latency: request small buffer (20 ms = 960 frames @48k) instead of host default (often 100+ ms)
    config.buffer_size = cpal::BufferSize::Fixed(960);
    let sample_rate = config.sample_rate.0;
    let channels = config.channels as usize;

    let udp = std::net::UdpSocket::bind("0.0.0.0:0").context("bind udp for capture")?;
    udp.connect(&server_audio_addr)
        .with_context(|| format!("connect udp to {server_audio_addr}"))?;
    let _ = udp.set_nonblocking(true);

    let hash_fn = Arc::new(hash_fn);
    let encoder = Arc::new(Mutex::new(
        opus::Encoder::new(48000, opus::Channels::Mono, opus::Application::Voip)
            .context("opus encoder")?,
    ));
    {
        let mut enc = encoder.lock().unwrap();
        let _ = enc.set_bitrate(opus::Bitrate::Bits(32000));
        let _ = enc.set_vbr(true);
    }

    let frame_samples = 960usize;
    let pending = Arc::new(Mutex::new(Vec::<f32>::with_capacity(frame_samples * 2)));
    let seq = Arc::new(Mutex::new(0u32));
    let is_active = Arc::new(is_active_fn);
    let vu_cb = Arc::new(vu_callback);

    let stream = match sample_format {
        cpal::SampleFormat::F32 => {
            let pending = pending.clone();
            let seq = seq.clone();
            let encoder = encoder.clone();
            let is_active = is_active.clone();
            let vu_cb = vu_cb.clone();
            let hash = hash_fn.clone();
            let udp = udp.try_clone().context("clone udp")?;
            device.build_input_stream(
                &config,
                move |data: &[f32], _: &cpal::InputCallbackInfo| {
                    let active = is_active();
                    let mono: Vec<f32> = if channels == 1 {
                        data.to_vec()
                    } else {
                        data.chunks(channels)
                            .map(|ch| ch.iter().sum::<f32>() / channels as f32)
                            .collect()
                    };
                    let mono48: Vec<f32> = if sample_rate != 48000 {
                        let ratio = sample_rate as f32 / 48000.0;
                        let mut out = Vec::with_capacity((mono.len() as f32 / ratio) as usize + 1);
                        let mut idx = 0.0f32;
                        while (idx as usize) < mono.len() {
                            out.push(mono[idx as usize]);
                            idx += ratio;
                        }
                        out
                    } else {
                        mono
                    };
                    let db = rms_db(&mono48);
                    vu_cb(db);
                    if !active {
                        return;
                    }
                    let mut pend = pending.lock().unwrap();
                    for s in mono48 {
                        pend.push(s);
                        while pend.len() >= frame_samples {
                            let frame: Vec<f32> = pend.drain(..frame_samples).collect();
                            let mut enc = encoder.lock().unwrap();
                            let pcm_i16: Vec<i16> = frame.iter().map(|f| (f.clamp(-1.0, 1.0) * 32767.0) as i16).collect();
                            let mut out = vec![0u8; 4000];
                            let len = match enc.encode(&pcm_i16, &mut out) {
                                Ok(n) => n,
                                Err(e) => {
                                    warn!(error=%e, "opus encode");
                                    continue;
                                }
                            };
                            out.truncate(len);
                            let mut seqv = seq.lock().unwrap();
                            let hdr = crate::protocol::AudioHeader {
                                seq: *seqv,
                                timestamp_ms: std::time::SystemTime::now()
                                    .duration_since(std::time::UNIX_EPOCH)
                                    .unwrap()
                                    .as_millis() as u32,
                                client_id_hash: hash(),
                            };
                            *seqv = seqv.wrapping_add(1);
                            drop(seqv);
                            drop(enc);
                            let mut pkt = Vec::with_capacity(crate::protocol::AudioHeader::SIZE + out.len());
                            pkt.extend_from_slice(&hdr.encode());
                            pkt.extend_from_slice(&out);
                            let _ = udp.send(&pkt);
                        }
                    }
                },
                |err| warn!(error=%err, "cpal input error"),
                None,
            )?
        }
        cpal::SampleFormat::I16 => {
            let pending = pending.clone();
            let seq = seq.clone();
            let encoder = encoder.clone();
            let is_active = is_active.clone();
            let vu_cb = vu_cb.clone();
            let hash = hash_fn.clone();
            let udp = udp.try_clone().context("clone udp")?;
            device.build_input_stream(
                &config,
                move |data: &[i16], _: &cpal::InputCallbackInfo| {
                    let f32_data: Vec<f32> = data.iter().map(|s| *s as f32 / 32768.0).collect();
                    let mono: Vec<f32> = if channels == 1 {
                        f32_data
                    } else {
                        f32_data
                            .chunks(channels)
                            .map(|ch| ch.iter().sum::<f32>() / channels as f32)
                            .collect()
                    };
                    let mono48: Vec<f32> = if sample_rate != 48000 {
                        let ratio = sample_rate as f32 / 48000.0;
                        let mut out = Vec::with_capacity((mono.len() as f32 / ratio) as usize + 1);
                        let mut idx = 0.0f32;
                        while (idx as usize) < mono.len() {
                            out.push(mono[idx as usize]);
                            idx += ratio;
                        }
                        out
                    } else {
                        mono
                    };
                    let db = rms_db(&mono48);
                    vu_cb(db);
                    if !is_active() {
                        return;
                    }
                    let mut pend = pending.lock().unwrap();
                    for s in mono48 {
                        pend.push(s);
                        while pend.len() >= frame_samples {
                            let frame: Vec<f32> = pend.drain(..frame_samples).collect();
                            let mut enc = encoder.lock().unwrap();
                            let pcm_i16: Vec<i16> = frame.iter().map(|f| (f.clamp(-1.0, 1.0) * 32767.0) as i16).collect();
                            let mut out = vec![0u8; 4000];
                            let len = match enc.encode(&pcm_i16, &mut out) {
                                Ok(n) => n,
                                Err(e) => {
                                    warn!(error=%e, "opus encode i16");
                                    continue;
                                }
                            };
                            out.truncate(len);
                            let mut seqv = seq.lock().unwrap();
                            let hdr = crate::protocol::AudioHeader {
                                seq: *seqv,
                                timestamp_ms: std::time::SystemTime::now()
                                    .duration_since(std::time::UNIX_EPOCH)
                                    .unwrap()
                                    .as_millis() as u32,
                                client_id_hash: hash(),
                            };
                            *seqv = seqv.wrapping_add(1);
                            drop(seqv);
                            drop(enc);
                            let mut pkt = Vec::with_capacity(crate::protocol::AudioHeader::SIZE + out.len());
                            pkt.extend_from_slice(&hdr.encode());
                            pkt.extend_from_slice(&out);
                            let _ = udp.send(&pkt);
                        }
                    }
                },
                |err| warn!(error=%err, "cpal i16 error"),
                None,
            )?
        }
        cpal::SampleFormat::U16 => {
            let pending = pending.clone();
            let seq = seq.clone();
            let encoder = encoder.clone();
            let is_active = is_active.clone();
            let vu_cb = vu_cb.clone();
            let hash = hash_fn.clone();
            let udp = udp.try_clone().context("clone udp")?;
            device.build_input_stream(
                &config,
                move |data: &[u16], _: &cpal::InputCallbackInfo| {
                    let f32_data: Vec<f32> = data.iter().map(|s| (*s as f32 / 65535.0) * 2.0 - 1.0).collect();
                    let mono: Vec<f32> = if channels == 1 {
                        f32_data
                    } else {
                        f32_data
                            .chunks(channels)
                            .map(|ch| ch.iter().sum::<f32>() / channels as f32)
                            .collect()
                    };
                    let mono48: Vec<f32> = if sample_rate != 48000 {
                        let ratio = sample_rate as f32 / 48000.0;
                        let mut out = Vec::with_capacity((mono.len() as f32 / ratio) as usize + 1);
                        let mut idx = 0.0f32;
                        while (idx as usize) < mono.len() {
                            out.push(mono[idx as usize]);
                            idx += ratio;
                        }
                        out
                    } else {
                        mono
                    };
                    let db = rms_db(&mono48);
                    vu_cb(db);
                    if !is_active() {
                        return;
                    }
                    let mut pend = pending.lock().unwrap();
                    for s in mono48 {
                        pend.push(s);
                        while pend.len() >= frame_samples {
                            let frame: Vec<f32> = pend.drain(..frame_samples).collect();
                            let mut enc = encoder.lock().unwrap();
                            let pcm_i16: Vec<i16> = frame.iter().map(|f| (f.clamp(-1.0, 1.0) * 32767.0) as i16).collect();
                            let mut out = vec![0u8; 4000];
                            let len = match enc.encode(&pcm_i16, &mut out) {
                                Ok(n) => n,
                                Err(e) => {
                                    warn!(error=%e, "opus encode u16");
                                    continue;
                                }
                            };
                            out.truncate(len);
                            let mut seqv = seq.lock().unwrap();
                            let hdr = crate::protocol::AudioHeader {
                                seq: *seqv,
                                timestamp_ms: std::time::SystemTime::now()
                                    .duration_since(std::time::UNIX_EPOCH)
                                    .unwrap()
                                    .as_millis() as u32,
                                client_id_hash: hash(),
                            };
                            *seqv = seqv.wrapping_add(1);
                            drop(seqv);
                            drop(enc);
                            let mut pkt = Vec::with_capacity(crate::protocol::AudioHeader::SIZE + out.len());
                            pkt.extend_from_slice(&hdr.encode());
                            pkt.extend_from_slice(&out);
                            let _ = udp.send(&pkt);
                        }
                    }
                },
                |err| warn!(error=%err, "cpal u16 error"),
                None,
            )?
        }
        _ => anyhow::bail!("unsupported input sample format: {:?}", sample_format),
    };

    stream.play().context("play cpal input")?;
    info!("cpal input stream started ({}Hz {}ch {:?}, dev: {})", sample_rate, channels, sample_format, dev_name);
    Ok(stream)
}

#[cfg(any(feature = "client", feature = "server"))]
pub fn find_output_device_by_name(substr: &str) -> Option<cpal::Device> {
    let host = cpal::default_host();
    if let Ok(devices) = host.output_devices() {
        for dev in devices {
            if let Ok(name) = dev.name() {
                if name.to_lowercase().contains(&substr.to_lowercase()) {
                    return Some(dev);
                }
            }
        }
    }
    None
}

/// Server-side virtual mic writer — feeds PipeWire/Pulse sink `sink_name`
/// via `pacat`/`pw-cat` so we never fall back to the default speaker.
/// Uses a small 8192-sample ring (~170 ms @48k) and 20 ms latency to keep
/// delay <100 ms instead of the old 4-second cpal ring (main 1-2 s lag).
#[cfg(any(feature = "client", feature = "server"))]
pub fn spawn_virtual_mic_writer(
    sink_name: &str,
) -> Result<Arc<Mutex<rtrb::Producer<f32>>>> {
    // Small ring — old size 48000*4 = 192k ≈4 s, capped latency was 1-2 s.
    // Now 8192 ≈170 ms max, and we actively trim >50 ms (2400 samples).
    let (prod, cons) = rtrb::RingBuffer::<f32>::new(8192);
    let cons = Arc::new(Mutex::new(cons));
    let prod_arc = Arc::new(Mutex::new(prod));
    let ret = prod_arc.clone();
    let sink = sink_name.to_string();
    let cons_thread = cons.clone();
    std::thread::spawn(move || {
        virtual_mic_writer_thread(sink, cons_thread);
    });
    // Give writer a moment to spawn pacat/pw-cat
    info!(sink=%sink_name, "virtual mic pulse writer started (ring 8192, latency 20ms)");
    // Sunshine moves ALL sink-inputs into sink-sunshine-stereo on session start,
    // hijacking our mic feed: games get silence (source suspends) and the mic is
    // streamed back to the client (self-echo). A guardian re-pins it every 2 s.
    #[cfg(feature = "server")]
    {
        spawn_sink_input_guardian(&sink_name);
        info!(sink=%sink_name, "sink-input guardian started (re-pin every 2s)");
    }
    Ok(ret)
}

/// Re-pin any sink-input belonging to mic-relay back to `sink_name`.
/// Sunshine (and other default-sink switchers) move existing playback streams
/// into their virtual game-audio sink on session start.
#[cfg(feature = "server")]
pub fn spawn_sink_input_guardian(sink_name: &str) {
    let sink = sink_name.to_string();
    std::thread::spawn(move || sink_input_guardian_thread(sink));
}

#[cfg(feature = "server")]
fn sink_input_guardian_thread(sink: String) {
    loop {
        std::thread::sleep(std::time::Duration::from_secs(2));
        if let Err(e) = repin_sink_inputs(&sink) {
            warn!(sink=%sink, error=%e, "sink-input guardian check failed");
        }
    }
}

#[cfg(feature = "server")]
fn repin_sink_inputs(sink: &str) -> Result<()> {
    use std::process::Command;
    let out = Command::new("pactl")
        .args(["list", "sinks", "short"])
        .output()
        .context("pactl list sinks")?;
    let mut sink_idx: Option<String> = None;
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        let cols: Vec<&str> = line.split('\t').collect();
        if cols.len() >= 2 && cols[1] == sink {
            sink_idx = Some(cols[0].to_string());
            break;
        }
    }
    let Some(sink_idx) = sink_idx else {
        anyhow::bail!("sink {sink} not found (recreating?)");
    };

    let out = Command::new("pactl")
        .args(["list", "sink-inputs"])
        .output()
        .context("pactl list sink-inputs")?;
    let text = String::from_utf8_lossy(&out.stdout);
    // (input_idx, sink_idx, application.name)
    let mut entries: Vec<(String, String, String)> = Vec::new();
    let mut cur_idx: Option<String> = None;
    let mut cur_sink: Option<String> = None;
    let mut cur_app: Option<String> = None;
    for line in text.lines() {
        let t = line.trim();
        if let Some(rest) = t.strip_prefix("Sink Input #") {
            if let (Some(i), Some(s)) = (cur_idx.clone(), cur_sink.clone()) {
                entries.push((i, s, cur_app.take().unwrap_or_default()));
            }
            cur_idx = Some(rest.trim().trim_end_matches(':').to_string());
            cur_sink = None;
            cur_app = None;
        } else if let Some(rest) = t.strip_prefix("Sink:") {
            cur_sink = Some(rest.trim().to_string());
        } else if let Some(rest) = t.strip_prefix("application.name = ") {
            cur_app = Some(rest.trim().trim_matches('"').to_string());
        }
    }
    if let (Some(i), Some(s)) = (cur_idx.clone(), cur_sink.clone()) {
        entries.push((i, s, cur_app.take().unwrap_or_default()));
    }

    let mut moved = false;
    for (input, cur, app) in entries {
        if app == "mic-relay" {
            // Our mic feed must stay on the virtual sink
            if cur == sink_idx {
                continue;
            }
            warn!(input=%input, from=%cur, to=%sink_idx, "another program moved the mic stream — re-pinning to virtual mic");
            let st = Command::new("pactl")
                .args(["move-sink-input", &input, sink])
                .status();
            if matches!(st, Ok(s) if s.success()) {
                moved = true;
            }
        } else if cur == sink_idx {
            // Foreign stream (game/browser) ended up IN the mic sink — its audio
            // becomes mic input and is inaudible. Move it to a real sink.
            let Some(target) = fallback_sink(sink).or(cur_default_sink().filter(|d| d != sink)) else {
                continue;
            };
            warn!(input=%input, app=%app, from=sink, to=%target, "foreign stream inside the mic sink — moving out");
            let st = Command::new("pactl")
                .args(["move-sink-input", &input, &target])
                .status();
            if matches!(st, Ok(s) if s.success()) {
                moved = true;
            }
        }
    }

    // The null-sink must never be the default: streams that follow the default
    // (games, browsers) would feed the mic and become inaudible.
    if cur_default_sink().as_deref() == Some(sink) {
        if let Some(alt) = fallback_sink(sink) {
            warn!(from=%sink, to=%alt, "virtual mic is the default sink — repointing default to a real sink");
            let _ = Command::new("pactl")
                .args(["set-default-sink", &alt])
                .status();
        }
    }

    if moved {
        info!(sink=%sink, "sink routing corrected");
    }
    Ok(())
}

/// Best real sink to hand foreign streams to: prefer hardware output
/// (`alsa_output.*`), skip monitors and the virtual mic itself.
#[cfg(feature = "server")]
fn fallback_sink(virtual_sink: &str) -> Option<String> {
    let out = std::process::Command::new("pactl")
        .args(["list", "sinks", "short"])
        .output()
        .ok()?;
    let mut any = None;
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        let cols: Vec<&str> = line.split('\t').collect();
        if cols.len() < 2 {
            continue;
        }
        let name = cols[1];
        if name == virtual_sink || name.ends_with(".monitor") {
            continue;
        }
        if name.starts_with("alsa_output.") {
            return Some(name.to_string());
        }
        if any.is_none() {
            any = Some(name.to_string());
        }
    }
    any
}

#[cfg(feature = "server")]
fn cur_default_sink() -> Option<String> {
    let out = std::process::Command::new("pactl")
        .args(["get-default-sink"])
        .output()
        .ok()?;
    Some(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

#[cfg(any(feature = "client", feature = "server"))]
fn spawn_pacat_child(sink: &str) -> std::io::Result<std::process::Child> {
    // Prefer pacat (PulseAudio compat, always present when pipewire-pulse is enabled)
    // Use float32le mono 48k, low latency 20 ms, raw. Fallback to pw-cat below.
    std::process::Command::new("pacat")
        .args([
            "-p",
            "--raw",
            &format!("--device={sink}"),
            "--rate=48000",
            "--format=float32le",
            "--channels=1",
            "--latency-msec=20",
            "--client-name=mic-relay",
            "--stream-name=MicRelay",
        ])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .spawn()
}

#[cfg(any(feature = "client", feature = "server"))]
fn spawn_pwcat_child(sink: &str) -> std::io::Result<std::process::Child> {
    std::process::Command::new("pw-cat")
        .args([
            "-p",
            "--target",
            sink,
            "--rate",
            "48000",
            "--channels",
            "1",
            "--format",
            "f32",
            "--latency",
            "20ms",
        ])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .spawn()
}

#[cfg(any(feature = "client", feature = "server"))]
fn virtual_mic_writer_thread(sink: String, cons: Arc<Mutex<rtrb::Consumer<f32>>>) {
    use std::io::Write;
    loop {
        let mut child = match spawn_pacat_child(&sink) {
            Ok(c) => {
                info!(sink=%sink, via="pacat", "spawned pulse writer");
                c
            }
            Err(e) => {
                warn!(sink=%sink, error=%e, "pacat spawn failed, trying pw-cat");
                match spawn_pwcat_child(&sink) {
                    Ok(c) => {
                        info!(sink=%sink, via="pw-cat", "spawned pw-cat writer");
                        c
                    }
                    Err(e2) => {
                        warn!(sink=%sink, error=%e2, "both pacat and pw-cat failed — retry in 1s (is pipewire installed?)");
                        std::thread::sleep(std::time::Duration::from_secs(1));
                        continue;
                    }
                }
            }
        };
        let mut stdin = match child.stdin.take() {
            Some(s) => s,
            None => {
                warn!(sink=%sink, "failed to take writer stdin, restarting");
                let _ = child.kill();
                std::thread::sleep(std::time::Duration::from_millis(200));
                continue;
            }
        };
        // Drain ring -> stdin (f32le mono)
        let mut tmp = Vec::<u8>::with_capacity(960 * 4);
        let mut consecutive_empty = 0usize;
        loop {
            // Jitter handling: keep latency <50 ms (2400 samples). Consumer::slots() = occupied items.
            {
                let mut c = cons.lock().unwrap();
                let occupied = c.slots(); // items available to read
                if occupied > 2400 {
                    // drop oldest 480 samples (~10 ms) to catch up
                    for _ in 0..480 {
                        let _ = c.pop();
                    }
                    if occupied > 4000 {
                        // severe backlog, drop another 960
                        for _ in 0..960 {
                            let _ = c.pop();
                        }
                    }
                }
                // Drain up to 960 samples per write burst (20 ms)
                tmp.clear();
                for _ in 0..960 {
                    if let Ok(v) = c.pop() {
                        tmp.extend_from_slice(&v.to_le_bytes());
                        consecutive_empty = 0;
                    } else {
                        break;
                    }
                }
            }
            if tmp.is_empty() {
                consecutive_empty += 1;
                // No data: write silence after 50ms of empty to keep pacat alive and avoid underrun?
                // Instead just sleep 2ms (48000/512 ≈ 10ms period). Busy-wait is fine.
                if consecutive_empty > 50 {
                    // periodic silence keepalive: send 480 samples silence
                    let silence = [0u8; 480 * 4];
                    if stdin.write_all(&silence).is_err() {
                        warn!(sink=%sink, "pulse writer stdin broken (silence), restarting");
                        break;
                    }
                    let _ = stdin.flush();
                    consecutive_empty = 0;
                } else {
                    std::thread::sleep(std::time::Duration::from_millis(2));
                }
                // Check child still alive
                if let Ok(Some(status)) = child.try_wait() {
                    warn!(sink=%sink, status=%status, "pulse writer exited, restarting");
                    break;
                }
                continue;
            }
            if let Err(e) = stdin.write_all(&tmp) {
                warn!(sink=%sink, error=%e, "pulse writer write failed, restarting child");
                break;
            }
            if stdin.flush().is_err() {
                warn!(sink=%sink, "pulse writer flush failed, restarting");
                break;
            }
            if let Ok(Some(status)) = child.try_wait() {
                warn!(sink=%sink, status=%status, "pulse writer died during write, restarting");
                break;
            }
        }
        let _ = child.kill();
        let _ = child.wait();
        std::thread::sleep(std::time::Duration::from_millis(200));
    }
}

/// Legacy cpal fallback — kept for debugging, but server now uses pulse writer.
/// Do NOT call this on PipeWire; it falls back to default sink (audible speakers).
#[cfg(any(feature = "client", feature = "server"))]
pub fn spawn_output_playback(
    source_name: &str,
) -> Result<(cpal::Stream, rtrb::Producer<f32>)> {
    let host = cpal::default_host();
    // Strict: no fallback to default — caller must handle pulse path instead
    let device = find_output_device_by_name(source_name).context(format!(
        "no cpal output device matching '{source_name}' — use pulse writer instead (see spawn_virtual_mic_writer)"
    ))?;
    let dev_name = device.name().unwrap_or_else(|_| "unknown".into());
    info!(device=%dev_name, source=%source_name, "starting cpal output (legacy path)");
    let config = device.default_output_config().context("default output config")?;
    let channels = config.channels() as usize;
    let (prod, cons) = rtrb::RingBuffer::<f32>::new(8192);
    let cons = Arc::new(Mutex::new(cons));
    let stream = match config.sample_format() {
        cpal::SampleFormat::F32 => device.build_output_stream(
            &config.config(),
            {
                let cons = cons.clone();
                move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
                    let mut cons = cons.lock().unwrap();
                    for chunk in data.chunks_mut(channels) {
                        let v = cons.pop().unwrap_or(0.0);
                        for out in chunk.iter_mut() {
                            *out = v;
                        }
                    }
                }
            },
            |err| warn!(error=%err, "cpal output error"),
            None,
        )?,
        cpal::SampleFormat::I16 => device.build_output_stream(
            &config.config(),
            {
                let cons = cons.clone();
                move |data: &mut [i16], _: &cpal::OutputCallbackInfo| {
                    let mut cons = cons.lock().unwrap();
                    for chunk in data.chunks_mut(channels) {
                        let v = cons.pop().unwrap_or(0.0);
                        let s = (v.clamp(-1.0, 1.0) * 32767.0) as i16;
                        for out in chunk.iter_mut() {
                            *out = s;
                        }
                    }
                }
            },
            |err| warn!(error=%err, "cpal output i16"),
            None,
        )?,
        cpal::SampleFormat::U16 => device.build_output_stream(
            &config.config(),
            {
                let cons = cons.clone();
                move |data: &mut [u16], _: &cpal::OutputCallbackInfo| {
                    let mut cons = cons.lock().unwrap();
                    for chunk in data.chunks_mut(channels) {
                        let v = cons.pop().unwrap_or(0.0);
                        let s = ((v.clamp(-1.0, 1.0) + 1.0) * 32767.5) as u16;
                        for out in chunk.iter_mut() {
                            *out = s;
                        }
                    }
                }
            },
            |err| warn!(error=%err, "cpal output u16"),
            None,
        )?,
        _ => anyhow::bail!("unsupported output sample format: {:?}", config.sample_format()),
    };
    stream.play().context("play output")?;
    Ok((stream, prod))
}
