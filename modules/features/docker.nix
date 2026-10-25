{ self, inputs, ... }:
{
  flake.nixosModules.docker =
    { config
    , lib
    , pkgs
    , ...
    }:
    let
      cfg = config.myDocker;
    in
    {
      options.myDocker = {
        enable = lib.mkEnableOption "docker engine";

        mode = lib.mkOption {
          type = lib.types.enum [
            "rootless"
            "rootful"
          ];
          default = "rootless";
          description = ''
            rootless: per-user daemon over systemd user units, socket at
            /run/user/<uid>/docker.sock (DOCKER_HOST preset via
            setSocketVariable). rootful: system daemon, socket at
            /run/docker.sock with the docker group — the mode required by
            the myTraefik feature.
          '';
        };
      };

      config = lib.mkIf cfg.enable {
        environment.systemPackages = with pkgs; [
          docker
          docker-compose
        ];

        # Rootful: system daemon exposing /run/docker.sock to the docker group.
        virtualisation.docker.enable = cfg.mode == "rootful";

        # Rootless: user-units daemon, exactly the previous behaviour.
        virtualisation.docker.rootless = lib.mkIf (cfg.mode == "rootless") {
          enable = true;
          setSocketVariable = true;
        };
      };
    };
}
