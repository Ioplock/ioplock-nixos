# Conventions & Best Practices

## Naming Conventions

### `flake.nixosModules` keys

camelCase, prefixed with host or feature name:

| Kind | Pattern | Example |
|---|---|---|
| Host hardware | `<host>Hardware` | `acruxHardware` |
| Host configuration | `<host>Configuration` | `acruxConfiguration` |
| Feature | `<featureName>` | `niri`, `docker`, `fonts` |

### `flake.wrappers` / `flake.wrapperModules` keys

camelCase, name matches the program being wrapped:

```nix
flake.wrappers.niri      # ✅
flake.wrappers.myShell   # ✅  for a custom shell environment
```

### `perSystem.packages` keys

camelCase with a `my` prefix to distinguish locally-built packages from nixpkgs:

```nix
packages.myNiri        # ✅
packages.myShellEnv    # ✅
packages.myTerminal    # ✅
packages.niri          # ❌  could shadow nixpkgs
```

### Files & Directories

- Host directories: `modules/hosts/<hostname>/` — lowercase, matches `networking.hostName`.
- Feature files: `modules/features/<featureName>.nix` — one feature per file
  unless complex enough to warrant a subdirectory.

---

## Adding a New Host

1. **`hardware.nix`** — run `nixos-generate-config` and wrap the result:

   ```nix
   { self, inputs, ... }: {
     flake.nixosModules.<hostname>Hardware = { config, lib, modulesPath, ... }: {
       imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];
       # generated hardware config
     };
   }
   ```

2. **`configuration.nix`** — system settings, imports hardware + features:

   ```nix
   { self, inputs, ... }: {
     flake.nixosModules.<hostname>Configuration = { pkgs, ... }: {
       imports = [
         self.nixosModules.<hostname>Hardware
         self.nixosModules.niri
       ];
       system.stateVersion = "25.05";
       networking.hostName = "<hostname>";
     };
   }
   ```

3. **`default.nix`** — assembly point only, no logic:

   ```nix
   { self, inputs, ... }: {
     flake.nixosConfigurations.<hostname> = inputs.nixpkgs.lib.nixosSystem {
       modules = [ self.nixosModules.<hostname>Configuration ];
     };
   }
   ```

4. Add the target system to `modules/parts.nix` if not already listed.

---

## Adding a New Feature (NixOS module)

1. Create `modules/features/<featureName>.nix`.
2. Expose under `flake.nixosModules.<featureName>`.
3. If the feature needs a built package, add a `perSystem` block with
   `packages.my<FeatureName>`.
4. Import in the host's `configuration.nix` via `self.nixosModules.<featureName>`.

---

## Adding a Wrapped Package

When a program should be configured via `nix-wrapper-modules`:

