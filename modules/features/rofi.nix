{ self, inputs, ... }:
{
  flake.nixosModules.rofi =
    { pkgs, ... }:
    {
      environment.systemPackages = [
        self.packages.${pkgs.stdenv.hostPlatform.system}.myRofi
      ];
    };

  perSystem =
    { pkgs, lib, ... }:
    let
      literal = value: {
        _type = "literal";
        inherit value;
      };
      background = literal "#1e1e2eff";
      surface = literal "#313244ff";
      text = literal "#cdd6f4ff";
      muted = literal "#a6adc8ff";
      accent = literal "#89b4faff";
      mkTheme =
        {
          iconSize ? null,
          lines ? 8,
        }:
        {
          "*" = {
            background-color = background;
            text-color = text;
          };
          window = {
            background-color = background;
            width = literal "42%";
            border = literal "2px";
            border-color = accent;
            border-radius = literal "10px";
            padding = literal "12px";
          };
          inputbar = {
            background-color = surface;
            text-color = text;
            children = [
              (literal "prompt")
              (literal "entry")
            ];
            spacing = literal "8px";
            padding = literal "8px";
          };
          listview = {
            inherit lines;
            spacing = literal "4px";
          };
          element = {
            background-color = background;
            text-color = text;
            padding = literal "8px";
            border-radius = literal "6px";
          };
          "element alternate.normal" = {
            background-color = surface;
            text-color = text;
          };
          "element selected.normal" = {
            background-color = accent;
            text-color = background;
          };
          "element-icon" = {
            background-color = literal "transparent";
          }
          // lib.optionalAttrs (iconSize != null) {
            size = literal iconSize;
          };
          "element-text" = {
            background-color = literal "transparent";
            text-color = literal "inherit";
          };
          prompt = {
            background-color = literal "transparent";
            text-color = accent;
          };
          entry = {
            background-color = literal "transparent";
            text-color = text;
          };
          "textbox-prompt-colon" = {
            background-color = literal "transparent";
            text-color = muted;
          };
        };
    in
    {
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
        theme = mkTheme { };
      };

      packages.myCliphistRofiPicker = inputs.wrapper-modules.wrappers.rofi.wrap {
        inherit pkgs;

        settings = {
          show-icons = false;
          matching = "fuzzy";
        };

        theme = mkTheme { };
      };
    };
}
