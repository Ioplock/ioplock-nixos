{ inputs, ... }:
{
  imports = [
    inputs.wrapper-modules.flakeModules.default
  ];

  config = {
    systems = [
      "x86_64-linux"
      "x86_64-darwin"
      "aarch64-linux"
      "aarch64-darwin"
    ];
  };
}
