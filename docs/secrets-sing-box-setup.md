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
contains the example placeholder values (`example.com`, `REPLACE-WITH-UUID`,
etc.). sing-box would start but fail to connect — that's expected until you
fill in real values.

### 4. Edit the secret with real outbound values

```bash
nix run .#sops-edit -- secrets/sing-box-outbounds.json
```

This derives the age private key from the host SSH key again (sudo prompt)
and opens the decrypted file in `$EDITOR`. Replace the placeholders with your
real outbounds:

- `vless-grpc`: `server`, `server_port`, `uuid`, `server_name`, `service_name`
- `hysteria-out`: `server`, `server_ports`, `password`, `obfs.password`,
  `server_name`

The `urltest` group (`tag: "proxy"`) and `direct`/`block` outbounds normally
do not need editing. Save and quit (`:wq` in vim). sops re-encrypts on save.
If you quit without changing anything, sops discards the file ("file has not
changed, not writing") — make a real edit or the file keeps its old values.

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
`/run/sing-box/outbounds.json`, and sing-box starts with the merged config.

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
