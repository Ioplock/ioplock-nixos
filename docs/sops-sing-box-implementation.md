# sops-nix + sing-box Implementation Reference

Everything you need to know to replicate, modify, or troubleshoot this
setup. This covers the full chain: flake input → NixOS module → sops secrets
→ sing-box runtime merge.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [File Inventory](#file-inventory)
3. [How It Works — Runtime Flow](#how-it-works--runtime-flow)
4. [Flake Input](#flake-input)
5. [sops.nix — The Secret Management Module](#sopsnix--the-secret-management-module)
6. [sing-box.nix — The Proxy Module](#sing-boxnix--the-proxy-module)
7. [.sops.yaml — Recipient Configuration](#sopsyaml--recipient-configuration)
8. [Secret Files](#secret-files)
9. [Host Wiring](#host-wiring)
10. [First-Time Setup Procedure](#first-time-setup-procedure)
11. [Day-to-Day Secret Rotation](#day-to-day-secret-rotation)
12. [Helper Packages](#helper-packages)
13. [Troubleshooting](#troubleshooting)

---

## Architecture Overview

The setup uses a **split-config** pattern:

- **Public config** (committed as plaintext Nix in `sing-box.nix`): DNS
  servers, inbounds (socks :1080, http :8080), routing rules, Russian domain/IP
  bypass via geoip/geosite rule sets. This lives in `services.sing-box.settings`.
- **Secret config** (sops-encrypted JSON in `secrets/sing-box-outbounds.json`):
  Actual proxy server details — vless-grpc, hysteria2, urltest proxy group,
  direct, block outbounds. Encrypted at rest with AES256_GCM, decrypted by
  age at activation time.
- **Runtime merge**: sing-box runs with `-C /run/sing-box` (the nixpkgs
  module default). The nixpkgs module generates `/run/sing-box/config.json`
  from `settings`. An `ExecStartPre` script copies the sops-decrypted secret
  to `/run/sing-box/outbounds.json`. sing-box merges every JSON file in that
  directory, so `outbounds.json` supplements `config.json` with the secret
  outbounds array.

**Decryption chain:**

```
/etc/ssh/ssh_host_ed25519_key
  → ssh-to-age (at activation time, inside sops-nix)
    → age private key
      → decrypt secrets/sing-box-outbounds.json
        → /run/secrets/sing-box-outbounds
          → ExecStartPre copies to /run/sing-box/outbounds.json
            → sing-box merges with config.json
```

---

## File Inventory

| File | Purpose |
|------|---------|
| `flake.nix` | Declares `sops-nix` input (`github:Mic92/sops-nix`, nixpkgs follows) |
| `.sops.yaml` | Maps age recipient to `secrets/.*\.json$` creation rule |
| `modules/features/sops.nix` | NixOS module: imports sops-nix, configures age key path, defines `sops.secrets.sing-box-outbounds`, provides `sops-init-recipient` and `sops-edit` helpers |
| `modules/features/sing-box.nix` | NixOS module: custom sing-box build, DNS/inbounds/routing config, `ExecStartPre` that installs decrypted outbounds |
| `secrets/sing-box-outbounds.json` | Encrypted secret (AES256_GCM, age-encrypted) |
| `secrets/sing-box-outbounds.json.example` | Plaintext template with placeholder values |
| `modules/hosts/acrux/configuration.nix` | Host config that imports `self.nixosModules.sops` and `self.nixosModules.singBox` |

---

## How It Works — Runtime Flow

1. **Boot / nixos-rebuild switch**: NixOS activation runs `sops-nix.service`.
2. **sops-nix** reads `/etc/ssh/ssh_host_ed25519_key`, converts it to an age
   key via `ssh-to-age`, and decrypts `secrets/sing-box-outbounds.json` →
   `/run/secrets/sing-box-outbounds`.
3. **sing-box.service** starts after `sops-nix.service` (explicit `after`
   dependency).
4. **ExecStartPre** runs a shell script:
   ```bash
   install -Dm 600 \
     /run/secrets/sing-box-outbounds \
     /run/sing-box/outbounds.json
   chown sing-box:sing-box /run/sing-box/outbounds.json
   ```
5. **sing-box** starts with `-C /run/sing-box`, merges `config.json` (public)
   + `outbounds.json` (secret), and connects through the proxy outbounds.

The `sops.secrets.sing-box-outbounds.restartUnits = [ "sing-box.service" ]`
setting means if the encrypted secret changes and `nixos-rebuild switch` runs,
sing-box is automatically restarted.

---

## Flake Input

In `flake.nix`:

```nix
sops-nix = {
  url = "github:Mic92/sops-nix";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

- `nixpkgs.follows` prevents duplicate nixpkgs evaluations.
- The module accesses it via `inputs.sops-nix.nixosModules.sops` (standard
  flake-parts pattern through the `inputs` parameter).

---

## sops.nix — The Secret Management Module

**Path:** `modules/features/sops.nix`

This module exports `flake.nixosModules.sops` and two `perSystem` packages.

### NixOS Module (`nixosModules.sops`)

```nix
{ self, inputs, ... }:
{
  flake.nixosModules.sops =
    { config, ... }:
    {
      imports = [ inputs.sops-nix.nixosModules.sops ];

      # Derive age key from host SSH ed25519 key — no separate key file needed
      sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

      sops.defaultSopsFile = ./../../secrets/sing-box-outbounds.json;
      sops.defaultSopsFormat = "json";

      # key = "" → emit the whole decrypted JSON as the secret file
      # (not extracting a single top-level key)
      sops.secrets.sing-box-outbounds = {
        key = "";
        restartUnits = [ "sing-box.service" ];
      };
    };
  # ... perSystem helpers follow ...
};
```

Key points:
- `sops.age.sshKeyPaths` — sops-nix derives the age decryption key from the
  SSH host key at activation time. No `SOPS_AGE_KEY_FILE` needed at runtime.
- `key = ""` — critical: tells sops to emit the full decrypted document rather
  than extracting a single JSON key. sing-box needs the entire `{"outbounds": [...]}` blob.
- `restartUnits` — sing-box is automatically restarted when the secret changes.

### perSystem Helper Packages

#### `sops-init-recipient`

Run once on a fresh host to derive the age public key from the SSH host key
and patch `.sops.yaml`:

```bash
nix run .#sops-init-recipient
```

What it does:
1. Reads `/etc/ssh/ssh_host_ed25519_key.pub`
2. Converts to `age1...` via `ssh-to-age`
3. Replaces the `age1PLACEHOLDER_REPLACE_VIA_sops-init-recipient` token in
   `.sops.yaml` with the real recipient
4. Idempotent — refuses to run if placeholder is already gone

#### `sops-edit`

Drop-in replacement for the `sops` CLI that auto-derives the age private key:

```bash
# Normal edit:
nix run .#sops-edit -- secrets/sing-box-outbounds.json

# Reset (first time — re-encrypt from example template):
nix run .#sops-edit -- --reset secrets/sing-box-outbounds.json
```

What it does:
1. Derives age private key from `/etc/ssh/ssh_host_ed25519_key` via
   `ssh-to-age -private-key` (uses sudo if key is root-only)
2. Writes it to `$XDG_CONFIG_HOME/sops/age/keys.txt` (outside the repo)
3. Sets `SOPS_AGE_KEY_FILE` and runs `sops` with the provided arguments
4. `--reset` mode: copies `.example` over the target, encrypts fresh

---

## sing-box.nix — The Proxy Module

**Path:** `modules/features/sing-box.nix`

### Custom Package (`perSystem.packages.mySingBox`)

```nix
packages.mySingBox = pkgs.sing-box.overrideAttrs (old: {
  tags = lib.unique ((old.tags or [ ]) ++ [
    "with_naive_outbound"
    "with_purego"
  ]);
  postInstall = (old.postInstall or "") + lib.optionalString (cronetLibDir != null) ''
    install -Dm755 \
      ${old.goModules}/github.com/sagernet/cronet-go/lib/${cronetLibDir}/libcronet.so \
      $out/bin/libcronet.so
  '';
});
```

- Adds `with_naive_outbound` and `with_purego` build tags
- Bundles `libcronet.so` for the host platform (x86_64-linux or aarch64-linux)
- No naive outbound is wired into the config — the build just makes it available

### NixOS Module (`nixosModules.singBox`)

#### Public Config (`services.sing-box.settings`)

```nix
services.sing-box = {
  enable = true;
  package = self.packages.${pkgs.stdenv.hostPlatform.system}.mySingBox;

  settings = {
    log = { level = "info"; timestamp = true; };

    dns = {
      servers = [
        { tag = "remote-dns"; type = "tls"; server = "8.8.8.8"; detour = "proxy"; }
        { tag = "local-dns";  type = "https"; server = "1.1.1.1"; }
      ];
      rules = [
        { domain_suffix = [ ".ru" ".su" ".рф" ]; server = "local-dns"; }
        { rule_set = [ "geoip-ru" "geosite-ru" ]; server = "local-dns"; }
      ];
      final = "remote-dns";
    };

    inbounds = [
      { type = "socks"; tag = "socks-in"; listen = "127.0.0.1"; listen_port = 1080; }
      { type = "http";  tag = "http-in";  listen = "127.0.0.1"; listen_port = 8080; }
    ];

    route = {
      default_domain_resolver = { server = "local-dns"; strategy = "ipv4_only"; };
      rule_set = [
        { tag = "geoip-ru";   type = "remote"; format = "binary";
          url = "https://github.com/SagerNet/sing-geoip/raw/rule-set/geoip-ru.srs";
          download_detour = "direct"; }
        { tag = "geosite-ru"; type = "remote"; format = "binary";
          url = "https://github.com/SagerNet/sing-geosite/raw/rule-set/geosite-category-ru.srs";
          download_detour = "direct"; }
      ];
      rules = [
        { domain_suffix = [ ".ru" ".su" ".рф" ]; outbound = "direct"; }
        { rule_set = [ "geoip-ru" "geosite-ru" ]; outbound = "direct"; }
      ];
      auto_detect_interface = true;
      final = "proxy";
    };

    experimental.cache_file.enabled = true;
  };
};
```

**Routing logic:**
- `.ru`, `.su`, `.рф` domains + geoip/geosite-ru rule sets → `direct` (bypass)
- Everything else → `proxy` (through the urltest group in outbounds.json)
- DNS: Russian domains use `local-dns` (1.1.1.1), everything else uses
  `remote-dns` (8.8.8.8 via proxy)

#### Secret Integration (`systemd.services.sing-box`)

```nix
systemd.services.sing-box = {
  after = [ "sops-nix.service" ];
  serviceConfig.ExecStartPre = lib.mkAfter [
    "+${pkgs.writeShellScript "sing-box-install-outbounds" ''
      install -Dm 600 \
        ${config.sops.secrets.sing-box-outbounds.path} \
        /run/sing-box/outbounds.json
      chown sing-box:sing-box /run/sing-box/outbounds.json
    ''}"
  ];
};
```

- `after = [ "sops-nix.service" ]` — ensures decryption completes first
- `config.sops.secrets.sing-box-outbounds.path` resolves to
  `/run/secrets/sing-box-outbounds` at runtime
- The `+` prefix runs the script as root (needed for `/run/sing-box/` access)
- `install -Dm 600` creates the directory if missing, sets restrictive perms
- `chown sing-box:sing-box` — sing-box service runs as the `sing-box` user

---

## .sops.yaml — Recipient Configuration

**Path:** `.sops.yaml`

```yaml
keys:
  - &acrux age1vjjve4xm7a8gc2es5yelngpn8yjskfptd7ahyjr4e3k7p0kawylsphwazy
creation_rules:
  - path_regex: secrets/.*\.json$
    key_groups:
      - age:
          - *acrux
```

- YAML anchor `&acrux` defines the age public key for host `acrux`
- `creation_rules` applies to all files matching `secrets/.*\.json$`
- The age public key is safe to commit — only the SSH host private key on
  disk can decrypt

---

## Secret Files

### `secrets/sing-box-outbounds.json.example` (Template)

The plaintext template with placeholder values:

```json
{
  "outbounds": [
    {
      "type": "urltest",
      "tag": "proxy",
      "outbounds": ["vless-grpc", "hysteria-out"],
      "url": "https://www.gstatic.com/generate_204",
      "interval": "3m",
      "tolerance": 50
    },
    {
      "type": "vless",
      "tag": "vless-grpc",
      "server": "example.com",
      "server_port": 443,
      "uuid": "REPLACE-WITH-UUID",
      "flow": "xtls-rprx-vision",
      "domain_resolver": { "server": "local-dns", "strategy": "ipv4_only" },
      "tls": {
        "enabled": true,
        "server_name": "example.com",
        "utls": { "enabled": true }
      },
      "transport": { "type": "grpc", "service_name": "grpc-service" }
    },
    {
      "type": "hysteria2",
      "tag": "hysteria-out",
      "server": "example.com",
      "server_ports": ["20000:50000"],
      "domain_resolver": { "server": "local-dns", "strategy": "ipv4_only" },
      "hop_interval": "30s",
      "password": "REPLACE",
      "up_mbps": 100,
      "down_mbps": 100,
      "obfs": { "type": "salamander", "password": "REPLACE" },
      "tls": { "enabled": true, "server_name": "example.com", "insecure": false }
    },
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }
  ]
}
```

Fields to fill with real values:
- `vless-grpc`: `server`, `server_port`, `uuid`, `server_name`, `service_name`
- `hysteria-out`: `server`, `server_ports`, `password`, `obfs.password`, `server_name`

### `secrets/sing-box-outbounds.json` (Encrypted)

The actual encrypted file. All values are `ENC[AES256_GCM,...]` blobs.
SOPS metadata at the bottom contains the age recipient, version, and
last modified timestamp. Safe to commit.

---

## Host Wiring

In `modules/hosts/acrux/configuration.nix`:

```nix
imports = [
  # ...
  self.nixosModules.singBox
  self.nixosModules.sops
  # ...
];
```

Both modules must be imported. The host must have:
- `services.openssh` enabled (for `/etc/ssh/ssh_host_ed25519_key`)
- User in `wheel` group (for sudo access to read the SSH host key)

---

## First-Time Setup Procedure

### Prerequisites

- NixOS booted with `services.openssh` enabled
- `/etc/ssh/ssh_host_ed25519_key` (and `.pub`) exist
- User is in `wheel` group
- `$EDITOR` is set

### Steps

Run all commands from the repo root.

#### 1. Sanity check

```bash
nix flake check
nixos-rebuild dry-build --flake .#<host>
```

Both must pass before proceeding.

#### 2. Derive age recipient and patch .sops.yaml

```bash
git add -A
nix run .#sops-init-recipient
```

Verifies: `grep age1 .sops.yaml` — should show real recipient, not placeholder.

#### 3. Re-encrypt the secret against the real recipient

```bash
nix run .#sops-edit -- --reset secrets/sing-box-outbounds.json
```

This copies the `.example` template, encrypts it with the host's real age key.
The file now contains placeholder values — sing-box starts but can't connect.

#### 4. Edit with real outbound values

```bash
nix run .#sops-edit -- secrets/sing-box-outbounds.json
```

Opens `$EDITOR` with decrypted JSON. Fill in real server details. Save and quit.
sops re-encrypts on save.

#### 5. Stage for the builder

```bash
git add -A
git status --short
```

Flakes only see git-tracked/staged files. The re-encrypted secret and
`.sops.yaml` must be staged.

#### 6. Build-check and switch

```bash
nix flake check
nixos-rebuild dry-build --flake .#<host>
sudo nixos-rebuild switch --flake .#<host>
```

---

## Day-to-Day Secret Rotation

To change outbounds without touching Nix:

```bash
nix run .#sops-edit -- secrets/sing-box-outbounds.json
git add -A
sudo nixos-rebuild switch --flake .#<host>
```

The `restartUnits` setting automatically restarts `sing-box.service`.

---

## Helper Packages

Both helpers are defined in `modules/features/sops.nix` under `perSystem`.

### sops-init-recipient

| Aspect | Detail |
|--------|--------|
| Package | `packages.sops-init-recipient` |
| Runtime deps | `openssh`, `ssh-to-age`, `gnused`, `git` |
| Usage | `nix run .#sops-init-recipient` |
| What it does | Reads SSH pub key → converts to age → patches `.sops.yaml` |
| Idempotent | Yes — refuses if placeholder already replaced |

### sops-edit

| Aspect | Detail |
|--------|--------|
| Package | `packages.sops-edit` |
| Runtime deps | `openssh`, `ssh-to-age`, `sops`, `coreutils`, `git` |
| Usage | `nix run .#sops-edit -- [flags] <file>` |
| What it does | Derives age key from SSH host key → runs `sops` |
| Key location | `$XDG_CONFIG_HOME/sops/age/keys.txt` (outside repo) |
| `--reset` mode | Copies `.example` over target, encrypts fresh |

---

## Troubleshooting

### `sudo: a terminal is required to read the password`

The helpers need an interactive terminal for sudo. Run in a real shell.

### `sed: couldn't open temporary file ...: Read-only file system`

Old version of the helper that baked `.sops.yaml` into the nix store.
Rebuild (`git add -A && nix flake check`) and re-run.

### sops opens a blank/default config

You hit `--reset` against a target without a `.example`, or on a file already
encrypted with the real key. Omit `--reset` for normal editing.

### Activation fails: `sops-decrypt: ... no matching key`

The encrypted file's recipient doesn't match the host's age key.
Re-run `sops-init-recipient` to confirm `.sops.yaml`, then `--reset` to
re-encrypt.

### `nix flake check` warns `Git tree is dirty`

Harmless — means unstaged changes. Run `git add -A`.

### sing-box fails to start after switch

Check:
1. `systemctl status sops-nix.service` — did decryption succeed?
2. `ls -la /run/secrets/sing-box-outbounds` — does the decrypted file exist?
3. `ls -la /run/sing-box/outbounds.json` — did ExecStartPre install it?
4. `journalctl -u sing-box` — any config merge errors?

### Adding a new host

1. Add a new key in `.sops.yaml`:
   ```yaml
   keys:
     - &acrux age1...
     - &newhost age1...   # derive via sops-init-recipient on the new host
   creation_rules:
     - path_regex: secrets/.*\.json$
       key_groups:
         - age:
             - *acrux
             - *newhost
   ```
2. Re-encrypt the secret so both hosts can decrypt:
   ```bash
   nix run .#sops-edit -- secrets/sing-box-outbounds.json
   ```
3. Import `self.nixosModules.sops` and `self.nixosModules.singBox` in the
   new host's `configuration.nix`.

### Using with other secrets

To add more sops-managed secrets:
1. Add a new `sops.secrets.<name>` in `sops.nix` (or a new module)
2. Update `.sops.yaml` path_regex if needed (or keep `secrets/.*\.json$`)
3. Reference via `config.sops.secrets.<name>.path` in the consumer module
4. Add `restartUnits` if the consumer service should restart on change
