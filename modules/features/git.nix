{ self, inputs, ... }: {
  flake.wrappers.git = { wlib, ... }: {
    imports = [wlib.wrapperModules.git];

    settings = {
      user = {
        name = "Ioplock";
        email = "ioplock.me@gmail.com";
      };
    };
  };

  flake.nixosModules.git = {pkgs, ...}: {
    environment.systemPackages = [
      self.packages.${pkgs.stdenv.hostPlatform.system}.myGit
    ];
  };

  perSystem = {pkgs, ...}: {
    wrappers.packages.git = true;

    packages.myGit = inputs.wrapper-modules.wrappers.git.wrap {
      inherit pkgs;
      imports = [self.wrapperModules.git];
    };
  };
}
