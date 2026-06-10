{ self, inputs, ... }:
{
  flake.nixosConfigurations.acrux = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.nixosModules.acruxConfiguration
    ];
  };
}
