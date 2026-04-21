# AGENTS.md

Instructions for AI agents (Claude, Copilot, Cursor, etc.) working on this
NixOS configuration.

---

## Read the Docs First — Mandatory

Before any change, read both documents in full:

- [`docs/architecture.md`](docs/architecture.md) — dendritic pattern, output
  namespaces, Nix-native config rule, wrapper-modules guide (pre-built
  wrappers, shared wrapper modules, `wrapPackage`), and the layered
  environment pattern.
- [`docs/conventions.md`](docs/conventions.md) — naming rules, file layout,
  step-by-step workflows, verification commands, and hard constraints.

Do not skip this. The structure of this repo is non-standard.

---

## Before Any Change — Mandatory Checklist

### 1. Search the internet

This repo tracks `nixos-unstable`. APIs change. Before writing any Nix:

- Search [search.nixos.org/packages](https://search.nixos.org/packages) — confirm current package attribute name.
- Search [search.nixos.org/options](https://search.nixos.org/options) — confirm option names, types, defaults.
- For `wrapper-modules`, fetch the current docs:
  <https://birdeehub.github.io/nix-wrapper-modules/md/getting-started.html>
- For other flake inputs (`flake-parts`, `import-tree`, etc.), fetch the
  current README from their GitHub.

Do not rely on training-data knowledge for any of the above — it may be stale.

### 2. Find the correct tool for the task

Before writing any program configuration, run this decision tree:

1. Does a `programs.<n>` or `services.<n>` NixOS module exist?
   → [search.nixos.org/options](https://search.nixos.org/options). Use it.
2. Does `nix-wrapper-modules` have a pre-built wrapper for this program?
   → [birdeehub.github.io/nix-wrapper-modules](https://birdeehub.github.io/nix-wrapper-modules/md/getting-started.html). Use it.
3. Can `lib.wrapPackage` produce the right derivation?
   → Build it in `perSystem`. See `docs/architecture.md#lib.wrappackage`.
4. None of the above?
   → Write a typed NixOS module with `options`. **Never paste a raw config string.**

### 3. Verify the structural pattern

Every file under `modules/` must be a flake-parts module:

- Top-level function signature is `{ self, inputs, ... }: { ... }`.
- Outputs go under `flake.*` or `perSystem`.
- Cross-module references go through `self.nixosModules.*`,
  `self.wrapperModules.*`, or `self'.packages.*` — never relative paths.

---

## Hard Constraints — Never Violate

1. **Never use relative `import` paths between modules.**

2. **Never write raw config file content** (`writeText`, `etc.*`,
   `xdg.configFile` with `.text`, `runCommand` producing config files).
   Always use NixOS options or `wrapper-modules`.
   See `docs/architecture.md#the-nix-native-configuration-rule`.

3. **Never use `pkgs.buildEnv` to create environment packages.**
   The correct tool is `inputs.wrapper-modules.lib.wrapPackage` with
   `extraPackages`. See `docs/architecture.md#environment-packages`.

4. **Never run `nixos-rebuild switch` or `nixos-rebuild boot`.**
   Only `nix flake check` and `nixos-rebuild dry-build` are permitted.
   The user decides when to switch. This is firm — do not ask for sudo,
   do not offer to switch, do not suggest it.

5. **Never change `system.stateVersion`.**

6. **Never write to the same `flake.*` key from two different files.**
   `import-tree` merges all files; duplicate keys produce silent last-write-wins
   behaviour.

7. **Never add secrets, passwords, or tokens.**

8. **Never add business logic to `default.nix` assembly files.**

9. **Never inline hardware configuration into `configuration.nix`.**

---

## Output Namespaces — Keep Them Separate

| Namespace | Purpose | Do not confuse with |
|---|---|---|
| `flake.nixosModules.*` | NixOS system modules | wrapper modules |
| `flake.wrappers.*` | Partially-evaluated reusable wrapper configs | nixosModules |
| `flake.wrapperModules.*` | Raw wrapper module fragments for `imports = [...]` | nixosModules |
| `perSystem.packages.my*` | Built derivations | global package sets |

---

## Workflow for Common Tasks

### Configure a program

1. NixOS option → 2. pre-built wrapper → 3. `lib.wrapPackage` → 4. typed NixOS module.
   **Never a raw config string.** See `docs/architecture.md#the-nix-native-configuration-rule`.

### Build a wrapped package

Follow `docs/conventions.md#adding-a-wrapped-package`. Always fetch the
current wrapper-modules API before writing wrapper code.

### Build a layered environment (shell → terminal → desktop)

Follow `docs/architecture.md#environment-packages`. Key points:
- Shell layer: `lib.wrapPackage { package = pkgs.<shell>; extraPackages = [...]; }`
- Terminal layer: pre-built wrapper with `shell = lib.getExe self'.packages.myShellEnv`
- Desktop layer: compositor wrapper with `terminal = lib.getExe self'.packages.myTerminal`
- Always use `self'` (prime) to reference other `perSystem` packages.

### Add a system package to a host

Edit `modules/hosts/<host>/configuration.nix`, append to
`environment.systemPackages`. Confirm the package name on
`search.nixos.org/packages` first.

### Add a new feature (NixOS module)

Follow `docs/conventions.md#adding-a-new-feature`.

### Add a new host

Follow `docs/conventions.md#adding-a-new-host`.

### Modify niri settings

Edit the `perSystem` block in `modules/features/niri.nix`. Fetch the current
option schema from the wrapper-modules docs before editing.

### Update a flake input

```bash
nix flake update <input-name>
```

Then `nixos-rebuild dry-build --flake .#<host>`. Report outcome — do not switch.

---

## Verification

After any change, run and report:

```bash
nix flake check                          # always first
nixos-rebuild dry-build --flake .#acrux  # build check, no side effects
```

Do not present a change as complete until `nix flake check` passes.

**Never run:**
```bash
sudo nixos-rebuild switch ...   # ❌ never
sudo nixos-rebuild boot   ...   # ❌ never
```

---

## Project Structure Reference

```
.
├── AGENTS.md
├── docs/
│   ├── architecture.md    ← dendritic pattern, output namespaces,
│   │                         Nix-native config rule, wrapper-modules
│   │                         guide, layered environment pattern
│   └── conventions.md     ← naming, workflows, do-not list, commands
├── flake.lock
├── flake.nix              ← entry point; edit only to add new inputs
└── modules/
    ├── parts.nix          ← flake-parts config (supported systems)
    ├── features/
    │   └── niri.nix       ← nixosModules.niri + wrappers.niri + perSystem packages
    └── hosts/
        └── acrux/
            ├── configuration.nix
            ├── default.nix
            └── hardware.nix
```

---

## Key Inputs

| Input | Repo | Purpose |
|---|---|---|
| `nixpkgs` | `github:nixos/nixpkgs/nixos-unstable` | Package set and NixOS modules |
| `flake-parts` | `github:hercules-ci/flake-parts` | Modular flake structure |
| `import-tree` | `github:vic/import-tree` | Auto-imports all `.nix` under `modules/` |
| `wrapper-modules` | `github:BirdeeHub/nix-wrapper-modules` | Typed wrappers + `lib.wrapPackage` + flake-parts module |