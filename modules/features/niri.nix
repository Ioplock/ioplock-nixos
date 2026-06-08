{ self, inputs, ... }: {
  flake.nixosModules.niri = { config, pkgs, lib, ... }: {
    programs.niri = {
      enable = true;
      package = self.packages.${pkgs.stdenv.hostPlatform.system}.myNiri;
    };

    programs.uwsm.enable = true;

    environment.sessionVariables = {
      # Fix for Chromium/Electron apps (VS Code, Discord, etc.)
      NIXOS_OZONE_WL = "1";

      # Hardware acceleration for Firefox
      MOZ_ENABLE_WAYLAND = "1";

      # Force toolkit backend to Wayland
      GDK_BACKEND = "wayland,x11"; # GTK apps
      QT_QPA_PLATFORM = "wayland;xcb"; # Qt apps
      SDL_VIDEODRIVER = "wayland"; # Games and SDL apps
      CLUTTER_BACKEND = "wayland"; # Clutter apps

      # Java apps (like IntelliJ or older games)
      _JAVA_AWT_WM_NONREPARENTING = "1";
    };

    services.greetd = {
      enable = true;
      settings = rec {
        initial_session = {
          command = "${lib.getExe config.programs.uwsm.package} start -- niri.desktop";
          user = "ioplock";
        };
        default_session = initial_session;
      };
    };

  };

  perSystem = { pkgs, lib, self', ... }: {
    packages.myNiri = inputs.wrapper-modules.wrappers.niri.wrap {
      inherit pkgs;
      settings = {
        # spawn-at-startup = [
        #   (lib.getExe self'.packages.myNoctalia)
        # ];

        xwayland-satellite.path = lib.getExe pkgs.xwayland-satellite;

        input.keyboard.xkb.layout = "us,ru";

        layout.gaps = 5;

        binds = {
          "Mod+Return".spawn-sh = lib.getExe pkgs.ghostty;
          "Mod+Space".spawn-sh = "${lib.getExe self'.packages.myRofi} -show drun";
          "Mod+Q".close-window = _: {};
          # "Mod+S".spawn-sh = "${lib.getExe self'.packages.myNoctalia} ipc call launcher toggle";
        };
      };
    };
  };
}
