{ self, inputs, ... }: {
  flake.nixosModules.firefox = { pkgs, lib, ... }: let
    firefox = self.packages.${pkgs.stdenv.hostPlatform.system}.myFirefox;
  in {
    environment.systemPackages = [ firefox ];
    environment.sessionVariables.BROWSER = lib.getExe firefox;

    xdg.mime = {
      enable = true;
      defaultApplications = {
        "text/html" = "firefox.desktop";
        "x-scheme-handler/http" = "firefox.desktop";
        "x-scheme-handler/https" = "firefox.desktop";
      };
    };
  };

  perSystem = { pkgs, ... }: {
    packages.myFirefox = inputs.wrapper-modules.lib.wrapPackage {
      inherit pkgs;
      package = pkgs.firefox;
    };
  };
}
