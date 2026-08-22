{ self, inputs, ... }:
{

  flake.nixosModules.mimosaConfiguration =
    { pkgs, ... }:
    {
      # import any other modules from here
      imports = [
        self.nixosModules.mimosaHardware
        self.nixosModules.git
        self.nixosModules.nh
        self.nixosModules.shell
        self.nixosModules.ssh
        self.nixosModules.user
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
        authorizedKeys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO2reTQCZyP5XULzWNsQ0iVGxwYylpkW8xuK1hG+DaE9 ioplock.me@gmail.com"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGmxqTkkihZlO5FEriD9Xxp8do+3GbVxR7xsa9V/aHGE daniiilbackto2007@gmail.com"
        ];
      };

      programs.nh.flake = "/home/mimosa/nixconf";

      # ==================================================
      # SSH
      # ==================================================
      # Key-only login.
      services.openssh.settings.PasswordAuthentication = false;
    };

}
