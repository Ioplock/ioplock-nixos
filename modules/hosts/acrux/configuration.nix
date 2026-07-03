{ self, inputs, ... }:
{

  flake.nixosModules.acruxConfiguration =
    { pkgs, ... }:
    {
      # import any other modules from here
      imports = [
        self.nixosModules.acruxHardware
        self.nixosModules.audio
        self.nixosModules.ayugram
        self.nixosModules.cliphist
        self.nixosModules.docker
        self.nixosModules.firefox
        self.nixosModules.git
        self.nixosModules.nh
        self.nixosModules.quickshell
        self.nixosModules.rofi
        self.nixosModules.ssh
        self.nixosModules.shell
        self.nixosModules.niri
        self.nixosModules.vscode
        self.nixosModules.yazi
      ];

      # ==================================================
      # System
      # ==================================================
      nixpkgs.config.allowUnfree = true;
      nix.settings.experimental-features = [
        "nix-command"
        "flakes"
      ];
      system.stateVersion = "25.05";

      environment.systemPackages = with pkgs; [
        home-manager
      ];

      # ==================================================
      # Boot
      # ==================================================
      # Use the systemd-boot EFI boot loader.
      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;

      # ==================================================
      # Networking
      # ==================================================
      networking.hostName = "acrux"; # Define your hostname.
      networking.networkmanager.enable = true; # Easiest to use and most distros use this by default.

      # Set your time zone.
      time.timeZone = "Europe/Moscow";

      # Firewall
      networking.firewall = {
        enable = true;
        allowedTCPPorts = [
          22
          5432
          27017
          80
          8080
        ]; # allow forwarded port
      };

      # ==================================================
      # Users
      # ==================================================
      # Define a user account. Don't forget to set a password with 'passwd'.
      users.users.ioplock = {
        isNormalUser = true;
        extraGroups = [
          "wheel"
          "input"
          "video"
          "networkmanager"
          "docker"
        ]; # Enable 'sudo' for the user.
        linger = true;
      };

      # ==================================================
      # Desktop
      # ==================================================
      # Enable touchpad support (enabled default in most desktopManager).
      services.libinput.enable = true;

      # ==================================================
      # Video
      # ==================================================
      hardware.graphics = {
        enable = true;
        enable32Bit = true; # Highly recommended for gaming/Steam
      };

      # ==================================================
      # Bluetooth
      # ==================================================
      hardware.bluetooth.enable = true;
      hardware.bluetooth.powerOnBoot = false;
      # TODO: Replace Blueman with Bluetooth controls provided by a custom desktop shell.
      services.blueman.enable = true;
    };

}
