{ inputs, ... }:
{
  imports = [
    inputs.wrapper-modules.flakeModules.default
  ];

  config = {
    systems = [
      "x86_64-linux"
      "aarch64-linux"
    ];

    perSystem =
      { system, ... }:
      {
        _module.args.pkgs = import inputs.nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
      };
  };
}
