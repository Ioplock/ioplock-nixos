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

        networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
      };
    };
}
