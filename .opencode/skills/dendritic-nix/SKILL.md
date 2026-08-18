---
name: dendritic-nix
description: Use when reading, explaining, reviewing, or changing Nix in this repository's dendritic NixOS flake. Applies the flake-parts/import-tree module shape, self-based output references, wrapper-modules namespaces, Nix-native configuration rule, local naming conventions, and safe verification. Do not use as generic guidance for unrelated Nix projects.
metadata:
  project: nixconf
  pattern: dendritic-nix
---

# Dendritic Nix

Work with this repository as a dendritic NixOS flake built from
`flake-parts`, `import-tree`, and `nix-wrapper-modules`.

## Load the source of truth

Before changing any file, find the Git worktree root and read these files in
full:

1. `AGENTS.md`
2. `docs/architecture.md`
3. `docs/conventions.md`

Those files override this skill if they change or conflict with it. Do not
infer the architecture from a conventional NixOS repository layout.

Before writing Nix, verify unstable APIs against their current upstream
sources:

- Search `search.nixos.org/packages` for package attribute names.
- Search `search.nixos.org/options` for NixOS option names, types, and
  defaults.
- Read the current `nix-wrapper-modules` documentation before using wrapper
  APIs.
- Read the current upstream README for other flake inputs such as
  `flake-parts` and `import-tree` when changing their usage.

## Understand the architecture

`flake.nix` calls `flake-parts.lib.mkFlake`, and `import-tree` discovers every
`.nix` file below `modules/`. Therefore every file below `modules/` is itself a
flake-parts module with this outer shape:

```nix
{ self, inputs, ... }: {
  flake.nixosModules.myFeature = { pkgs, lib, ... }: {
    # NixOS module configuration
  };

  perSystem = { pkgs, self', ... }: {
    packages.myPackage = /* derivation */;
  };
}
```

Directory names organize the code but do not control imports. All matching
files are always imported and merged. Guard optional behavior with module
options, not by conditionally including files.

Cross-module dependencies must go through flake outputs:

```nix
imports = [
  self.nixosModules.acruxHardware
  self.nixosModules.niri
];
```

Never use a relative import between files under `modules/`.

## Keep output namespaces distinct

| Namespace | Value |
|---|---|
| `flake.nixosModules.<name>` | NixOS system module |
| `flake.wrappers.<name>` | Reusable, partially evaluated wrapper configuration |
| `flake.wrapperModules.<name>` | Raw wrapper module fragment used in wrapper `imports` |
| `perSystem.packages.my<Name>` | Locally built package for the current system |

Use `self.nixosModules.*` for NixOS module imports,
`self.wrapperModules.*` for shared wrapper imports, and
`self'.packages.*` for dependencies on other current-system packages. From a
NixOS module, select a per-system package with:

```nix
self.packages.${pkgs.stdenv.hostPlatform.system}.myPackage
```

Do not define the same `flake.*` key in multiple files. `import-tree` merging
can otherwise produce silent last-write-wins behavior.

## Put code in the right place

- `modules/features/<feature>.nix`: reusable NixOS features and related
  wrappers or packages.
- `modules/hosts/<host>/hardware.nix`:
  `flake.nixosModules.<host>Hardware`; generated hardware details.
- `modules/hosts/<host>/configuration.nix`:
  `flake.nixosModules.<host>Configuration`; host identity, system settings,
  hardware imports, and feature imports.
- `modules/hosts/<host>/default.nix`:
  `flake.nixosConfigurations.<host>`; thin assembly only, with no business
  logic.
- `modules/parts.nix`: flake-parts systems and shared flake configuration.

Name `flake.nixosModules` and wrapper keys in camelCase. Name locally built
packages `my<Name>` so they cannot be confused with nixpkgs attributes.

## Configure programs through typed Nix interfaces

Never emit a program configuration as an untyped raw string. Choose the first
applicable mechanism:

1. A `programs.<name>` or `services.<name>` NixOS module.
2. A pre-built `nix-wrapper-modules` wrapper.
3. `inputs.wrapper-modules.lib.wrapPackage` in `perSystem`.
4. A custom NixOS module with typed `options` and `config`.

Forbidden escape hatches include config-producing `writeText`, `runCommand`,
`environment.etc.<name>.text`, and `xdg.configFile.<name>.text`.

Use a pre-built wrapper's `.wrap` for supported programs. When wrapper
settings must be shared, define `flake.wrappers.<name>` and import the exposed
fragment through `self.wrapperModules.<name>` at the build site. Use `.apply`
only when extending an evaluated base wrapper for related variants.

Use `inputs.wrapper-modules.lib.wrapPackage` for an ad-hoc wrapper and for
environment packages. It returns the package directly. Never replace this
with `pkgs.buildEnv`.

Small helper programs may use `pkgs.writeShellApplication`; use
`runtimeInputs` for their dependencies. This exception is for executable
scripts, not application configuration files.

Always use `lib.getExe` when an option needs an executable path.

## Compose layered environments

Build each layer in `perSystem` and reference the layer below through
`self'.packages`:

```text
myDesktop  -> myTerminal -> myShellEnv
```

- Build `myShellEnv` with `lib.wrapPackage`, using `extraPackages` for tools.
- Configure the terminal wrapper's shell with
  `lib.getExe self'.packages.myShellEnv`.
- Configure the desktop wrapper's terminal with
  `lib.getExe self'.packages.myTerminal`.

Install only the final package in the host when the transitive environment is
desired. Keep every layer independently usable.

## Preserve repository invariants

- Never change `system.stateVersion`.
- Never add secrets, passwords, or tokens.
- Never inline hardware configuration into `configuration.nix`.
- Do not hand-edit `hardware.nix` except for intentional kernel-module or
  filesystem adjustments.
- Do not duplicate reusable settings across hosts; extract a feature module.
- Do not add business logic to a host `default.nix`.
- Preserve unrelated work in a dirty worktree.
- Edit `flake.nix` only when a new input is actually required.

## Verify changes safely

After changing Nix, run these in order from the repository root:

```bash
nix flake check
nixos-rebuild dry-build --flake .#host
```

Do not report a Nix change complete unless `nix flake check` passes. Report
the result of both checks, including any environmental blocker.

Never run or recommend `nixos-rebuild switch` or `nixos-rebuild boot`. Never
ask for sudo to activate the configuration; activation belongs to the user.
