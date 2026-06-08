{ self, inputs, ... }: {
  flake.nixosModules.rofi = { pkgs, ... }: {
    environment.systemPackages = [
      self.packages.${pkgs.stdenv.hostPlatform.system}.myRofi
    ];
  };

  perSystem = { pkgs, ... }: let
    literal = value: {
      _type = "literal";
      inherit value;
    };
  in {
    packages.myRofi = inputs.wrapper-modules.wrappers.rofi.wrap {
      inherit pkgs;

      settings = {
        modi = "drun,run,window";
        show-icons = true;
        display-drun = "Applications";
        display-run = "Run";
        display-window = "Windows";
        drun-display-format = "{name}";
      };

      # TODO: Replace Rofi with launcher controls provided by a custom desktop shell.
      theme = {
        "*" = {
          background-color = "#1e1e2eff";
          text-color = "#cdd6f4ff";
        };
        window = {
          width = literal "42%";
          border = literal "2px";
          border-color = "#89b4faff";
          border-radius = literal "10px";
          padding = literal "12px";
        };
        inputbar = {
          children = [
            (literal "prompt")
            (literal "entry")
          ];
          spacing = literal "8px";
          padding = literal "8px";
        };
        listview = {
          lines = 8;
          spacing = literal "4px";
        };
        element = {
          padding = literal "8px";
          border-radius = literal "6px";
        };
        "element selected" = {
          background-color = "#313244ff";
          text-color = "#89b4faff";
        };
      };
    };
  };
}
