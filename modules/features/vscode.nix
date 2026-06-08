{ self, inputs, ... }: {
  flake.nixosModules.vscode = { pkgs, lib, ... }: {
    nixpkgs.config.allowUnfreePredicate = package: lib.getName package == "vscode";

    environment.systemPackages = [
      self.packages.${pkgs.stdenv.hostPlatform.system}.myVSCode
    ];
  };

  perSystem = { system, pkgs, lib, ... }: let
    vscodePkgs = import inputs.nixpkgs {
      inherit system;
      config.allowUnfreePredicate = package: lib.getName package == "vscode";
    };
  in {
    packages.myVSCode = inputs.wrapper-modules.lib.wrapPackage {
      pkgs = vscodePkgs;
      package = vscodePkgs.vscode;
    };
  };
}
