{ self, inputs, ... }:
{
  flake.nixosModules.youtrack =
    {
      config,
      lib,
      ...
    }:
    let
      cfg = config.myYoutrack;
    in
    {
      options.myYoutrack = {
        enable = lib.mkEnableOption "YouTrack issue tracker (native services.youtrack, routed through Traefik when it is enabled)";

        domain = lib.mkOption {
          type = lib.types.str;
          default = "youtrack.ioplock.su";
          description = ''
            Public hostname. Drives the Traefik Host() router rule and
            the YouTrack base-url (links in notifications, etc.).
          '';
        };

        port = lib.mkOption {
          type = lib.types.port;
          default = 8081;
          description = ''
            Local TCP port YouTrack listens on. Never published in the
            firewall — Traefik reaches it over loopback. 8081 avoids the
            Traefik dashboard on 8080.
          '';
        };

        listenAddress = lib.mkOption {
          type = lib.types.str;
          default = "127.0.0.1";
          description = ''
            Interface YouTrack binds to. Keep the loopback default:
            only Traefik needs to reach the service.
          '';
        };

        jvmHeap = lib.mkOption {
          type = lib.types.str;
          default = "768m";
          description = ''
            JVM maximum heap (-Xmx). Total process RSS runs higher
            (metaspace, thread stacks); pair with memoryMax.
          '';
        };

        memoryMax = lib.mkOption {
          type = lib.types.str;
          default = "1G";
          description = ''
            Hard systemd memory cap (MemoryMax/MemoryHigh) for the
            YouTrack JVM. Minimal profile: raise both this and jvmHeap
            if the service gets OOM-killed on large projects or during
            upgrades (journalctl -u youtrack).
          '';
        };
      };

      config = lib.mkIf cfg.enable {
        services.youtrack = {
          enable = true;
          # virtualHost stays null: nginx is not used, Traefik is the edge.
          environmentalParameters = {
            listen-address = cfg.listenAddress;
            listen-port = cfg.port;
            base-url = "https://${cfg.domain}";
          };
          # Merges (list concat) with the upstream module's own
          # -Ddisable.configuration.wizard.on.upgrade entry.
          generalParameters = [ "-Xmx${cfg.jvmHeap}" ];
        };

        systemd.services.youtrack.serviceConfig = {
          MemoryMax = cfg.memoryMax;
          MemoryHigh = cfg.memoryMax;
        };

        # Traefik route for a non-container upstream: the file provider
        # (dynamicConfigOptions) is merged into the same static config as
        # the Docker provider set up by myTraefik, so compose stacks keep
        # working unchanged. No router-level tls section — the websecure
        # entrypoint default already attaches the ACME resolver.
        services.traefik.dynamicConfigOptions = lib.mkIf config.services.traefik.enable {
          http.routers.youtrack = {
            rule = "Host(`${cfg.domain}`)";
            entrypoints = [ "websecure" ];
            service = "youtrack";
          };
          http.services.youtrack.loadBalancer.servers = [
            { url = "http://${cfg.listenAddress}:${toString cfg.port}"; }
          ];
        };
      };
    };
}
