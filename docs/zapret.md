# zapret: DPI bypass with private strategies

The `zapret` feature runs zapret2 (nfqws2) from nixpkgs on hosts that import
`self.nixosModules.zapret`, using desync strategies maintained in the
**private** `zapret-cfg` repository. This repo is public, so strategies,
domain lists and blob files are sops-encrypted into `secrets/zapret.json` —
they never appear in the Nix store, the systemd unit file or anywhere in this
repository as plain text.

## Components

| Name | Where | Purpose |
|---|---|---|
| `packages.myZapretImport` | `modules/features/zapret.nix` | Regenerates `secrets/zapret.json` from a zapret-cfg checkout |
| `packages.myNfqws2` | `modules/features/zapret.nix` | Shell wrapper set as `services.zapret2.package` (merges public args + decrypted strategies) |
| `flake.nixosModules.zapret` | `modules/features/zapret.nix` | sops secrets, `zapret2` user, `services.zapret2` config, service overrides |
| `secrets/zapret.json` | sops-encrypted | 9 keys: strategies + 8 lists/blobs references |
| `secrets/zapret.json.example` | plaintext placeholder | Key-name reference only (values say `--placeholder`) |

Source of truth for strategy content is always zapret-cfg:
`config/strategies.conf`, `lists/*.txt`, `blobs/*.bin`. Never edit
`secrets/zapret.json` by hand via `sops-edit` — re-run the import script
instead, otherwise your changes are lost on the next import.

## How it works at runtime

nfqws2 expands an `@file` given as argv[1] into the *entire* command line and
ignores every other argument. The upstream `services.zapret2` module has to
generate its own arguments (`--qnum`, `--fwmark`, `--lua-init`, firewall
match flags), so they and the private strategies must be merged into one
runtime file. That merge is the wrapper's job:

1. `services.zapret2.package` is set to `myNfqws2`, so the module builds its
   normal ExecStart against the wrapper (`--qnum=200`, `--fwmark=0x40000000`,
   `--lua-init=@<zapret-lib>`, `--lua-init=@<zapret-antidpi>`, ...).
2. The wrapper concatenates those arguments (`"$@"`) and the decrypted
   strategies file (`$ZAPRET_STRATEGIES`, set by the service override from
   `sops.secrets.zapret-strategies.path`) into a temp file, then runs two
   checks mirroring zapret-cfg's `start.sh`:
   - `--dry-run` prepended check — validates every parameter and file.
   - `--intercept=0` prepended check — initialises the Lua environment.
3. If both pass, it `exec`s the real nfqws2 (`pkgs.zapret2`) with the merged
   file as argv[1] (or exits with the exact error before touching the
   network).

Why `services.zapret2.profiles` is left empty: profile parameters are secrets
and would be embedded verbatim into the world-readable unit file. The
strategies arrive at runtime through the wrapper instead.

Because the `package` is the unit-less wrapper, the module compensates:

- `systemd.packages = [ pkgs.zapret2 ]` — provides the actual
  `nfqws2@.service` unit.
- `services.zapret2.files` uses absolute store paths to the shipped Lua
  files — default names would otherwise resolve against the wrapper, which
  has no `share/zapret2` directory.

Setup decided at module level:

