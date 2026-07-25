# First-time setup: sops-nix + sing-box on a fresh machine

This is the ordered procedure to bring up sops-nix secrets and the sing-box
client on a host that has never run this configuration before. It assumes the
machine already boots NixOS with `services.openssh` enabled (so
`/etc/ssh/ssh_host_ed25519_key` exists). If openssh is not yet active, deploy
the config once *without* the `singBox`/`sops` imports, reboot, then follow
this guide.

## Why order matters

sops-nix runs an activation script on `nixos-rebuild switch` that decrypts
`secrets/sing-box-outbounds.json` using the age key derived from the host's
SSH ed25519 key. The shipped `secrets/sing-box-outbounds.json` is a bootstrap
placeholder encrypted with a **throwaway** age key the host cannot decrypt.
If you switch before re-encrypting it with the host's real age recipient,
activation fails.

So the rule is: **prepare the secret before the first switch**, not after.

## Prerequisites

- `services.openssh` enabled and an ed25519 host key present at
  `/etc/ssh/ssh_host_ed25519_key` (and `.pub`).
- You are a member of `wheel` (the helpers use `sudo` to read the root-only
  private key).
- You are in a terminal where `sudo` can prompt for a password.
- `$EDITOR` is set to something usable (e.g. `vim`, `nano`).
- The target host imports both `self.nixosModules.sops` and
  `self.nixosModules.singBox`. The public Nix module provides the mixed
  SOCKS/HTTP proxy on `127.0.0.1:1080`; do not put credentials or bridge
  values in that module.
- Your VLESS/Hysteria2 subscription details are available. If you want the
  emergency Tor fallback from the first deployment, also have at least one
  valid bridge line ready. It is safe to deploy without a bridge, but that
  Tor candidate will remain unavailable.

## Steps

Run every command from the repo root (`/home/ioplock/nixconf` on acrux).
The helpers `cd` there themselves, but staying at the root avoids confusion.

### 1. Evaluate the config (sanity check, no side effects)

```bash
nix flake check
nixos-rebuild dry-build --flake .#acrux
```

Both must pass before going further. This confirms the modules evaluate and
the custom `mySingBox` build and `sops-init-recipient` / `sops-edit` helpers
are wired up.

Also confirm the host imports the two modules before continuing:

```bash
rg 'self\.nixosModules\.(sops|singBox)' modules/hosts/<host>/configuration.nix
```

Both names must appear. If they do not, add the imports as part of the host
configuration before preparing the secret.

### 2. Derive the host's age recipient and patch `.sops.yaml`

```bash
git add -A
nix run .#sops-init-recipient
```

This reads `/etc/ssh/ssh_host_ed25519_key.pub`, converts it to an `age1...`
recipient via `ssh-to-age`, and replaces the `age1PLACEHOLDER_...` token in
`.sops.yaml` with the real recipient. It refuses to run if the placeholder is
already gone (idempotent guard).

The `age1...` value is a **public** key — it is safe to commit. Only the
private half (the SSH host key on disk) can decrypt, and that never leaves
`/etc/ssh/`.

Verify:
```bash
grep age1 .sops.yaml   # should show your real recipient, not PLACEHOLDER
```

### 3. Re-encrypt the secret against the real recipient

The placeholder file was encrypted with a throwaway key. Replace it with a
fresh copy of `secrets/sing-box-outbounds.json.example`, encrypted to your
real recipient:

```bash
nix run .#sops-edit -- --reset secrets/sing-box-outbounds.json
```

This:
- copies `secrets/sing-box-outbounds.json.example` over the placeholder,
- encrypts it in place with `sops -e -i` using the age key derived from the
  host SSH key (sudo will prompt for your password here),
- prints instructions for the next step.

After this step the file is encrypted to the host's real recipient but still
contains the example placeholder values (`REPLACE-WITH-VLESS-HOST`,
`REPLACE-WITH-VLESS-UUID`, etc.). sing-box would start but fail to connect —
that's expected until you fill in real values.

### 4. Edit the secret with real outbound values

```bash
nix run .#sops-edit -- secrets/sing-box-outbounds.json
```

This derives the age private key from the host SSH key again (sudo prompt)
and opens the decrypted file in `$EDITOR`. Replace the placeholders with your
real outbounds. Keep the field layout from the template unless your provider
specifies otherwise:

- `vless-grpc`: `server`, `server_port`, `uuid`, TLS `server_name`, Reality
  `public_key` / `short_id`, and the gRPC `service_name`. Keep `utls`,
  `record_fragment`, and `fragment` enabled when they are part of your working
  connection.
- `hysteria-out`: `server`, `server_ports`, `password`, `obfs.password`, TLS
  `server_name`, and any provider-specific port range. Keep its TLS
  fragmentation fields when they are part of your working connection.
- `socks-out`: the local SOCKS server address and port, if you use it.

The `urltest` group (`tag: "proxy"`) already includes all configured
candidates—VLESS, Hysteria2, local SOCKS, and Tor—and normally needs no
editing. `direct` and `block` also need no edits. Save and quit (`:wq` in
vim). sops re-encrypts on save. If you quit without changing anything, sops
discards the file ("file has not changed, not writing") — make a real edit or
the file keeps its old values.

#### Emergency Tor fallback

The template contains a bridge-ready `tor-out`. It starts the Nix-provided
Tor binary through the stable `executable_path` below; no globally installed
Tor package is required. Keep that `executable_path` in the encrypted
outbound.

At service start, Nix exposes the selected transport binaries at stable paths:

