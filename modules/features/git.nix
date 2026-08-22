{ self, inputs, ... }:
{
  flake.wrappers.git =
    { wlib, ... }:
    {
      imports = [ wlib.wrapperModules.git ];
    };

  flake.nixosModules.git =
    { config, pkgs, ... }:
    {
      environment.systemPackages = [
        self.packages.${pkgs.stdenv.hostPlatform.system}.myGit
      ];

      # Identity lives in /etc/gitconfig (system scope). The wrapped git's
      # GIT_CONFIG_GLOBAL only replaces the global scope, so this resolves
      # per-host even inside the wrapper.
      programs.git = {
        enable = true;
        config.user = {
          name = config.myUser.fullName;
          email = config.myUser.email;
        };
      };
    };

  perSystem =
    { pkgs, ... }:
    {
      wrappers.packages.git = true;

      packages.myGit = inputs.wrapper-modules.wrappers.git.wrap {
        inherit pkgs;
        imports = [ self.wrapperModules.git ];
      };
    };
}