- firewall: TCP `{80, 443, 2053, 2083, 2087, 2096, 8443}`, all UDP
  (`udpPorts = null` — the module option cannot express the Discord voice
  port ranges; this is a superset of zapret-cfg's verified rules),
  `maxPackets = 12`, `queue = 200`, `desyncFwmark = 0x40000000`.
- `net.netfilter.nf_conntrack_acct = 1` sysctl — the generated nftables
  rules match `ct original packets 1-12`, which requires conntrack accounting.
- static system user/group `zapret2` (not DynamicUser) so `sops-nix` can
  chown the 0400 secrets; service unit `nfqws2@default` gets `After =
  sops-install-secrets.service` and `ZAPRET_STRATEGIES` from the decrypted
  path.
- The upstream module generates and installs the nftables matching rules
  itself (`configureAutomatically = true` by default, which asserts
  `networking.nftables.enable` — both hosts satisfy this).

## Importing strategies

Run this whenever the content in a zapret-cfg checkout changes (strategies,
lists, blobs). From anywhere inside this repo:

```bash
nix run .#myZapretImport -- /path/to/zapret-cfg
```

The script (requires `sops`, `jq` — provided by the derivation):

1. Validates the checkout: `config/strategies.conf` readable, 8 lists
   non-empty (`targets`, `list-{google,discord,cloudflare,exclude}`,
   `ipset-{discord,cloudflare,exclude}`), the two blob files readable.
2. Rejects unsafe strategy content up front: `$`, backtick or an unquoted
   glob (`*`, `[`, `?` after whitespace). nfqws2 wordexp-parses the config;
   these characters would fail to parse or expand unexpectedly and produce a
   service that cannot start.
3. Transforms the strategies:
   - `--lua-init=...` lines are dropped (the module provides both Lua files
     via `services.zapret2.files`).
   - `--blob=<name>:@blobs/<file>.bin` → `--blob=<name>:0x<hex>` (the blob is
     embedded as hex so the secret stays self-contained).
   - `=lists/<name>.txt` → `=/run/secrets/zapret-<name>` (nfqws2 reads the
     decrypted list files directly at runtime).
4. Derives the age key the same way `sops-edit` does:
   `~/.config/sops/age/keys.txt`, auto-generated from
   `/etc/ssh/ssh_host_ed25519_key` if readable. If it is not readable and no
   key file exists, run `nix run .#sops-edit -- <file>` once first (it uses
   `sudo` to convert the host key), then re-run the import.
5. Writes the plaintext to a temp file **under `secrets/`** (so the
   `.sops.yaml` creation rule `secrets/.*\.json$` encrypts it for every
   registered host), encrypts it in place, and atomically moves it over
   `secrets/zapret.json`.

Then make the result visible and verify:

```bash
git add secrets/zapret.json
nix flake check
nixos-rebuild dry-build --flake .#<host>
```

`git add` matters: Nix evaluates the flake from the git tree, so an untracked
`secrets/zapret.json` is invisible to evaluation and the flake fails to
resolve the `sopsFile`.

## First deployment on a new host

sops-nix decrypts with the age key derived from the host's SSH ed25519 key,
so the new host must be a registered recipient **before** the first switch.

1. Follow the sops host-registration procedure in
   `docs/secrets-sing-box-setup.md` (run `nix run .#sops-init-recipient` on
   the new host).
2. Sync the secret to the new recipients:
   ```bash
   nix run .#sops-edit -- updatekeys secrets/zapret.json
   ```
3. Import `self.nixosModules.zapret` into
   `modules/hosts/<host>/configuration.nix` (next to the other feature
   imports).
4. `git add` every changed/new file, then `nix flake check`,
   `nixos-rebuild dry-build --flake .#<host>`, and switch.

The age key materialises on the host during the first switch
(`sops.age.sshKeyPaths` in the `sops` module); no manual key copy is needed.

## Day-2 operations

The service is the template unit instance `nfqws2@default`:

```bash
systemctl status nfqws2@default
systemctl stop nfqws2@default     # nftables rules are removed on stop
systemctl start nfqws2@default    # re-created on start
journalctl -u nfqws2@default -b
```

- Starts automatically at boot; stopping it is safe and takes the generated
  nftables rules (queue 200 interception) with it.
- Every one of the 9 secrets has `restartUnits = [ "nfqws2@default" ]`:
  changing an encrypted value and switching restarts the service with the
  new content.
- Runtime decrypted files land in `/run/secrets/`:
  `/run/secrets/zapret-strategies`, `/run/secrets/zapret-targets`,
  `/run/secrets/zapret-list-{google,discord,cloudflare,exclude}`,
  `/run/secrets/zapret-ipset-{discord,cloudflare,exclude}` (mode 0400, owner
  `zapret2`).
- Check the interception rules: `nft list ruleset | grep -F 'queue num 200'`.

Do **not** run zapret-cfg's `linux/start.sh` on the same host while the
service runs: both install firewall rules for queue 200 — they collide.

This feature provisions no DNS changes; the strategies only affect nfqws2
traffic shaping, exactly as in zapret-cfg.

## Troubleshooting

**Import rejects the strategies** (`unsafe for nfqws2 config parsing`):
edit the offending line in zapret-cfg (replace `$`, backticks, unquoted
globs), commit there, re-run the import.

**Service fails at boot — "cannot read strategies file" / sops errors**:
check `journalctl -u sops-install-secrets.service` (host not a recipient?
see "First deployment") and `journalctl -u nfqws2@default` for the
missing-file error.

**Service fails with a parameter or Lua error**:
the wrapper surfaces nfqws2's real error from the `--dry-run` or
`--intercept=0` phase. Reproduce manually as `zapret2` with
`ZAPRET_STRATEGIES=/run/secrets/zapret-strategies` to inspect the merged
file logic.

**Behavior regressions after a zapret2 version bump**: strategies were
verified on 2026-10-15 (Hl_telecom.K14) against zapret v1.0.5.2 pinned in
zapret-cfg's vendor tree. nixpkgs provides the same upstream version but a
differently built binary; if the ISP behavior regresses after a nixpkgs
update, re-run the zapret-cfg verification flow before blaming the
configuration.

**sing-box traffic**: connections to the sing-box server (TCP 443 to the
VPS) leave through the same postrouting rules and are intercepted too. If
proxy throughput or latency regresses while zapret runs, verify whether the
server IP is covered by the strategy exclusions — the port-based interception
itself cannot skip individual IPs.
