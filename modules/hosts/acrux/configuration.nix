{ self, inputs, ... }: {

  flake.nixosModules.acruxConfiguration = { pkgs, ... }: {
    # import any other modules from here
    imports = [
      self.nixosModules.acruxHardware
      self.nixosModules.ssh
      self.nixosModules.shell
      self.nixosModules.niri
    ];

    # ==================================================
    # System
    # ==================================================
    nix.settings.experimental-features = [ "nix-command" "flakes" ];
    system.stateVersion = "25.05";

    environment.systemPackages = with pkgs; [
      home-manager
      docker
      docker-compose
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
      allowedTCPPorts = [ 22 5432 27017 80 8080 ]; # allow forwarded port
    };

    # ==================================================
    # Users
    # ==================================================
    # Define a user account. Don't forget to set a password with 'passwd'.
    users.users.ioplock = {
      isNormalUser = true;
      extraGroups = [ "wheel" "input" "networkmanager" "docker" ]; # Enable 'sudo' for the user.
      linger = true;
    };

    # ==================================================
    # Desktop
    # ==================================================
    # Enable touchpad support (enabled default in most desktopManager).
    services.libinput.enable = true;

    # ==================================================
    # Audio
    # ==================================================
    security.rtkit.enable = true;
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
    };

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
    services.blueman.enable = true; # TODO: Search for alternatives or make own shell (For future ref this is graphical interface for bluetooth)

    # ==================================================
    # Docker
    # ==================================================
    virtualisation.docker.rootless = { # TODO: Maybe replace with podman (https://github.com/vimjoyer/nixconf/blob/421795866265554d9ca5f2c7b658aac80d9ab0f9/nixos/hosts/main/configuration.nix#L59)
      enable = true;
      setSocketVariable = true; # exports DOCKER_HOST for you
    };
  };

}
