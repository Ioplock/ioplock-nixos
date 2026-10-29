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
        self.nixosModules.cursor
        self.nixosModules.docker
        self.nixosModules.firefox
        self.nixosModules.fonts
        self.nixosModules.git
        self.nixosModules.libreoffice
        self.nixosModules.memory
        self.nixosModules.micRelay
        self.nixosModules.nh
        self.nixosModules.obsidian
        self.nixosModules.opencode
        self.nixosModules.qbittorrent
        self.nixosModules.quickshell
        self.nixosModules.rofi
        self.nixosModules.singBox
        self.nixosModules.sops
        self.nixosModules.ssh
        self.nixosModules.user
        self.nixosModules.shell
        self.nixosModules.neovim
        self.nixosModules.niri
        self.nixosModules.vscode
        self.nixosModules.yazi
        self.nixosModules.zapret
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
      system.stateVersion = "25.05";

      environment.systemPackages = with pkgs; [
        home-manager
        moonlight-qt
      ];

      # ==================================================
      # Docker — rootless daemon (default mode), unchanged.
      # ==================================================
      myDocker = {
        enable = true;
      };

      # ==================================================
      # Boot
      # ==================================================
      # Use the systemd-boot EFI boot loader.
      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;

      # ==================================================
      # Memory / swap
      # ==================================================
      # Same protection as mimosa, scaled to this 7.2 GiB box: zram fast
      # tier + user.slice backstop from the shared memory feature. Disk
      # overflow lives in hardware.nix: /var/swapfile (16 GiB) + the
      # 1.9 GiB partition; sshd/system.slice floors come from the ssh
      # feature. Without this, Docker + Firefox + qBittorrent exhausted
      # RAM + the tiny 1.9 GiB partition and the whole box froze.
      myMemory = {
        enable = true;
        zramMemoryPercent = 25; # ~1.8 GiB zram device
        userSliceMemoryHigh = "6G"; # desktop session degrades instead of OOM, ~1.2 GiB left for system.slice
      };

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
      # Primary account, consumed by the user/niri/git features.
      myUser = {
        name = "ioplock";
        fullName = "Ioplock";
        email = "ioplock.me@gmail.com";
        extraGroups = [
          "wheel"
          "input"
          "video"
          "networkmanager"
          "docker"
        ]; # Enable 'sudo' for the user.
        linger = true;
      };

      programs.nh.flake = "/home/ioplock/nixconf";

      # ==================================================
      # Mic Relay — GUI client (mDNS discoverable, fallback 192.168.1.92:50051)
      # ==================================================
      myMicRelay = {
        enable = true;
        role = "client";
      };

      # ==================================================
      # qBittorrent — headless service, WebUI at localhost:8085
      # ==================================================
      myQbittorrent = {
        enable = true;
        openFirewall = true;
      };

      # ==================================================
      # Desktop
      # ==================================================
      # Enable touchpad support (enabled default in most desktopManager).
      services.libinput.enable = true;

      # mDNS browsing so Moonlight discovers Sunshine hosts advertised on the
      # LAN (mimosa advertises via avahi; a local responder is still required).
      services.avahi.enable = true;
      networking.firewall.allowedUDPPorts = [ 5353 ];

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
