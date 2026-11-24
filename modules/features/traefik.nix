{ self, inputs, ... }:
{
  flake.nixosModules.traefik =
    { config
    , lib
    , pkgs
    , ...
    }:
    let
      cfg = config.myTraefik;
    in
    {
      options.myTraefik = {
        enable = lib.mkEnableOption "Traefik reverse proxy with the Docker provider";

        openFirewall = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Open the web and websecure entrypoints (TCP 80 and 443) — plus the
            dashboard port when enabled — in the firewall.
          '';
        };

        dashboard = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Serve the Traefik dashboard via api.insecure on
            http://<host>:8080/dashboard/. LAN-only in practice: the router
            forwards ports 80/443 only, never 8080.
          '';
        };

        acmeEmail = lib.mkOption {
          type = lib.types.str;
          default = "ioplock.me@gmail.com";
          description = "Email used for the ACME (Let's Encrypt) account registration.";
        };

        exposedByDefault = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Pass-through for providers.docker.exposedByDefault. Keep false:
            containers are routed only when they carry the
            traefik.enable=true label.
          '';
        };

        dockerNetwork = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = ''
            Pass-through for providers.docker.network — a shared docker
            network used to reach containers. Empty picks each container's
            own network address; per-container override available via the
            traefik.docker.network label.
          '';
        };
      };

      config = lib.mkIf cfg.enable {
        assertions = [
          {
            # The traefik system user can only reach the docker API over the
            # rootful socket /run/docker.sock (docker group). The rootless
            # per-user socket /run/user/<uid>/docker.sock sits behind a 0700
            # /run/user/<uid> directory it can never traverse.
            assertion = config.virtualisation.docker.enable;
            message = "myTraefik requires rootful docker: set virtualisation.docker.enable = true (myDocker.mode = \"rootful\").";
          }
        ];

        services.traefik = {
          enable = true;
          # Docker provider needs the docker socket: traefik joins the
          # "docker" group created by the rootful docker module.
          group = "docker";

          staticConfigOptions = {
            entryPoints = {
              web = {
                address = ":80";
                # ACME HTTP-01 on web stays working: the internal ACME
                # challenge router has the highest priority and is
                # unaffected by this permanent redirect.
                http.redirections.entryPoint = {
                  to = "websecure";
                  scheme = "https";
                  permanent = true;
                };
              };
              websecure = {
                address = ":443";
                # Every router attached to websecure gets TLS with the
                # certificate resolved through ACME; the domain comes from
                # the router's Host() rule. Do not set a tls section on
                # compose routers — a router-level tls replaces (not
                # merges) this entrypoint default and loses the resolver.
                http.tls.certResolver = "letsencrypt";
              };
            };

            certificatesResolvers.letsencrypt.acme = {
              email = cfg.acmeEmail;
              storage = "${config.services.traefik.dataDir}/acme.json";
              # The router's Host() domain must resolve to this server and
              # port 80 must be reachable from the internet for this to work.
              httpChallenge.entryPoint = "web";
            };

            providers.docker = {
              exposedByDefault = cfg.exposedByDefault;
              watch = true;
              network = cfg.dockerNetwork;
            };
          } // lib.optionalAttrs cfg.dashboard { api.insecure = true; };
        };

        networking.firewall.allowedTCPPorts =
          lib.mkIf
            cfg.openFirewall
            ([ 80 443 ] ++ lib.optionals cfg.dashboard [ 8080 ]);
      };
    };
}
