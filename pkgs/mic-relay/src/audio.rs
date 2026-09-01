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

#[cfg(any(feature = "client", feature = "server"))]
pub fn spawn_output_playback(
    source_name: &str,
) -> Result<(cpal::Stream, rtrb::Producer<f32>)> {
    let host = cpal::default_host();
    let device = find_output_device_by_name(source_name)
        .or_else(|| host.default_output_device())
        .context("no output device for playback")?;
    let dev_name = device.name().unwrap_or_else(|_| "unknown".into());
    info!(device=%dev_name, source=%source_name, "starting cpal output to virtual sink");
    let config = device.default_output_config().context("default output config")?;
    let channels = config.channels() as usize;
    let (prod, cons) = rtrb::RingBuffer::<f32>::new(48000 * 4);
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
