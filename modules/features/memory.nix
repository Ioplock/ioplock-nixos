{ self, inputs, ... }:
{
  flake.nixosModules.memory =
    {
      config,
      lib,
      ...
    }:
    let
      cfg = config.myMemory;
    in
    {
      options.myMemory = {
        enable = lib.mkEnableOption ''
          memory pressure protection: zram fast swap tier plus an optional
          MemoryHigh backstop on user.slice
        '';

        zramMemoryPercent = lib.mkOption {
          type = lib.types.ints.positive;
          default = 25;
          description = ''
            Percentage of total RAM the zram swap device may occupy
            (uncompressed upper bound — actual RAM use is lower once
            compression is factored in). 25 rather than the 50 default so
            the device does not eat too much of a small box.
          '';
        };

        userSliceMemoryHigh = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            MemoryHigh for user.slice, e.g. "6G" on an 8 GiB host or
            "15G" on a 16 GiB host. Last-resort backstop: if the user
            session (desktop + apps) exceeds the limit, apply reclaim
            pressure within user.slice only. MemoryHigh never kills —
            the session degrades instead of OOM — and system.slice
            (sshd, journald, Docker) stays out of the blast radius
            thanks to MemoryLow/MemoryMin set in the ssh feature.
            null disables the backstop.
          '';
        };
      };

      config = lib.mkIf cfg.enable {
        # Fast compressed swap tier, filled before disk swap (priority
        # 100 vs disk's 10/-2). Absorbs burst reclaim at RAM speed so
        # the multi-second freezes from pure disk-swap thrash get
        # shorter. Disk overflow is declared per host in hardware.nix
        # (swap partition and/or /var/swapfile).
        zramSwap = {
          enable = true;
          memoryPercent = cfg.zramMemoryPercent;
          priority = 100;
        };

        systemd.slices."user.slice".sliceConfig = lib.mkIf (cfg.userSliceMemoryHigh != null) {
          MemoryHigh = cfg.userSliceMemoryHigh;
        };
      };
    };
}
