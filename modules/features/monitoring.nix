{
  self,
  inputs,
  ...
}:
{
  flake.nixosModules.monitoring =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.myMonitoring;
    in
    {
      options.myMonitoring = {
        enable = lib.mkEnableOption "continuous monitoring (netdata metrics + smartd disk health)";

        openFirewall = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Open the netdata web UI port in the firewall for LAN access.
            Leave off to reach the UI through an SSH tunnel only.
          '';
        };

        port = lib.mkOption {
          type = lib.types.port;
          default = 19999;
          description = "Port the netdata web UI listens on.";
        };
      };

      config = lib.mkIf cfg.enable {
        # Single daemon collecting everything out of the box: CPU core/package
        # temperatures via hwmon, load, memory, disks, network, processes.
        # Metrics persist on disk (dbengine), so history survives restarts.
        services.netdata = {
          enable = true;
          # nixpkgs builds netdata without the dashboard UI by default
          # (withCloudUi, ncul1-licensed web assets), leaving the agent to
          # serve 404s on /. Opt into it — hosts using this feature must set
          # nixpkgs.config.allowUnfree = true. ML (dlib) is disabled: building
          # it OOM-crashed acrux, and anomaly detection is not needed for
          # temperature/load history.
          #
          # nixpkgs rewrites the vendored GOPROXY in both NetdataGoTools.cmake
          # and the root CMakeLists.txt (snmp-trap-profile-pack target) to a
          # local Go vendor dir since PR #559221 (2026-09-14) — no patching
          # needed here. Patching it ourselves would collide with nixpkgs'
          # --replace-fail and break the build.
          package = pkgs.netdata.override {
            withCloudUi = true;
            withML = false;
            # ndsudo is netdata's SUID-root exec helper (whitelisted commands
            # only). Needed so the built-in smartctl collector can read drive
            # SMART data; fed smartctl via extraNdsudoPackages below.
            withNdsudo = true;
          };
          # The NixOS module leaves the listen address at upstream default;
          # make LAN exposure explicit instead of relying on it.
          config."web" = {
            "bind to" = "*";
            "default port" = cfg.port;
          };
        };

        # SMART polling for every auto-detected drive: health status and
        # temperature, warnings logged to the journal.
        services.smartd.enable = true;

        # Put smartctl on ndsudo's PATH: activates netdata's smartctl
        # collector so drive temps/SMART attributes show up as dashboard
        # charts (smartd alone only logs to the journal).
        services.netdata.extraNdsudoPackages = [ pkgs.smartmontools ];

        networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
      };
    };
}
