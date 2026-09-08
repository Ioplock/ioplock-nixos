{ self, inputs, ... }:
{
  flake.nixosModules.libreoffice =
    { pkgs, ... }:
    {
      environment.systemPackages =
        [
          self.packages.${pkgs.stdenv.hostPlatform.system}.myLibreoffice
        ]
        ++ (with pkgs; [
          # Spellcheck backend + dictionaries. Installed at system level
          # (not wrapper extraPackages) per the NixOS Wiki: LibreOffice
          # discovers them via the system share/hunspell paths.
          hunspell
          hunspellDicts.en_US
          hunspellDicts.ru_RU
        ]);

      xdg.mime = {
        enable = true;
        defaultApplications = {
          # Writer
          "application/msword" = "libreoffice-writer.desktop";
          "application/vnd.openxmlformats-officedocument.wordprocessingml.document" = "libreoffice-writer.desktop";
          "application/vnd.openxmlformats-officedocument.wordprocessingml.template" = "libreoffice-writer.desktop";
          "application/vnd.oasis.opendocument.text" = "libreoffice-writer.desktop";
          "application/vnd.oasis.opendocument.text-template" = "libreoffice-writer.desktop";
          "application/rtf" = "libreoffice-writer.desktop";
          "text/rtf" = "libreoffice-writer.desktop";
          # Calc
          "application/vnd.ms-excel" = "libreoffice-calc.desktop";
          "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" = "libreoffice-calc.desktop";
          "application/vnd.openxmlformats-officedocument.spreadsheetml.template" = "libreoffice-calc.desktop";
          "application/vnd.oasis.opendocument.spreadsheet" = "libreoffice-calc.desktop";
          "application/vnd.oasis.opendocument.spreadsheet-template" = "libreoffice-calc.desktop";
          "text/csv" = "libreoffice-calc.desktop";
          # Impress
          "application/vnd.ms-powerpoint" = "libreoffice-impress.desktop";
          "application/vnd.openxmlformats-officedocument.presentationml.presentation" = "libreoffice-impress.desktop";
          "application/vnd.openxmlformats-officedocument.presentationml.template" = "libreoffice-impress.desktop";
          "application/vnd.openxmlformats-officedocument.presentationml.slideshow" = "libreoffice-impress.desktop";
          "application/vnd.oasis.opendocument.presentation" = "libreoffice-impress.desktop";
          "application/vnd.oasis.opendocument.presentation-template" = "libreoffice-impress.desktop";
          # Draw
          "application/vnd.oasis.opendocument.graphics" = "libreoffice-draw.desktop";
          "application/vnd.oasis.opendocument.graphics-template" = "libreoffice-draw.desktop";
          "application/vnd.visio" = "libreoffice-draw.desktop";
        };
      };
    };

  perSystem =
    { pkgs, ... }:
    {
      packages.myLibreoffice = inputs.wrapper-modules.lib.wrapPackage {
        inherit pkgs;
        package = pkgs.libreoffice-qt;
      };
    };
}
