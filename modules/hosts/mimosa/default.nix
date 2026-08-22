{ self, inputs, ... }:
{
  flake.nixosConfigurations.mimosa = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.nixosModules.mimosaConfiguration
    ];
  };
}
