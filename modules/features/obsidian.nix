{ self, inputs, ... }:
{
  flake.nixosModules.obsidian =
    { pkgs, ... }:
    {
      environment.systemPackages = [
        self.packages.${pkgs.stdenv.hostPlatform.system}.myObsidian
      ];
    };

  perSystem =
    { pkgs, ... }:
    {
      packages.myObsidian = inputs.wrapper-modules.lib.wrapPackage {
        inherit pkgs;
        package = pkgs.obsidian;
      };
    };
}
