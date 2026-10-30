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
        self.nixosModules.fonts
        self.nixosModules.git
        self.nixosModules.memory
        self.nixosModules.micRelay
        self.nixosModules.modioSplit
        self.nixosModules.monitoring
        self.nixosModules.nh
        self.nixosModules.niri
        self.nixosModules.opencode
        self.nixosModules.qbittorrent
        self.nixosModules.quickshell
        self.nixosModules.rofi
        self.nixosModules.shell
        self.nixosModules.neovim
        self.nixosModules.singBox
        self.nixosModules.sops
        self.nixosModules.traefik
        self.nixosModules.ssh
        self.nixosModules.steam
        self.nixosModules.sunshine
        self.nixosModules.user
        self.nixosModules.vscode
        self.nixosModules.yazi
        self.nixosModules.youtrack
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
      # Memory / swap
      # ==================================================
      # zram fast tier + user.slice backstop come from the shared
      # memory feature (modules/features/memory.nix). Disk overflow
      # lives in hardware.nix: /var/swapfile (32 GiB) + the 8 GiB
      # partition; sshd/system.slice floors come from the ssh feature.
      myMemory = {
        enable = true;
        zramMemoryPercent = 25; # ~4 GiB zram device (~1–2 GiB actual RAM when well compressed)
        userSliceMemoryHigh = "15G"; # game + Steam + desktop session degrades instead of OOM
      };

      # ==================================================
      # Networking
      # ==================================================
      networking.hostName = "mimosa"; # Define your hostname.
      networking.networkmanager.enable = true; # Easiest to use and most distros use this by default.

      # Set your time zone.
      time.timeZone = "Europe/Moscow";

      # Firewall: SSH for management; TCP 80/443 and the 8080 dashboard are
      # opened by myTraefik.openFirewall (80/443 are forwarded from the
      # router; 8080 stays LAN-only).
      networking.firewall = {
        enable = true;
        allowedTCPPorts = [ 22 ];
        allowedUDPPortRanges = [
          {
            from = 17780;
            to = 17785;
          }
        ];
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
          "docker"
        ];
        authorizedKeys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO2reTQCZyP5XULzWNsQ0iVGxwYylpkW8xuK1hG+DaE9 ioplock.me@gmail.com"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGmxqTkkihZlO5FEriD9Xxp8do+3GbVxR7xsa9V/aHGE daniiilbackto2007@gmail.com"
        ];
      };

      programs.nh.flake = "/home/mimosa/nixconf";

      # ==================================================
      # Desktop (gaming niri: compact status bar — clock, layout, volume,
      # workspace, focused window, settings; no wifi/bluetooth/battery)
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
      # Mic Relay — headless server, mDNS discoverable
      # ==================================================
      myMicRelay = {
        enable = true;
        role = "server";
        server = {
          openFirewall = true;
          mdns = true;
        };
      };

      # ==================================================
      # qBittorrent — headless service, WebUI at localhost:8085
      # ==================================================
      myQbittorrent = {
        enable = true;
        openFirewall = true;
      };

      # ==================================================
      # Docker — rootful, so the system-level Traefik service can
      # use /run/docker.sock (see myTraefik below).
      # ==================================================
      # The user needs the docker group to run compose without sudo.
      # After switching from rootless docker, existing compose stacks
      # must be brought up again against the system daemon.
      myDocker = {
        enable = true;
        mode = "rootful";
      };

      # ==================================================
      # Traefik — system reverse proxy in front of docker compose stacks.
      # Exposes any stack carrying traefik.enable=true labels; issues
      # Let's Encrypt certificates automatically for the routers' Host()
      # domains (HTTP-01 over port 80).
      # ==================================================
      myTraefik = {
        enable = true;
        openFirewall = true;
        dashboard = true;
      };

      # ==================================================
      # YouTrack — native services.youtrack (NOT Docker).
      # The nixpkgs package builds from the jetbrains/youtrack
      # image via a Nix fixed-output fetch, so no docker pull
      # is involved. Traefik routes youtrack.ioplock.su to the
      # loopback port when myTraefik (services.traefik) is on.
      # Minimal profile: 768m heap, 1G cgroup cap — raise the
      # myYoutrack.jvmHeap / myYoutrack.memoryMax overrides
      # here if the service gets OOM-killed.
      # ==================================================
      myYoutrack.enable = true;

      # ==================================================
      # mod.io split-routing — TUN for TF3 Mod Center (Proton ignores proxy)
      # ==================================================
      # Requires singBox+sops (imported above). Only mod.io/modapi.io/modcdn
      # go through `proxy`; remaining TUN traffic stays `direct`.
      myModioSplit.enable = true;

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
