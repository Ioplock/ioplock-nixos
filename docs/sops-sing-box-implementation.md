# sops-nix + sing-box Implementation Reference

This is the design reference for the running system: flake input → NixOS
modules → SOPS secret → runtime merge → sing-box routing. For the ordered
procedure to configure a fresh machine, use
[`secrets-sing-box-setup.md`](secrets-sing-box-setup.md) instead.

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
10. [Helper Packages](#helper-packages)
11. [Troubleshooting](#troubleshooting)
12. [Tor Runtime Design](#tor-runtime-design)

---

## Architecture Overview

The setup uses a **split-config** pattern:

- **Public config** (committed as plaintext Nix in `sing-box.nix`): DNS
  servers, one mixed SOCKS/HTTP inbound on `127.0.0.1:1080`, routing rules,
  Russian domain/IP bypass via geoip/geosite rule sets. This lives in
  `services.sing-box.settings`.
- **Secret config** (sops-encrypted JSON in `secrets/sing-box-outbounds.json`):
  Actual proxy server details — vless-grpc, hysteria2, local SOCKS, the
  bridge-ready Tor outbound, urltest proxy group, and direct/block outbounds.
  Encrypted at rest with AES256_GCM, decrypted by age at activation time.
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
| `modules/hosts/*/configuration.nix` | Host configs importing `self.nixosModules.sops` and `self.nixosModules.singBox`; currently acrux and mimosa |

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

## Tor Runtime Design

`tor-out` is a candidate in the `proxy` urltest group. It starts the
Nix-provided Tor binary from its stable runtime path; its persistent state
directory is `/var/lib/sing-box/tor`.

The service exposes the pluggable transports under stable runtime paths:

```text
/run/sing-box/pt/tor
/run/sing-box/pt/lyrebird
/run/sing-box/pt/snowflake-client
```

They are symlinks to the exact Nix-built packages selected by the system, so
the encrypted config does not need to contain a Nix store hash.
`tor-out.executable_path` deliberately names `/run/sing-box/pt/tor`.

sing-box represents `torrc` as a map, which cannot represent repeated Tor
directives. The repeated `ClientTransportPlugin` and `Bridge` directives must
therefore be sent as `extra_args` pairs at Tor startup. The operational bridge
procedure and secret-handling rules are in the
[first-time setup guide](secrets-sing-box-setup.md#emergency-tor-fallback).

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

Run on a fresh or newly-added host to derive the age public key from its
SSH host key and register it in `.sops.yaml`:

```bash
nix run .#sops-init-recipient
```

What it does:
1. Reads `/etc/ssh/ssh_host_ed25519_key.pub`
2. Converts to `age1...` via `ssh-to-age`
3. Registers the recipient in `.sops.yaml`, depending on state:
   - placeholder present → replaces it (fresh-repo bootstrap)
   - already present → idempotent no-op
   - otherwise → appends a `- &<hostname> <recipient>` anchor under
     `keys:` and adds the alias to every creation rule's age list
4. Prints the follow-up sync command (`sops-edit -- updatekeys`)

#### `sops-edit`

Drop-in replacement for the `sops` CLI that manages the age private key
for you:

```bash
# Normal edit:
nix run .#sops-edit -- secrets/sing-box-outbounds.json

# Reset (fresh repo — re-encrypt from example template):
nix run .#sops-edit -- --reset secrets/sing-box-outbounds.json

# Apply current .sops.yaml creation rules to an already-encrypted file:
nix run .#sops-edit -- updatekeys secrets/sing-box-outbounds.json
```

What it does:
1. Uses `$XDG_CONFIG_HOME/sops/age/keys.txt` when it exists; only when it
   does not, derives the private key from `/etc/ssh/ssh_host_ed25519_key`
   via `ssh-to-age -private-key` (sudo if root-only) and writes it there
2. Sets `SOPS_AGE_KEY_FILE` and runs `sops` with the provided arguments
3. `--reset` mode: copies `.example` over the target, encrypts fresh

Gotchas baked into this design: plain `sops -e -i` refuses files that are
already encrypted, and `sops rotate -i` re-uses a file's existing recipients
without consulting `.sops.yaml`. To change *who* can decrypt, use
`updatekeys`; to change *what* is inside, use a normal edit.

---

## sing-box.nix — The Proxy Module

**Path:** `modules/features/sing-box.nix`

### Custom Package (`perSystem.packages.mySingBox`)

```nix
packages.mySingBox = pkgs.sing-box.overrideAttrs (old: {
  tags = lib.unique ((old.tags or [ ]) ++ [
    "with_naive_outbound"
    "with_purego"
    "with_gvisor"
    "with_quic"
    "with_utls"
    "with_wireguard"
  ]);
  postInstall = (old.postInstall or "") + lib.optionalString (cronetLibDir != null) ''
    install -Dm755 \
      ${old.goModules}/github.com/sagernet/cronet-go/lib/${cronetLibDir}/libcronet.so \
      $out/bin/libcronet.so
  '';
});
```

- Adds NaiveProxy/purego plus gVisor, QUIC, uTLS, and WireGuard build tags.
- Bundles `libcronet.so` for the host platform (x86_64-linux or aarch64-linux)
- The current config does not wire NaiveProxy or WireGuard outbounds, but the
  core supports them for later use.

### NixOS Module (`nixosModules.singBox`)

#### Public Config (`services.sing-box.settings`)

The Nix-native `settings` attribute produces the public `config.json`; it
contains no outbound credentials. Its concrete behavior is:

- A `mixed` listener on `127.0.0.1:1080` accepts both SOCKS5 and HTTP proxy
  traffic.
- `geohide-dns` is DNS-over-HTTPS to `dns.geohide.ru:444/dns-query`, resolved
  initially through `local-dns` and sent through `proxy` thereafter.
- `local-dns` is Cloudflare DNS-over-HTTPS (`1.1.1.1`). Russian suffixes and
  the Russian GeoIP/Geosite rule sets use it; other queries use `geohide-dns`.
- `.ru`, `.su`, `.рф`, `geoip-ru`, and `geosite-ru` route directly. All other
  traffic uses the secret `proxy` URLTest outbound.
- The GeoIP/Geosite rule sets download directly, interface autodetection is
  enabled, and sing-box's cache file is enabled.

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
      install -d -m 755 /run/sing-box/pt
      ln -sfn ${pkgs.tor}/bin/tor /run/sing-box/pt/tor
      ln -sfn ${lib.getExe pkgs.obfs4} /run/sing-box/pt/lyrebird
      ln -sfn ${pkgs.snowflake}/bin/client /run/sing-box/pt/snowflake-client
      install -d -m 700 -o sing-box -g sing-box /var/lib/sing-box/tor
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
- The two symlinks decouple secret JSON from changing Nix store hashes.
- `/var/lib/sing-box/tor` persists Tor state so the Tor process does not
  create a new cold state directory on every service restart.

---

## .sops.yaml — Recipient Configuration

**Path:** `.sops.yaml`

```yaml
keys:
  - &acrux age1vjjve4xm7a8gc2es5yelngpn8yjskfptd7ahyjr4e3k7p0kawylsphwazy
  - &mimosa age1fnkd9ujtym3l9acrhupdtaz4sluf3pkq59mqymxtnskkaqdf3dnq77kjjt
creation_rules:
  - path_regex: secrets/.*\.json$
    key_groups:
      - age:
          - *acrux
          - *mimosa
```

- One YAML anchor per host defines that host's age public key (derived from
  its SSH ed25519 key)
- `creation_rules` applies to all files matching `secrets/.*\.json$` and
  encrypts them for every listed host
- Age public keys are safe to commit — only the SSH host private keys on
  disk can decrypt
- Register additional hosts with `nix run .#sops-init-recipient` on the
  host itself, then sync existing secrets with `sops-edit -- updatekeys`

---

## Secret Files

### `secrets/sing-box-outbounds.json.example` (Template)

The plaintext template has explicit placeholders for every VLESS, Hysteria2,
and local SOCKS value, and preserves the active uTLS, Reality, and TLS
fragmentation settings. It also contains the bridge-ready `tor-out` and its
stable transport-plugin paths. Because it is valid JSON for SOPS, comments
are documented in [Tor Runtime Design](#tor-runtime-design) instead
of embedded in the file.

### `secrets/sing-box-outbounds.json` (Encrypted)

The actual encrypted file. All values are `ENC[AES256_GCM,...]` blobs.
SOPS metadata at the bottom contains the age recipient, version, and
last modified timestamp. Safe to commit.

---

## Host Wiring

In each host's `configuration.nix` (currently acrux and mimosa):

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


The operational procedure for first deployment, validation, bridge setup, and
later secret rotation is in [the setup guide](secrets-sing-box-setup.md).

---

## Helper Packages

Both helpers are defined in `modules/features/sops.nix` under `perSystem`.

### sops-init-recipient

| Aspect | Detail |
|--------|--------|
| Package | `packages.sops-init-recipient` |
| Runtime deps | `openssh`, `ssh-to-age`, `gnused`, `git` |
| Usage | `nix run .#sops-init-recipient` |
| What it does | Reads SSH pub key → converts to age → registers anchor + alias in `.sops.yaml` |
| Idempotent | Yes — no-op when the host is already registered |

### sops-edit

| Aspect | Detail |
|--------|--------|
| Package | `packages.sops-edit` |
| Runtime deps | `openssh`, `ssh-to-age`, `sops`, `coreutils`, `git` |
| Usage | `nix run .#sops-edit -- [flags] <file>` (any sops args, incl. `updatekeys`) |
| What it does | Prefers an existing user age key; derives one from the SSH host key otherwise → runs `sops` |
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

The encrypted file's recipients don't include the host's age key.
Confirm the host is registered in `.sops.yaml` (`sops-init-recipient`),
then sync the secret from a host that can already decrypt it:

```bash
nix run .#sops-edit -- updatekeys secrets/sing-box-outbounds.json
```

### `nix flake check` warns `Git tree is dirty`

Harmless — means unstaged changes. Run `git add -A`.

### sing-box fails to start after switch

Check:
1. `systemctl status sops-nix.service` — did decryption succeed?
2. `ls -la /run/secrets/sing-box-outbounds` — does the decrypted file exist?
3. `ls -la /run/sing-box/outbounds.json` — did ExecStartPre install it?
4. `journalctl -u sing-box` — any config merge errors?

### Adding a new host

1. On the new host, register its recipient:
   ```bash
   git add -A
   nix run .#sops-init-recipient   # appends anchor + creation-rule alias
   ```
2. Commit, push, and pull on every machine so all see the updated
   `.sops.yaml`.
3. From any host that can already decrypt (e.g. acrux), sync existing
   secrets to the new recipient set:
   ```bash
   nix run .#sops-edit -- updatekeys secrets/sing-box-outbounds.json
   ```
4. Commit the rotated secret and import `self.nixosModules.sops` and
   `self.nixosModules.singBox` in the new host's `configuration.nix`.

Note: `sops rotate -i` would NOT work for step 3 — it re-uses a file's
existing recipients and ignores `.sops.yaml`. `updatekeys` is what applies
current creation rules.

### Using with other secrets

To add more sops-managed secrets:
1. Add a new `sops.secrets.<name>` in `sops.nix` (or a new module)
2. Update `.sops.yaml` path_regex if needed (or keep `secrets/.*\.json$`)
3. Reference via `config.sops.secrets.<name>.path` in the consumer module
4. Add `restartUnits` if the consumer service should restart on change
