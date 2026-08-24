{ self, inputs, ... }:
{

  flake.nixosModules.mimosaConfiguration =
    { pkgs, ... }:
    {
      # import any other modules from here
      imports = [
        self.nixosModules.mimosaHardware
        self.nixosModules.audio
        self.nixosModules.cliphist
        self.nixosModules.cursor
        self.nixosModules.docker
        self.nixosModules.firefox
        self.nixosModules.git
        self.nixosModules.monitoring
        self.nixosModules.nh
        self.nixosModules.niri
        self.nixosModules.opencode
        self.nixosModules.rofi
        self.nixosModules.shell
        self.nixosModules.singBox
        self.nixosModules.sops
        self.nixosModules.ssh
        self.nixosModules.steam
        self.nixosModules.sunshine
        self.nixosModules.user
        self.nixosModules.vscode
        self.nixosModules.yazi
      ];

      # ==================================================
      # System
      # ==================================================
      nixpkgs.config.allowUnfree = true;
      nix.settings = {
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        auto-optimise-store = true;
      };
      system.stateVersion = "26.05";

      # ==================================================
      # Boot
      # ==================================================
      # Use the systemd-boot EFI boot loader.
      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;

      # Headless-ready GPU: force-enable HDMI-A-1 and inject a 1920x1080@60
      # mode directly (kernelParams apply at boot — reboot to change). A
      # drm.edid_firmware reference is deliberately NOT used: nixpkgs kernels
      # do not ship the edid/*.bin blobs, and the failed load falls back to
      # the kernel's built-in stub EDID offering only 640x480. With a real
      # monitor attached its native EDID still takes precedence.
      boot.kernelParams = [
        "video=HDMI-A-1:1920x1080@60e"
      ];

      # ==================================================
      # Networking
      # ==================================================
      networking.hostName = "mimosa"; # Define your hostname.
      networking.networkmanager.enable = true; # Easiest to use and most distros use this by default.

      # Set your time zone.
      time.timeZone = "Europe/Moscow";

      # Firewall: server exposes SSH only.
      networking.firewall = {
        enable = true;
        allowedTCPPorts = [ 22 ];
      };

      # ==================================================
      # Users
      # ==================================================
      # Primary account, consumed by the user/git features.
      myUser = {
        name = "mimosa";
        fullName = "Ioplock";
        email = "ioplock.me@gmail.com";
        # input group grants write access to /dev/uinput for Sunshine's
        # virtual gamepads and other input injection.
        extraGroups = [
          "wheel"
          "input"
        ];
        authorizedKeys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO2reTQCZyP5XULzWNsQ0iVGxwYylpkW8xuK1hG+DaE9 ioplock.me@gmail.com"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGmxqTkkihZlO5FEriD9Xxp8do+3GbVxR7xsa9V/aHGE daniiilbackto2007@gmail.com"
        ];
      };

      programs.nh.flake = "/home/mimosa/nixconf";

      # ==================================================
      # Desktop (gaming niri: wallpaper only, no status bar)
      # ==================================================
      myNiri.package = self.packages.${pkgs.stdenv.hostPlatform.system}.myNiriGaming;

      # ==================================================
      # Video
      # ==================================================
      hardware.graphics = {
        enable = true;
        enable32Bit = true; # Required by Steam/Wine 32-bit games.
      };

      # ==================================================
      # SSH
      # ==================================================
      # Key-only login.
      services.openssh.settings.PasswordAuthentication = false;

      # ==================================================
      # Monitoring
      # ==================================================
      # Netdata UI reachable from the LAN on :19999 (smartd included).
      myMonitoring = {
        enable = true;
        openFirewall = true;
      };
    };

}
