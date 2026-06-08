{ self, inputs, ... }: {
  flake.nixosModules.niri = { config, pkgs, lib, ... }:
  let
    niri = lib.getExe config.programs.niri.package;
    uwsm = lib.getExe config.programs.uwsm.package;
  in {
    programs.niri = {
      enable = true;
      package = self.packages.${pkgs.stdenv.hostPlatform.system}.myNiri;
    };

    programs.uwsm.enable = true;

    services.udev.packages = [ pkgs.brightnessctl ];

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
          command = "${uwsm} start -F -- ${niri} --session";
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

        input = {
          keyboard = {
            xkb = {
              layout = "us,ru";
              options = "grp:caps_toggle";
            };
            repeat-rate = 40;
            repeat-delay = 250;
          };

          touchpad = {
            natural-scroll = _: {};
            tap = _: {};
          };

          mouse.accel-profile = "flat";
        };

        layout = {
          gaps = 5;
          focus-ring = {
            width = 2;
            active-color = "#f77af5ff";
            inactive-color = "#3b4261";
          };
        };

        workspaces = {
          "w0" = _: {};
          "w1" = _: {};
          "w2" = _: {};
          "w3" = _: {};
          "w4" = _: {};
          "w5" = _: {};
          "w6" = _: {};
          "w7" = _: {};
          "w8" = _: {};
          "w9" = _: {};
        };

        binds = {
          "Mod+Return".spawn-sh = lib.getExe pkgs.ghostty;
          "Mod+Space".spawn-sh = "${lib.getExe self'.packages.myRofi} -show drun";
          "Mod+Q".close-window = _: {};

          "Mod+H".focus-column-left = _: {};
          "Mod+L".focus-column-right = _: {};
          "Mod+K".focus-window-up = _: {};
          "Mod+J".focus-window-down = _: {};

          "Mod+Shift+H".move-column-left = _: {};
          "Mod+Shift+L".move-column-right = _: {};
          "Mod+Shift+K".move-window-up = _: {};
          "Mod+Shift+J".move-window-down = _: {};

          "Mod+Ctrl+H".set-column-width = "-5%";
          "Mod+Ctrl+L".set-column-width = "+5%";
          "Mod+Ctrl+J".set-window-height = "-5%";
          "Mod+Ctrl+K".set-window-height = "+5%";

          "Mod+1".focus-workspace = "w0";
          "Mod+2".focus-workspace = "w1";
          "Mod+3".focus-workspace = "w2";
          "Mod+4".focus-workspace = "w3";
          "Mod+5".focus-workspace = "w4";
          "Mod+6".focus-workspace = "w5";
          "Mod+7".focus-workspace = "w6";
          "Mod+8".focus-workspace = "w7";
          "Mod+9".focus-workspace = "w8";
          "Mod+0".focus-workspace = "w9";

          "Mod+Shift+1".move-column-to-workspace = "w0";
          "Mod+Shift+2".move-column-to-workspace = "w1";
          "Mod+Shift+3".move-column-to-workspace = "w2";
          "Mod+Shift+4".move-column-to-workspace = "w3";
          "Mod+Shift+5".move-column-to-workspace = "w4";
          "Mod+Shift+6".move-column-to-workspace = "w5";
          "Mod+Shift+7".move-column-to-workspace = "w6";
          "Mod+Shift+8".move-column-to-workspace = "w7";
          "Mod+Shift+9".move-column-to-workspace = "w8";
          "Mod+Shift+0".move-column-to-workspace = "w9";

          "XF86AudioRaiseVolume".spawn-sh = "${lib.getExe' pkgs.wireplumber "wpctl"} set-volume -l 1.4 @DEFAULT_AUDIO_SINK@ 5%+";
          "XF86AudioLowerVolume".spawn-sh = "${lib.getExe' pkgs.wireplumber "wpctl"} set-volume -l 1.4 @DEFAULT_AUDIO_SINK@ 5%-";
          "XF86AudioMute".spawn-sh = "${lib.getExe' pkgs.wireplumber "wpctl"} set-mute @DEFAULT_AUDIO_SINK@ toggle";
          "XF86AudioMicMute".spawn-sh = "${lib.getExe' pkgs.wireplumber "wpctl"} set-mute @DEFAULT_AUDIO_SOURCE@ toggle";

          "Mod+bracketleft".spawn-sh = "${lib.getExe pkgs.brightnessctl} set 5%-";
          "Mod+bracketright".spawn-sh = "${lib.getExe pkgs.brightnessctl} set 5%+";
          # "Mod+S".spawn-sh = "${lib.getExe self'.packages.myNoctalia} ipc call launcher toggle";
        };
      };
    };
  };
}
