{ self, inputs, ... }:
{
  flake.wrappers.quickshell =
    {
      config,
      lib,
      pkgs,
      wlib,
      ...
    }:
    {
      imports = [ wlib.modules.default ];

      options.configPath = lib.mkOption {
        type = lib.types.path;
        default = ./.;
        description = "Path to the Quickshell configuration directory.";
      };

      config = {
        package = pkgs.quickshell;
        binName = "quickshell-status-bar";
        flags."--path" = config.configPath;
      };
    };

  flake.nixosModules.quickshell =
    { pkgs, ... }:
    {
      environment.systemPackages = [
        self.packages.${pkgs.stdenv.hostPlatform.system}.myQuickshell
      ];

      # Needed for user `systemctl suspend/reboot/poweroff` from the power overlay.
      security.polkit.enable = true;

      # Don't let the physical power key bypass the overlay.
      services.logind.settings.Login.HandlePowerKey = "ignore";
    };

  perSystem =
    { pkgs, self', ... }:
    {
      packages.myQuickshellStatus = pkgs.writeShellApplication {
        name = "quickshell-status";
        runtimeInputs = with pkgs; [
          bluez
          coreutils
          gawk
          jq
          networkmanager
          niri
          systemd
          wireplumber
        ];
        text = builtins.readFile ./status.sh;
      };

      packages.myWallpaperList = pkgs.writeShellApplication {
        name = "list-wallpapers";
        runtimeInputs = with pkgs; [
          findutils
          gnused
        ];
        text = builtins.readFile ./list-wallpapers.sh;
      };

      packages.myToggleBluetooth = pkgs.writeShellApplication {
        name = "toggle-bluetooth";
        runtimeInputs = with pkgs; [
          bluez
          util-linux
        ];
        text = builtins.readFile ./toggle-bluetooth.sh;
      };

      packages.myQuickshell = inputs.wrapper-modules.lib.wrapPackage {
        inherit pkgs;
        imports = [ self.wrapperModules.quickshell ];
        configPath = ./.;
        extraPackages = [
          pkgs.coreutils
          pkgs.systemd
          self'.packages.myQuickshellStatus
          self'.packages.myWallpaperList
          self'.packages.myToggleBluetooth
          pkgs.networkmanager
          pkgs.niri
          pkgs.wireplumber
        ];
      };
    };
}
