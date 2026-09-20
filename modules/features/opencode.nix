{ self, inputs, ... }:
{
  flake.wrappers.opencode =
    {
      wlib,
      lib,
      config,
      ...
    }:
    {
      imports = [ wlib.wrapperModules.opencode ];

      options.openComputerUseCommand = lib.mkOption {
        type = lib.types.str;
        default = "open-computer-use";
        description = "Executable for the open-computer-use MCP server. Overridden per-system with an absolute store path.";
      };

      # NOTE: explicit `config.` prefix is required once a custom `options`
      # entry exists (wrapper-modules transposition rule).
      config.settings = {
        provider.openrouter.models."deepseek/deepseek-v4-flash-0731" = {
          name = "DeepSeek V4 Flash (max)";
          reasoningEffort = "max";
        };

        mcp.context7 = {
          type = "remote";
          url = "https://mcp.context7.com/mcp";
        };

        mcp."open-computer-use" = {
          type = "local";
          command = [
            config.openComputerUseCommand
            "mcp"
          ];
          enabled = true;
        };
      };
    };

  flake.nixosModules.opencode =
    { pkgs, ... }:
    {
      environment.systemPackages = [
        self.packages.${pkgs.stdenv.hostPlatform.system}.myOpencode
        self.packages.${pkgs.stdenv.hostPlatform.system}.myOpenComputerUse
        pkgs.mcp-nixos
      ];
    };

  perSystem =
    {
      pkgs,
      lib,
      self',
      ...
    }:
    {
      wrappers.packages.opencode = true;

      # open-computer-use is not in nixpkgs. The published npm tarball ships
      # a statically-linked Go binary per OS/arch plus dependency-free Node
      # launcher scripts (postinstall only prints help), so a plain
      # stdenv derivation suffices — no buildNpmPackage needed.
      packages.myOpenComputerUse =
        let
          version = "0.3.5";
          pythonGi = pkgs.python3.withPackages (ps: [ ps.pygobject3 ]);
        in
        pkgs.stdenv.mkDerivation {
          pname = "open-computer-use";
          inherit version;
          src = pkgs.fetchurl {
            url = "https://registry.npmjs.org/open-computer-use/-/open-computer-use-${version}.tgz";
            hash = "sha512-KKRY42by3yR+XPJiu6tk9wCn6lp0Y/dh1i8ap2SpW45hNSTej/hTPy1uquOLn/E4wF9hvPgProxmrsNj2FdpjQ==";
          };
          sourceRoot = "package";

          nativeBuildInputs = [ pkgs.makeWrapper ];

          dontBuild = true;

          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin $out/lib/open-computer-use
            cp -r bin dist package.json README.md LICENSE $out/lib/open-computer-use/
            chmod +x $out/lib/open-computer-use/dist/linux/*/open-computer-use

            # The Linux runtime embeds a Python AT-SPI bridge (requires
            # Atspi typelib, Gdk optional for screenshots) and expects
            # `python3` on PATH. A desktop session (XDG_RUNTIME_DIR,
            # DBUS_SESSION_BUS_ADDRESS) is required at runtime.
            for bin in open-computer-use ocu open-computer-use-mcp open-codex-computer-use-mcp; do
              makeWrapper ${lib.getExe pkgs.nodejs_24} $out/bin/$bin \
                --add-flags $out/lib/open-computer-use/bin/$bin \
                --prefix PATH : ${lib.makeBinPath [ pythonGi ]} \
                --prefix GI_TYPELIB_PATH : ${
                  lib.makeSearchPathOutput "lib" "lib/girepository-1.0" [
                    pkgs.gobject-introspection
                    pkgs.at-spi2-core
                    pkgs.gtk3
                  ]
                } \
                --prefix LD_LIBRARY_PATH : ${
                  lib.makeLibraryPath [
                    pkgs.at-spi2-core
                    pkgs.gtk3
                    pkgs.glib
                  ]
                }
            done
            runHook postInstall
          '';

          meta = {
            description = "Open-source Computer Use MCP server (open Codex Computer Use alternative)";
            homepage = "https://github.com/iFurySt/open-codex-computer-use";
            license = lib.licenses.mit;
            platforms = [
              "x86_64-linux"
              "aarch64-linux"
            ];
            mainProgram = "open-computer-use";
          };
        };

      packages.myOpencode = inputs.wrapper-modules.wrappers.opencode.wrap {
        inherit pkgs;
        imports = [ self.wrapperModules.opencode ];
        openComputerUseCommand = lib.getExe self'.packages.myOpenComputerUse;
      };

      packages.myOpencodeProxy = inputs.wrapper-modules.wrappers.opencode.wrap {
        inherit pkgs;
        imports = [ self.wrapperModules.opencode ];
        binName = "opencode-proxy";
        openComputerUseCommand = lib.getExe self'.packages.myOpenComputerUse;
        env = {
          HTTP_PROXY = "http://127.0.0.1:1080";
          HTTPS_PROXY = "http://127.0.0.1:1080";
          ALL_PROXY = "socks5://127.0.0.1:1080";
        };
      };
    };
}