1. Check if a pre-built wrapper exists:
   [birdeehub.github.io/nix-wrapper-modules](https://birdeehub.github.io/nix-wrapper-modules/md/getting-started.html).

2. If the wrapper config should be reusable, define it under `flake.wrappers.*`:

   ```nix
   { self, inputs, ... }: {
     flake.wrappers.myProgram = { config, lib, pkgs, wlib, ... }: {
       imports = [ wlib.wrapperModules.myProgram ];
       # custom options + config
     };
   }
   ```

3. Build the package in `perSystem`:

   ```nix
   perSystem = { pkgs, self', ... }: {
     packages.myProgram = inputs.wrapper-modules.wrappers.myProgram.wrap {
       inherit pkgs;
       imports = [ self.wrapperModules.myProgram ];
       # option overrides for this specific build
     };
   };
   ```

4. Reference in the NixOS module via
   `self.packages.${pkgs.stdenv.hostPlatform.system}.myProgram`.

---

## Adding an Environment (Layered Wrapped Shell)

The full pattern is described in `docs/architecture.md#environment-packages`.
Quick checklist:

- Shell layer: `lib.wrapPackage { package = pkgs.<shell>; extraPackages = [...]; env = {...}; }`
- Terminal layer: pre-built wrapper with `shell = lib.getExe self'.packages.myShellEnv`
- Desktop layer: niri (or similar) wrapper with `terminal = lib.getExe self'.packages.myTerminal`
- All layers built in `perSystem`, named `my<n>` with `my` prefix.
- Reference lower layers with `self'.packages.*` (prime `'`).

---

## What Belongs Where

| Concern | Location |
|---|---|
| Hardware (filesystems, kernel modules, microcode) | `hosts/<host>/hardware.nix` |
| Host identity (hostname, timezone, users, stateVersion) | `hosts/<host>/configuration.nix` |
| Reusable service/program NixOS configs | `modules/features/<feature>.nix` |
| flake-parts system list | `modules/parts.nix` |
| Reusable wrapper module config | `flake.wrappers.<n>` in a feature file |
| Per-system package build (wrappers, environments, scripts) | `perSystem` block in a feature file |

---

## system.stateVersion

- Set **once** per host in `configuration.nix`.
- **Never change it** after the host has been deployed.
- The value must match the NixOS version at time of first install.

---

## nixpkgs Channel

This flake tracks `nixos-unstable`. Before adding or changing packages:

- Check [search.nixos.org/packages](https://search.nixos.org/packages) for current attribute names.
- Check [search.nixos.org/options](https://search.nixos.org/options) for module option names/types.
- Prefer `pkgs.*` over `inputs.nixpkgs.legacyPackages.*` inside NixOS modules.

---

## Do Not

- **Do not** use relative `import` paths between modules. Always go through
  `self.nixosModules.*`, `self.wrapperModules.*`, or `self'.packages.*`.
- **Do not** write raw config file strings (`writeText`, `etc.*`,
  `xdg.configFile` with `.text`). Always use NixOS options or wrapper-modules.
  See `docs/architecture.md#the-nix-native-configuration-rule`.
- **Do not** use `pkgs.buildEnv` for environment packages. The correct tool is
  `inputs.wrapper-modules.lib.wrapPackage` with `extraPackages`. See
  `docs/architecture.md#environment-packages`.
- **Do not** add business logic to `default.nix` assembly files.
- **Do not** edit `hardware.nix` by hand except for kernel modules or
  filesystem adjustments.
- **Do not** duplicate settings across hosts — extract into a feature module.
- **Do not** commit secrets. Use `sops-nix`, `agenix`, or external env files.
- **Do not** run `nixos-rebuild switch` or `nixos-rebuild boot`. See below.

---

## Permitted Verification Commands

```bash
# Evaluate the flake — always run this first
nix flake check

# Build check — catches missing packages and option type errors, no side effects
nixos-rebuild dry-build --flake .#acrux

# Inspect all flake outputs
nix flake show

# Build a specific package
nix build .#myNiri
nix build .#myShellEnv
```

**Never run:**
```bash
sudo nixos-rebuild switch ...   # ❌
sudo nixos-rebuild boot   ...   # ❌
```

---

## Updating Inputs

```bash
nix flake update            # all inputs
nix flake update nixpkgs    # single input
```

After updating, run `nixos-rebuild dry-build --flake .#<host>` and report
the result. Do not switch.

---

## Wrapper Quick Reference

```nix
# Pre-built wrapper
inputs.wrapper-modules.wrappers.<n>.wrap { inherit pkgs; settings = {...}; }

# Import a shared wrapper module
inputs.wrapper-modules.wrappers.<n>.wrap { inherit pkgs; imports = [self.wrapperModules.<n>]; }

# Extend and vary
let base = inputs.wrapper-modules.wrappers.<n>.apply { inherit pkgs; imports = [...]; };
in { packages.a = base.wrapper; packages.b = (base.apply { opt = val; }).wrapper; }

# Ad-hoc environment wrapper
inputs.wrapper-modules.lib.wrapPackage { inherit pkgs; package = pkgs.<shell>; extraPackages = [...]; env = {...}; }

# Tiny inline script
pkgs.writeShellApplication { name = "..."; runtimeInputs = [...]; text = ''...''; }
```

Always use `lib.getExe` for executable paths.
Always check upstream docs before writing wrapper code.