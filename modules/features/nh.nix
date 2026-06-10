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
        flake = "${config.users.users.ioplock.home}/nixconf";
        package = self.packages.${pkgs.stdenv.hostPlatform.system}.myNh;
      };
    };

  perSystem =
    { pkgs, ... }:
    {
      packages.myNh = inputs.wrapper-modules.lib.wrapPackage {
        inherit pkgs;
        package = pkgs.nh;
      };
    };
}
