# Architecture Overview

This configuration uses three interlocking tools to create a clean, dendritic NixOS flake:

| Tool | Purpose |
|---|---|
| [`flake-parts`](https://flake.parts) | Structures the flake output into composable modules |
| [`import-tree`](https://github.com/vic/import-tree) | Recursively auto-imports all `.nix` files under `modules/` |
| [`nix-wrapper-modules`](https://github.com/BirdeeHub/nix-wrapper-modules) | Wraps programs with typed Nix module-system settings; exposes `lib.wrapPackage` for ad-hoc wrapping |

Full docs: <https://birdeehub.github.io/nix-wrapper-modules/md/intro.html>

---

## The Dendritic Pattern

Every `.nix` file under `modules/` is a **flake-parts module**. They are auto-discovered by `import-tree` and merged into the final flake.

```
flake.nix
  └─ flake-parts (mkFlake)
       └─ import-tree ./modules
            ├─ parts.nix          ← flake-parts config (systems list, etc.)
            ├─ features/
            │    └─ niri.nix      ← flake.nixosModules.niri + perSystem packages
            └─ hosts/
                 └─ acrux/
                      ├─ default.nix        ← flake.nixosConfigurations.acrux
                      ├─ configuration.nix  ← flake.nixosModules.acruxConfiguration
                      └─ hardware.nix       ← flake.nixosModules.acruxHardware
```

### Key rule: modules talk via `self`, not relative paths

```nix
# ✅ Correct — resolve through self
imports = [
  self.nixosModules.acruxHardware
  self.nixosModules.niri
];

# ❌ Wrong — breaks the dendritic pattern
imports = [ ../hardware.nix ];
```

---

## Flake Output Namespaces

This configuration uses **three distinct output namespaces**. Never mix them up:

| Namespace | Type | Used for |
|---|---|---|
| `flake.nixosModules.*` | NixOS module | System-level config, imported via NixOS |
| `flake.wrappers.*` | Partially-evaluated wrapper module | Reusable wrapper configs, composed into package builds |
| `flake.wrapperModules.*` | Raw wrapper module (function) | Shared wrapper config fragments, imported via `imports = [...]` |

`flake.wrappers` and `flake.wrapperModules` are produced automatically by the
`wrapper-modules` flake-parts integration module. You define them under
`flake.wrappers.<name>` and both output forms are exposed for you.

---

## Module Anatomy

### flake-parts module (top level)

```nix
{ self, inputs, ... }: {
  # NixOS system-level configuration
  flake.nixosModules.myFeature = { pkgs, lib, ... }: { ... };

  # Reusable wrapper module definition
  flake.wrappers.myTool = { pkgs, wlib, lib, ... }: {
    imports = [ wlib.wrapperModules.myTool ];
    # typed settings...
  };

  # Per-system package builds
  perSystem = { pkgs, self', ... }: {
    packages.myTool = inputs.wrapper-modules.wrappers.myTool.wrap {
      inherit pkgs;
      imports = [ self.wrapperModules.myTool ];
    };
  };
}
```

Top-level arguments:

| Argument | What it is |
|---|---|
| `self` | Current flake outputs — use to cross-reference modules and packages |
| `inputs` | All flake inputs declared in `flake.nix` |
| `self'` (prime) | Current system's `perSystem` outputs — use to reference other `perSystem` packages |

### NixOS module (inner level)

```nix
{ pkgs, lib, config, modulesPath, ... }: {
  imports = [ ... ];
  options = { ... };
  config  = { ... };
}
```

---

## Host Layout

| File | Responsibility |
|---|---|
| `hardware.nix` | `flake.nixosModules.<host>Hardware` — generated, rarely hand-edited |
| `configuration.nix` | `flake.nixosModules.<host>Configuration` — imports hardware + features, all system settings |
| `default.nix` | `flake.nixosConfigurations.<host>` — thin assembly point only |

---

## Feature Layout

Features live under `modules/features/`. A feature:

1. Exposes a `flake.nixosModules.*` entry.
2. Optionally exposes `perSystem.packages.*` for built packages.
3. Optionally exposes `flake.wrappers.*` / `flake.wrapperModules.*` for reusable wrapper configs.
4. Is imported into a host via `self.nixosModules.<featureName>`.

---

## The Nix-Native Configuration Rule

**Never write program configuration as raw text strings dropped into the store.**
Every program must be configured through NixOS module options or through a
`wrapper-modules` wrapper.

Forbidden patterns:

```nix
# ❌ Raw string into /etc
environment.etc."app/config.toml".text = ''...'';

# ❌ XDG escape hatch
xdg.configFile."app/config.toml".text = ''...'';

# ❌ writeText / runCommand producing a config file
(pkgs.writeTextFile { name = "cfg"; text = ''...''; destination = "..."; })
```

Decision tree before configuring any program:

1. Does a `programs.<n>` or `services.<n>` NixOS module exist?
   → Check [search.nixos.org/options](https://search.nixos.org/options). Use it.
2. Does `nix-wrapper-modules` have a pre-built wrapper?
   → Check [birdeehub.github.io/nix-wrapper-modules](https://birdeehub.github.io/nix-wrapper-modules/md/getting-started.html). Use it.
3. Can `lib.wrapPackage` cover it?
   → Build an ad-hoc wrapper in `perSystem`. See below.
4. None of the above?
   → Write a proper NixOS module with typed `options`. Never paste a raw config string.

---

## wrapper-modules — Full Guide

Always check the upstream docs before writing any wrapper code:
<https://birdeehub.github.io/nix-wrapper-modules/md/getting-started.html>

### Pre-built wrapper (`.wrap`)

For programs that have a pre-built wrapper module in `nix-wrapper-modules`:

```nix
perSystem = { pkgs, lib, ... }: {
  packages.myNiri = inputs.wrapper-modules.wrappers.niri.wrap {
    inherit pkgs;
    settings = {
      input.keyboard.xkb.layout = "us,ru";
      layout.gaps = 5;
      xwayland-satellite.path = lib.getExe pkgs.xwayland-satellite;
      binds = {
        "Mod+Return".spawn-sh = lib.getExe pkgs.ghostty;
        "Mod+Q".close-window  = null;
      };
    };
  };
};
```

`settings` is fully typed and validated at eval time.

### Importing a shared wrapper module (`imports = [self.wrapperModules.*]`)

When a wrapper configuration should be reusable across multiple builds, define
it as `flake.wrappers.<n>` (which also exposes it as `flake.wrapperModules.<n>`),
then import it:

```nix
# Define the reusable wrapper config
{ self, inputs, ... }: {
  flake.wrappers.niri = { config, lib, pkgs, ... }: {
    imports = [ inputs.wrapper-modules.lib.wrapperModules.niri ];

    # Define custom options that callers can set
    options.terminal = lib.mkOption {
      type = lib.types.str;
      default = "ghostty";
    };

    config.settings = {
      binds."Mod+Return".spawn = config.terminal;
      layout.gaps = 5;
    };
  };
}

# Use it, overriding the terminal option at call site
{ self, inputs, ... }: {
  perSystem = { pkgs, self', ... }: {
    packages.myNiri = inputs.wrapper-modules.wrappers.niri.wrap {
      inherit pkgs;
      imports = [ self.wrapperModules.niri ];
      terminal = lib.getExe self'.packages.myTerminal;
    };
  };
}
```

### `.apply { ... }.wrapper` — extending an evaluated config

`.apply` extends an already-evaluated wrapper config and gives back an object
with `.wrapper` (the package), `.wrap`, `.apply`, and `.eval` available at
the top level. Useful when you need to build the same base wrapper multiple
times with small variations:

```nix
let
  base = inputs.wrapper-modules.wrappers.tmux.apply {
    inherit pkgs;
    imports = [ self.wrapperModules.tmux ];
  };
in {
  packages.myTmux        = base.wrapper;
  packages.myTmuxVi      = (base.apply { modeKeys = "vi"; }).wrapper;
}
```

### `lib.wrapPackage` — ad-hoc wrapping of any package

`lib.wrapPackage` wraps any arbitrary executable and extends its environment.
It includes `wlib.modules.default` automatically and returns the package
directly (no `.wrapper` needed).

This is the correct tool for creating an **environment package** — a shell
that carries all its tools with it:

```nix
perSystem = { pkgs, lib, self', ... }: {
  packages.myShellEnv = inputs.wrapper-modules.lib.wrapPackage {
    inherit pkgs;
    package = pkgs.zsh;              # the main executable being wrapped
    extraPackages = with pkgs; [     # added to PATH inside the wrapper
      fzf
      zoxide
      eza
      bat
      ripgrep
      fd
      starship
      lazygit
    ];
    env = {
      EDITOR = lib.getExe self'.packages.myNeovim;
    };
  };
};
```

`extraPackages` are injected into the wrapper script's PATH — they are not
installed globally, they travel with the wrapper derivation.

### `pkgs.writeShellApplication` — tiny inline scripts

For small helper scripts that do not need a full wrapper module:

```nix
packages.myHelper = pkgs.writeShellApplication {
  name = "my-helper";
  runtimeInputs = [ pkgs.jq pkgs.curl ];
  text = ''
    curl -s "$1" | jq .
  '';
};
```

Prefer `writeShellApplication` over `writeShellScriptBin` — it adds strict
bash options (`set -euo pipefail`) and handles `runtimeInputs` for you.

---

## Environment Packages — Layered Wrapped Environments

The wrapping system enables a **layered environment** pattern where each layer
is a `perSystem` package that composes the layer below it. The result is a
chain of derivations that each carry their dependencies with them — portable
across any machine without global installation.

### The layer chain

```
myDesktop   (niri wrapper — terminal=myTerminal)
  └─ myTerminal  (ghostty/kitty wrapper — shell=myShellEnv)
       └─ myShellEnv  (zsh/fish wrapper — extraPackages=[all tools])
```

Each layer is independent: a headless server can use only `myShellEnv`; a
desktop host can use `myDesktop` and gets the entire stack transitively.

### Shell environment layer (`lib.wrapPackage`)

```nix
perSystem = { pkgs, lib, self', ... }: {
  packages.myShellEnv = inputs.wrapper-modules.lib.wrapPackage {
    inherit pkgs;
    package = pkgs.zsh;
    extraPackages = with pkgs; [
      # nix tooling
      nil nixd alejandra
      # shell tools
      fzf zoxide eza bat ripgrep fd lazygit
    ];
    env.EDITOR = lib.getExe self'.packages.myNeovim;
  };
};
```

### Terminal layer (pre-built wrapper with `shell` option)

```nix
perSystem = { pkgs, lib, self', ... }: {
  packages.myTerminal = inputs.wrapper-modules.wrappers.ghostty.wrap {
    inherit pkgs;
    imports = [ self.wrapperModules.ghostty ];
    shell = lib.getExe self'.packages.myShellEnv;  # ← references the layer below
  };
};
```

### Desktop layer (niri wrapper with `terminal` option)

```nix
perSystem = { pkgs, lib, self', ... }: {
  packages.myDesktop = inputs.wrapper-modules.wrappers.niri.wrap {
    inherit pkgs;
    imports = [ self.wrapperModules.niri ];
    terminal = lib.getExe self'.packages.myTerminal;  # ← references the layer below
    env.EDITOR = lib.getExe self'.packages.myNeovim;
  };
};
```

### Using a layered environment in a host

```nix
# In configuration.nix — one line brings the entire stack
environment.systemPackages = [
  self.packages.${pkgs.stdenv.hostPlatform.system}.myDesktop
];
```

Or put the reference inside a feature module so any importing host gets the
full environment automatically.

### Rules for environment packages

- Always build in `perSystem`.
- Always reference lower layers via `self'.packages.*` (prime `'`) — this
  gives the current system's outputs.
- Reference the final package in NixOS modules via
  `self.packages.${pkgs.stdenv.hostPlatform.system}.*`.
- Use `lib.getExe` for all executable paths.
- Keep each layer in a descriptively-named `perSystem.packages.my<n>` entry.

---

## import-tree Behaviour

- **All files are always imported.** Guard conditional config with NixOS option
  toggles, not by placing/removing files.
- **File names don't matter** to the merge — only the attribute paths they
  write to (`flake.nixosModules.*`, `flake.wrappers.*`, etc.) matter.
- **Directory structure is purely organisational.**
- Avoid writing to the same attribute from two different files.