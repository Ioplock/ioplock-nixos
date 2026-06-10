{ self, inputs, ... }:
{
  flake.nixosModules.docker =
    { pkgs, ... }:
    {
      environment.systemPackages = with pkgs; [
        docker
        docker-compose
      ];

      virtualisation.docker.rootless = {
        enable = true;
        setSocketVariable = true;
      };
    };
}
