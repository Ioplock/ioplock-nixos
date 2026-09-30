{ self, inputs, ... }:
{
  flake.nixosModules.qbittorrent =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.myQbittorrent;
    in
    {
      options.myQbittorrent = {
        enable = lib.mkEnableOption "qBittorrent headless service (WebUI) with a desktop launcher entry";

        webuiPort = lib.mkOption {
          type = lib.types.port;
          default = 8085;
          description = "TCP port the WebUI listens on.";
        };

        torrentingPort = lib.mkOption {
          type = lib.types.port;
          default = 51413;
          description = "Peer listening port — TCP for peers, UDP for DHT/uTP.";
        };

        openFirewall = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Open the WebUI port and torrenting port over TCP, and the
            torrenting port over UDP (DHT/uTP), in the firewall.
          '';
        };

        downloadsDir = lib.mkOption {
          type = lib.types.path;
          default = "/var/lib/qBittorrent/Downloads";
          description = ''
            Default save path for torrents. The service user has no usable
            home directory ($HOME=/var/empty, ProtectHome=yes), so the
            qBittorrent default of $HOME/Downloads is not writable.
          '';
        };
      };

      config = lib.mkIf cfg.enable {
        services.qbittorrent = {
          enable = true;
          webuiPort = cfg.webuiPort;
          torrentingPort = cfg.torrentingPort;
          inherit (cfg) openFirewall;
          # qBittorrent 5.x refuses to start until the legal notice is
          # accepted; this is the non-interactive acceptance.
          extraArgs = [ "--confirm-legal-notice" ];
          serverConfig = {
            "BitTorrent"."Session".DefaultSavePath = cfg.downloadsDir;
            # Passwordless WebUI access from this machine only (launcher
            # entry opens localhost). Remote access still requires auth;
            # a temporary password is printed to the service journal at
            # each start since no password is committed to this repo.
            "Preferences"."WebUI".LocalHostAuth = false;
          };
        };

        # The upstream module only opens TCP; DHT/uTP need UDP as well.
        networking.firewall.allowedUDPPorts = lib.mkIf cfg.openFirewall [ cfg.torrentingPort ];

        systemd.tmpfiles.settings.qbittorrent-downloads."${cfg.downloadsDir}"."d" = {
          mode = "755";
          inherit (config.services.qbittorrent) user group;
        };

        environment.systemPackages = [
          pkgs.xdg-utils
          (pkgs.makeDesktopItem {
            name = "qbittorrent-webui";
            desktopName = "qBittorrent WebUI";
            comment = "Open the qBittorrent WebUI in the browser";
            exec = "${lib.getExe' pkgs.xdg-utils "xdg-open"} http://localhost:${toString cfg.webuiPort}";
            icon = "${pkgs.qbittorrent}/share/icons/hicolor/scalable/apps/qbittorrent.svg";
            categories = [
              "Network"
              "FileTransfer"
            ];
          })
        ];
      };
    };
}
