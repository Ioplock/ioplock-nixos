{
  self,
  inputs,
  ...
}:
{
  flake.nixosModules.yazi =
    {
      pkgs,
      lib,
      ...
    }:
    let
      termfileChooser = pkgs.xdg-desktop-portal-termfilechooser;
      termfileChooserConfig = (pkgs.formats.ini { }).generate "termfilechooser-config" {
        filechooser = {
          cmd = "${termfileChooser}/share/xdg-desktop-portal-termfilechooser/yazi-wrapper.sh";
          create_help_file = "1";
          default_dir = "$HOME";
          env = "TERMCMD=${lib.getExe pkgs.ghostty} --title termfilechooser";
          open_mode = "suggested";
          save_mode = "suggested";
        };
      };
    in
    {
      programs.yazi = {
        enable = true;
      };

      environment.systemPackages = with pkgs; [
        zip
        unzip
        unrar
        rar
      ];

      environment.etc."xdg/xdg-desktop-portal-termfilechooser/config".source = termfileChooserConfig;

      xdg.mime.defaultApplications = {
        "inode/directory" = "yazi.desktop";
        "x-scheme-handler/file" = "yazi.desktop";
        "application/zip" = "yazi.desktop";
        "application/x-tar" = "yazi.desktop";
        "application/gzip" = "yazi.desktop";
        "application/x-bzip2" = "yazi.desktop";
        "application/x-7z-compressed" = "yazi.desktop";
        "application/x-rar" = "yazi.desktop";
        "application/x-xz" = "yazi.desktop";
        "application/zstd" = "yazi.desktop";
        "application/x-tgz" = "yazi.desktop";
        "application/x-tbz" = "yazi.desktop";
        "application/x-txz" = "yazi.desktop";
      };
    };
}
