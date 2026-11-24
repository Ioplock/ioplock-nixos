{ self, inputs, ... }:
{
  flake.nixosModules.caratDeploy =
    { config
    , lib
    , pkgs
    , ...
    }:
    let
      cfg = config.myCaratDeploy;

      # Step 1 - runs as carat-ci, because this is the SSH forced command of
      # the deploy key. It cannot receive arguments (sshd never passes them),
      # so its only possible action is the sudo call below.
      signal = pkgs.writeShellApplication {
        name = "carat-deploy-signal";
        text = ''
          exec ${pkgs.sudo}/bin/sudo -n ${lib.getExe trigger}
        '';
      };

      # Step 2 - runs as root through the single NOPASSWD sudo rule. The rule
      # names exactly this store path, so no other command is reachable.
      trigger = pkgs.writeShellApplication {
        name = "carat-deploy-trigger";
        text = ''
          exec ${pkgs.systemd}/bin/systemctl start carat-deploy.service
        '';
      };

      # Step 3 - the deploy unit itself. Fixed working directory, fixed
      # compose file, no input from anywhere: pull the images GHCR calls
      # latest and recreate the stack.
      deployScript = pkgs.writeShellApplication {
        name = "carat-deploy";
        runtimeInputs = [ pkgs.docker-compose ];
        text = ''
          cd /etc/carat
          docker-compose --env-file .env -f docker-compose.yml pull
          docker-compose --env-file .env -f docker-compose.yml up -d --remove-orphans
          docker-compose --env-file .env -f docker-compose.yml ps
        '';
      };

      # Weekly disk reclamation. Images are the only unbounded part of the
      # stack's disk usage (data is capped by the loop filesystem below), and
      # every deploy of :latest strands the previous image.
      gcScript = pkgs.writeShellApplication {
        name = "carat-gc";
        runtimeInputs = [ pkgs.docker ];
        text = ''
          docker image prune --all --filter "until=168h" --force
          docker system df
        '';
      };
    in
    {
      options.myCaratDeploy = {
        enable = lib.mkEnableOption "restricted CI deploy hook: the CI key can only signal pull+restart";

        deployPublicKey = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = ''
            SSH public key of the CI deploy key. It is installed with
            restrict and a forced command: no shell, no pty, no forwarding,
            no arguments - a connection can only run the deploy signal.
          '';
        };

        memoryHigh = lib.mkOption {
          type = lib.types.str;
          default = "4G";
          description = ''
            MemoryHigh of carat.slice. Above this the stack is throttled and
            reclaim runs hard, but nothing is killed.
          '';
        };

        memoryMax = lib.mkOption {
          type = lib.types.str;
          default = "6G";
          description = ''
            MemoryMax of carat.slice: hard ceiling. The OOM killer acts on the
            stack instead of letting it eat the machine.
          '';
        };

        gcImages = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Weekly timer pruning container images no container has used for
            7 days (old :latest layers left behind by deploys).
          '';
        };
      };

      config = lib.mkIf cfg.enable {
        assertions = [
          {
            assertion = cfg.deployPublicKey != "";
            message = "myCaratDeploy.deployPublicKey must be set to the CI deploy public key.";
          }
        ];

        users.groups.carat-ci = { };

        users.users.carat-ci = {
          isSystemUser = true;
          group = "carat-ci";
          home = "/var/empty";
          createHome = false;
          # sshd executes the forced command as `shell -c <command>`, so a
          # real shell is required; `restrict` still forbids interactive
          # sessions, pty and any forwarding.
          shell = pkgs.bashInteractive;
          description = "CI deploy signal, forced command only";
          openssh.authorizedKeys.keys = [
            "restrict,command=\"${lib.getExe signal}\" ${cfg.deployPublicKey}"
          ];
        };

        # Exactly one command with an exact path and no arguments allowed:
        # carat-ci is not in wheel and not in the docker group, so this rule
        # is its entire privilege set.
        security.sudo.extraRules = [
          {
            users = [ "carat-ci" ];
            runAs = "root";
            commands = [
              {
                command = "${lib.getExe trigger} \"\"";
                options = [ "NOPASSWD" ];
              }
            ];
          }
        ];

        # Hard RAM ceiling for the whole stack. The compose services declare
        # cgroup_parent: carat.slice, so db, s3, migrate and backend all land
        # under this slice and share one budget.
        systemd.slices.carat = {
          description = "Carat compose stack - resource limits";
          sliceConfig = {
            MemoryHigh = cfg.memoryHigh;
            MemoryMax = cfg.memoryMax;
          };
        };

        # Hard disk ceiling for stack data: a fixed-size loop filesystem.
        # install.sh creates /var/lib/carat/data.img (10G default) and puts
        # the postgres and S3 data directories inside it, so the stack can
        # never grow past that file. nofail keeps boot clean before the image
        # exists; install.sh mounts it right after creating it.
        fileSystems."/var/lib/carat/data" = {
          device = "/var/lib/carat/data.img";
          fsType = "ext4";
          options = [
            "loop"
            "nofail"
            "noatime"
          ];
        };

        systemd.services.carat-gc = lib.mkIf cfg.gcImages {
          description = "Carat: prune container images unused for 7 days";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe gcScript;
          };
        };

        systemd.timers.carat-gc = lib.mkIf cfg.gcImages {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "weekly";
            Persistent = true;
            RandomizedDelaySec = "1h";
          };
        };

        systemd.services.carat-deploy = {
          description = "Carat stack: docker compose pull + up (CI signal only)";
          requires = [ "docker.service" ];
          after = [ "docker.service" ];
          serviceConfig = {
            Type = "oneshot";
            TimeoutStartSec = "15min";
            ExecStart = lib.getExe deployScript;
          };
        };
      };
    };
}
