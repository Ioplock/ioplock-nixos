# Remote gaming: Sunshine (mimosa) + Moonlight (acrux)

mimosa streams its desktop over the LAN with
[Sunshine](https://github.com/LizardByte/Sunshine); acrux connects with the
`moonlight-qt` client. mimosa is headless — Sunshine captures the display
forced into existence by `boot.kernelParams` (`drm.edid_firmware=HDMI-A-1`)
and encodes with the RX 5700 XT's VA-API.

## How it is wired

| Piece | Where | Notes |
|---|---|---|
| Feature module | `modules/features/sunshine.nix` | `nixosModules.sunshine`, imported by mimosa only |
| Upstream NixOS module | `services.sunshine` | systemd **user** service bound to `graphical-session.target`; uwsm activates that target for the greetd autologin niri session |
| Capture | KMS via CAP_SYS_ADMIN | `capSysAdmin = true`; no physical screen needed |
| Encoder | VA-API auto-detect | `adapter_name` unset on purpose |
| Firewall | TCP 47984/47989/47990/48010, UDP 47998-48000/48002/48010 | opened by `openFirewall = true` |
| Discovery | mDNS | avahi advertisement enabled by the module |

## Credentials

Web-UI login lives in the sops secret `secrets/sunshine-credentials.json`,
declared in `modules/features/sops.nix` and owned by the primary user (the
service is a user unit and reads `/run/secrets/sunshine-credentials.json`).

Sunshine parses **flat** keys — no wrapper object:

```json
{
  "username": "mimosa",
  "password": "A1B2...",   // UPPERCASE hex of SHA256(plaintext_password + salt)
  "salt": "16 random chars"
}
```

Regenerate (from acrux):

```bash
SALT=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c16)
PASS='<new password>'
HASH=$(printf '%s%s' "$PASS" "$SALT" | sha256sum | cut -d' ' -f1 | tr 'a-f' 'A-F')
nix run .#sops-edit -- -d -o /tmp/opencode/sunshine-credentials.json secrets/sunshine-credentials.json
jq --arg p "$HASH" --arg s "$SALT" '.password=$p | .salt=$s' \
  /tmp/opencode/sunshine-credentials.json > secrets/sunshine-credentials.json
rm /tmp/opencode/sunshine-credentials.json
nix run .#sops-edit -- -e -i secrets/sunshine-credentials.json
```

Then switch and restart the service manually — sops-nix is a system unit and
cannot restart the user unit directly:

```bash
ssh mimosa@192.168.1.92 systemctl --user -M mimosa@ restart sunshine
```

## Pairing a Moonlight client

1. Launch Moonlight; mimosa appears via mDNS (or add `192.168.1.92` manually).
2. Note the PIN the client shows.
3. Open `https://192.168.1.92:47990`, log in with the credentials above,
   enter the PIN under PIN tab.
4. Stream "Desktop". The gaming niri session is already live via autologin.

## Declarative-settings tradeoff

Any non-empty `services.sunshine.settings` locks out web-UI configuration
(upstream module behaviour), so encoder/display tuning happens in
`sunshine.nix`. Exactly two keys are set today; note the upstream module only
passes its rendered config file when **more than one** setting differs from
defaults — do not trim to one.
