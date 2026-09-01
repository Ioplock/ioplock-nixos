{ self, inputs, ... }:
{
  flake.nixosModules.micRelay =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.myMicRelay;
    in
    {
      options.myMicRelay = {
        enable = lib.mkEnableOption "LAN mic passthrough — headless server on mimosa, GUI clients elsewhere";

        role = lib.mkOption {
          type = lib.types.enum [
            "server"
            "client"
            "both"
          ];
          default = "client";
          description = "Which part to run on this host. `server` is headless (mimosa), `client` is GUI, `both` runs both.";
        };

        server = {
          port = lib.mkOption {
            type = lib.types.port;
            default = 50051;
            description = "TCP control port.";
          };
          audioPort = lib.mkOption {
            type = lib.types.port;
            default = 50052;
            description = "UDP audio port (Opus).";
          };
          sourceName = lib.mkOption {
            type = lib.types.str;
            default = "MicRelay";
            description = "PipeWire null-sink / virtual source name. Games see `<name>.monitor` as mic.";
          };
          openFirewall = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Open firewall for control + audio + mDNS.";
          };
          mdns = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Advertise via mDNS (_mic-relay._tcp).";
          };
          package = lib.mkOption {
            type = lib.types.package;
            default = self.packages.${pkgs.stdenv.hostPlatform.system}.myMicRelayServer;
            description = "Server package (headless).";
          };
        };

        client = {
          package = lib.mkOption {
            type = lib.types.package;
            default = self.packages.${pkgs.stdenv.hostPlatform.system}.myMicRelay;
            description = "Client package (GUI).";
          };
          autoStart = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Autostart client GUI on login (systemd user service).";
          };
        };
      };

      config = lib.mkIf cfg.enable (
        lib.mkMerge [
          (lib.mkIf (cfg.role == "server" || cfg.role == "both") {
            # Server runs as a user service so it inherits the user's PipeWire
            # socket (XDG_RUNTIME_DIR) and can create the virtual source.
            # On mimosa the user auto-logins via greetd+niri, so default.target
            # is reached without manual login. `linger` keeps it alive.
            systemd.user.services.mic-relay-server = {
              description = "mic-relay headless server — virtual mic + mDNS";
              after = [
                "pipewire.service"
                "network.target"
              ];
              wants = [ "pipewire.service" ];
              wantedBy = [ "default.target" ];
              path = with pkgs; [
                pipewire
                pulseaudio
              ];
              serviceConfig = {
                ExecStart = "${lib.getExe cfg.server.package} server --source-name ${cfg.server.sourceName} --port ${toString cfg.server.port} --audio-port ${toString cfg.server.audioPort}";
                Restart = "always";
                RestartSec = 3;
                Environment = [ "RUST_LOG=info" ];
              };
            };

            # Ensure lingering so the user service survives without an active session
            # (needed for headless mimosa after boot). Use mkDefault so host's explicit
            # myUser.linger = true/false is respected.
            myUser.linger = lib.mkDefault true;

            # CLI helper + pipewire tools for debugging virtual mic
            environment.systemPackages = with pkgs; [
              cfg.server.package
              pipewire
              pulseaudio
            ];

            services.avahi = lib.mkIf cfg.server.mdns {
              enable = true;
              publish.enable = true;
              publish.userServices = true;
              nssmdns4 = true;
              openFirewall = cfg.server.openFirewall;
            };

            networking.firewall = lib.mkIf cfg.server.openFirewall {
              allowedTCPPorts = [ cfg.server.port ];
              allowedUDPPorts = [
                cfg.server.audioPort
                5353
              ];
            };
          })

          (lib.mkIf (cfg.role == "client" || cfg.role == "both") {
            environment.systemPackages = with pkgs; [
              cfg.client.package
              pipewire
              pulseaudio
            ];

            systemd.user.services.mic-relay-client = lib.mkIf cfg.client.autoStart {
              description = "mic-relay GUI client";
              after = [ "graphical-session.target" ];
              partOf = [ "graphical-session.target" ];
              wantedBy = [ "graphical-session.target" ];
              serviceConfig = {
                ExecStart = "${lib.getExe cfg.client.package}";
                Restart = "on-failure";
              };
            };
          })
        ]
      );
    };

  perSystem =
    {
      pkgs,
      lib,
      self',
      ...
    }:
    let
      micRelaySrc = ../../pkgs/mic-relay;
      # Common native inputs for Rust + pkg-config
      nativeCommon = with pkgs; [ pkg-config ];
      # Server is headless: only needs opus + alsa if cpal is enabled. Keep minimal.
      # Client needs full GUI stack.
      guiBuildInputs = with pkgs; [
        alsa-lib
        opus
        libxkbcommon
        wayland
        libGL
        libx11
        libxrandr
        libxi
        libxcursor
        libxinerama
        libxcb
        vulkan-loader
      ];
      serverBuildInputs = with pkgs; [
        opus
        alsa-lib
      ];
    in
    {
      packages.myMicRelay = pkgs.rustPlatform.buildRustPackage {
        pname = "mic-relay";
        version = "0.1.0";
        src = micRelaySrc;
        cargoLock.lockFile = micRelaySrc + "/Cargo.lock";

        nativeBuildInputs = nativeCommon ++ [ pkgs.makeWrapper ];
        buildInputs = guiBuildInputs;
        doCheck = false;

        # Build full GUI + cli + server (default features = client,cli)
        # Explicitly pass features to ensure GUI is included; cargo respects default features.
        # We also enable server feature so the same binary can act as server if invoked with `server`.
        cargoBuildFlags = [
          "--features"
          "client,cli,server"
        ];

        # eframe/winit dlopen libwayland-client.so at runtime, so RPATH is not enough.
        # Wrap with LD_LIBRARY_PATH so `winit` can load wayland even when not in system PATH.
        postFixup = ''
          wrapProgram $out/bin/mic-relay \
            --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath guiBuildInputs}
        '';

        # eframe needs wayland-scanner etc at build time
        # pkg-config finds opus/alsa
        meta = {
          description = "mic-relay GUI client (also can run as server with `mic-relay server`)";
          mainProgram = "mic-relay";
        };
      };

      packages.myMicRelayServer = pkgs.rustPlatform.buildRustPackage {
        pname = "mic-relay-server";
        version = "0.1.0";
        src = micRelaySrc;
        cargoLock.lockFile = micRelaySrc + "/Cargo.lock";

        nativeBuildInputs = nativeCommon;
        buildInputs = serverBuildInputs;
        doCheck = false;

        cargoBuildFlags = [
          "--no-default-features"
          "--features"
          "server,cli"
        ];

        # Don't need GUI deps, so strip them; binary is smaller and doesn't pull wayland libs.
        meta = {
          description = "mic-relay headless server + ctl CLI (no GUI)";
          mainProgram = "mic-relay";
        };
      };

      # Windows cross via mingw — best-effort (Docker is reliable fallback).
      # Requires cmake for audiopus_sys (Opus) + policy workaround for CMake 4.
      # Opus C build defaults to -fstack-protector + _FORTIFY_SOURCE which under
      # mingw + rust -nodefaultlibs leaves __stack_chk_fail undefined; disable.
      packages.myMicRelayWindowsCross = pkgs.pkgsCross.mingwW64.rustPlatform.buildRustPackage {
        pname = "mic-relay-windows";
        version = "0.1.0";
        src = micRelaySrc;
        cargoLock.lockFile = micRelaySrc + "/Cargo.lock";
        nativeBuildInputs = nativeCommon ++ [ pkgs.cmake ];
        buildInputs = [ pkgs.pkgsCross.mingwW64.windows.pthreads ];
        # CMake 4 (Nixpkgs) dropped <3.5 compat; Opus CMakeLists is 2.8
        env.CMAKE_POLICY_VERSION_MINIMUM = "3.5";
        # Opus C stack protector/fortify leaves undefined __stack_chk_fail on mingw
        env.CFLAGS = "-O2 -fno-stack-protector -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0";
        env.CXXFLAGS = "-O2 -fno-stack-protector -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0";
        env.RUSTFLAGS = "-C link-arg=-lssp";
        cargoBuildFlags = [
          "--features"
          "client,cli"
          "--target"
          "x86_64-pc-windows-gnu"
        ];
        doCheck = false;
        meta.description = "mic-relay Windows GUI client (cross via mingw, best-effort; Docker is preferred)";
      };

      # Docker-based Windows builder — reliable fallback requested by user.
      # `nix run .#micRelayBuildWindows` will invoke docker locally to produce mic-relay.exe.
      packages.myMicRelayBuildWindows = pkgs.writeShellApplication {
        name = "mic-relay-build-windows";
        runtimeInputs = with pkgs; [
          docker
          coreutils
          bash
        ];
        text = ''
          set -euo pipefail
          SRC="''${1:-pkgs/mic-relay}"
          OUT="''${2:-result-win}"
          DOCKERFILE="''${3:-pkgs/mic-relay/Dockerfile.windows}"
          echo "[mic-relay] building Windows exe via Docker: $DOCKERFILE -> $OUT/mic-relay.exe"
          if [ ! -f "$DOCKERFILE" ]; then
            echo "Dockerfile not found: $DOCKERFILE" >&2
            exit 1
          fi
          # Build inside container and export artifact via --output
          # Requires Docker with BuildKit (default on NixOS docker rootless)
          docker build -f "$DOCKERFILE" -t mic-relay-windows-builder --build-arg SRC="$SRC" .
          # Create a temporary container to copy the exe out
          CID=$(docker create mic-relay-windows-builder)
          mkdir -p "$OUT"
          docker cp "$CID":/out/mic-relay.exe "$OUT"/mic-relay.exe || \
            docker cp "$CID":/mic-relay/target/x86_64-pc-windows-gnu/release/mic-relay.exe "$OUT"/mic-relay.exe
          docker rm "$CID" >/dev/null
          echo "[mic-relay] Windows exe at $OUT/mic-relay.exe — copy to Windows and run"
          ls -lh "$OUT"/mic-relay.exe
        '';
      };

      apps.micRelay = {
        type = "app";
        program = lib.getExe self'.packages.myMicRelay;
      };
      apps.micRelayServer = {
        type = "app";
        program = lib.getExe self'.packages.myMicRelayServer;
      };
      apps.micRelayBuildWindows = {
        type = "app";
        program = lib.getExe self'.packages.myMicRelayBuildWindows;
      };
    };
}