```text
/run/sing-box/pt/tor
/run/sing-box/pt/lyrebird
/run/sing-box/pt/snowflake-client
```

Leave the two existing `--ClientTransportPlugin` argument pairs intact. They
enable obfs4/Lyrebird and Snowflake without putting an unstable Nix store path
in the encrypted file.

When you obtain a bridge, append a `--Bridge` pair to `tor-out.extra_args` in
the encrypted outbound. For an obfs4 bridge, the shape is:

```json
"--Bridge",
"obfs4 REPLACE-WITH-IP:PORT REPLACE-WITH-FINGERPRINT cert=REPLACE-WITH-CERT iat-mode=0"
```

Add one such pair per bridge. Keep bridge addresses, fingerprints, and
certificates only in `secrets/sing-box-outbounds.json`; do not put them in the
public Nix module or the `.example` file. `torrc` is deliberately limited to
single-value options because sing-box represents it as a JSON map. Repeated
directives such as `ClientTransportPlugin` and `Bridge` therefore belong in
`extra_args`.

Until at least one valid bridge is added, the Tor candidate is intentionally
unusable; urltest can still select the VLESS, Hysteria2, or local SOCKS
candidates.

### 5. Stage the encrypted files for the builder

Flakes only see git-tracked (or staged) files. The re-encrypted secret and
`.sops.yaml` must be staged or `nixos-rebuild` will evaluate against the old
placeholder:

```bash
git add -A
git status --short       # confirm secrets/ and .sops.yaml are staged
```

You can commit now if you like (the repo rules let you commit secrets
because they are encrypted). Do **not** commit any private age key file —
the helpers write that to `$XDG_CONFIG_HOME/sops/age/keys.txt` outside the
repo.

### 6. Build-check again, then switch

```bash
nix flake check
nixos-rebuild dry-build --flake .#acrux
```

When you are satisfied, switch (you decide when):

```bash
sudo nixos-rebuild switch --flake .#acrux
```

On activation sops-nix decrypts `secrets/sing-box-outbounds.json` to
`/run/secrets/sing-box-outbounds`, the sing-box `ExecStartPre` installs it to
`/run/sing-box/outbounds.json`, creates the stable Tor transport paths, and
sing-box starts with the merged config.

After the first switch, inspect the service before relying on it:

```bash
systemctl status sing-box.service
journalctl -u sing-box.service -b --no-pager
```

With a valid Tor bridge, the journal should show Tor bootstrapping rather than
an immediate transport or bridge error. A Tor connection test is not possible
before bridge values are supplied.

Finally, test both protocols accepted by the mixed listener:

```bash
curl --proxy socks5h://127.0.0.1:1080 -fsS https://www.gstatic.com/generate_204
curl --proxy http://127.0.0.1:1080 -fsS https://www.gstatic.com/generate_204
```

Both commands should exit successfully with an empty response body. `urltest`
normally selects the lowest-latency healthy outbound; Tor is an emergency
candidate and is selected when the faster candidates are unavailable.

## Day-to-day changes later

To change outbounds (rotate a server, add a node, tweak urltest) without
touching Nix:

```bash
nix run .#sops-edit -- secrets/sing-box-outbounds.json
git add -A
sudo nixos-rebuild switch --flake .#acrux
```

The `sops.secrets.sing-box-outbounds.restartUnits` setting restarts
`sing-box.service` automatically when the secret changes.

## Troubleshooting

### `sudo: a terminal is required to read the password`

The helpers need an interactive terminal for sudo. Run them in a real shell,
not from a non-interactive context.

### `sed: couldn't open temporary file ...: Read-only file system`

You hit an old version of the helper that baked `.sops.yaml` into the nix
store. Rebuild the helper (`git add -A && nix flake check`) and re-run; the
current version operates on the real repo file.

### `Could not open in-place file for writing: ... no such file or directory`

You ran the helper from a subdirectory and the relative path doubled. The
current helpers `cd` to the repo root via `git rev-parse --show-toplevel`, so
this should not happen — if it does, make sure `git` is in `runtimeInputs`
(you may be on an older build).

### sops opens a blank/default config instead of my file

You hit `--reset` against a target whose `.example` did not exist, or you ran
`--reset` on a file already encrypted with the real key. Omit `--reset` for
normal editing; only use it the first time (step 3).

### `nix flake check` warns `Git tree is dirty`

Harmless. It just means you have unstaged changes. Stage them with
`git add -A` so the builder sees the latest files.

### Activation fails: `sops-decrypt: ... no matching key`

The encrypted file's recipient does not match any key the host can produce.
Re-run step 2 (`sops-init-recipient`) to confirm `.sops.yaml` has the host's
real `age1...`, then re-run step 3 (`--reset`) to re-encrypt.

### sing-box fails to start or the proxy on port 1080 does not respond

Check the startup chain in this order:

1. `systemctl status sops-nix.service` — the secret must decrypt first.
2. `ls -la /run/secrets/sing-box-outbounds` — confirms the decrypted JSON
   exists.
3. `ls -la /run/sing-box/outbounds.json` — confirms the service copied it
   into sing-box's merged configuration directory.
4. `ls -la /run/sing-box/pt` — confirms the Tor, Lyrebird, and Snowflake
   static paths were exposed.
5. `journalctl -u sing-box.service -b --no-pager` — reports JSON validation,
   outbound, DNS, or Tor bootstrap errors.

If the main VLESS/Hysteria2 connections work but Tor logs a bridge or
transport error, re-open the encrypted secret and verify the bridge is a
complete `--Bridge`/bridge-line pair and that the transport name matches it
(`obfs4` or `snowflake`).
