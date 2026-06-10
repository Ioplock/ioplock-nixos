{
  self,
  inputs,
  ...
}:
{
  flake.nixosModules.nh =
    { config, pkgs, ... }:
    {
      programs.nh = {
        enable = true;
        package = self.packages.${pkgs.stdenv.hostPlatform.system}.myNh;
      };
    };

  perSystem =
    { pkgs, ... }:
    {
      packages.myNh = inputs.wrapper-modules.lib.wrapPackage {
        inherit pkgs;
        package = pkgs.nh;
        # TODO: Resolve issue with path to flake
      };
    };
}
