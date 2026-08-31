// Stub for future: cpal capture + opus encode helpers.
// Kept minimal so server feature builds without pulling eframe.
#[cfg(all(feature = "opus", feature = "cpal"))]
pub mod opus_helpers {
    // Placeholder — real impl will wrap `opus::Encoder` / `Decoder`
}
