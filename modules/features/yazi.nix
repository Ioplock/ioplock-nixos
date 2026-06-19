{
  self,
  inputs,
  ...
}:
{
  flake.nixosModules.yazi =
    { pkgs, ... }:
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
