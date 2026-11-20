# WiVRn on Mimosa

The `wivrn` feature enables the native WiVRn user service, LAN discovery,
firewall ports, high-priority scheduling, and Steam OpenXR runtime import.
It uses VA-API HEVC encoding on Mimosa's AMD GPU. The nixpkgs package includes
xrizer for OpenVR games such as Half-Life: Alyx.

The server starts on login after the configuration is activated. Open **WiVRn
Server** in the application menu, or run `wivrn-dashboard`, for pairing and
status. To start or restart the service manually:

```bash
systemctl --user restart wivrn
```

## Play a Proton game from Steam

1. Close SteamVR and ALVR. Open the WiVRn dashboard on Mimosa.
2. Open **WiVRn** on the PICO 4 (look under unknown sources if necessary).
   Select **mimosa**, connect, and complete pairing if prompted. If discovery
   fails, enter Mimosa's LAN address, currently `192.168.1.92`.
3. Once connected, start the existing game shortcut in desktop Steam.
   Keep its existing Proton compatibility selection.

The headset must connect before the game starts: WiVRn selects its OpenXR
runtime and xrizer at connection time. SteamVR should remain closed. WiVRn also
lists manually added Steam shortcuts when their `OpenVR` flag is enabled. Alyx
is marked as VR so it can be launched from the headset; desktop Steam also works.
Restart Steam and reconnect WiVRn after changing a shortcut's VR flag.

For the existing **Half Life Alyx.exe** shortcut, the launch options are:

```text
OXR_RECENTER_STAGE=1 PRESSURE_VESSEL_IMPORT_OPENXR_1_RUNTIMES=1 %command% -vr
```

This preserves `-vr` and imports WiVRn into Steam's sandbox, including before
a new login picks up the feature's session environment variable. Other Steam
games normally need no extra runtime option after a new login.
`OXR_RECENTER_STAGE=1` is the [upstream workaround](https://github.com/WiVRn/WiVRn/issues/806#issuecomment-3957832997)
for OpenVR games that ignore the headset's recenter action.

For audio, select WiVRn's virtual output/input while the headset is connected.
Start with the headset application's default bitrate and resolution; adjust
them after confirming a clear, stable image.

To return to Steam Link, close the VR game and disconnect WiVRn. WiVRn restores
the previous runtime once the connection and all VR applications have closed.

## Headset controls

- Click both thumbsticks down simultaneously to show or hide WiVRn's in-stream
  window. The headset app's **Settings → In-stream window** must be enabled.
- Hold a controller's grip button to reposition the WiVRn window.
- Look forward and hold the PICO controller's **Home** button for about one
  second to recenter your view. Restart Alyx after changing its launch options.

Sources: [WiVRn controls](https://github.com/WiVRn/WiVRn/blob/v26.9/client/scenes/stream_gui.cpp),
[PICO controller buttons](https://www.picoxr.com/jp/support/faq/controller-function-buttons).

## Versions and diagnostics

The headset app and server must have the same version. Check the pinned server:

```bash
nix eval --raw .#nixosConfigurations.mimosa.config.services.wivrn.package.version
journalctl --user -u wivrn -b --no-pager
```

The initial PICO installation is the official `WiVRn-release.apk` from
[WiVRn v26.9](https://github.com/WiVRn/WiVRn/releases/tag/v26.9), matching the
current flake lock. Update the headset app along with future server updates.

Upstream: [usage and pairing](https://github.com/WiVRn/WiVRn/tree/v26.9#usage),
[Steam integration](https://github.com/WiVRn/WiVRn/blob/v26.9/docs/steamvr.md),
[encoder configuration](https://github.com/WiVRn/WiVRn/blob/v26.9/docs/configuration.md).
