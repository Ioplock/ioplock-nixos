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
      myQbtAdd = self.packages.${pkgs.stdenv.hostPlatform.system}.myQbtAdd;
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
          myQbtAdd
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
          # Hidden MIME handler: .torrent files and magnet: links open straight
          # into the local qBittorrent service via its WebUI API.
          (pkgs.makeDesktopItem {
            name = "qbittorrent-add";
            desktopName = "qBittorrent (add torrent)";
            comment = "Add a torrent or magnet link to the qBittorrent service";
            exec = "${lib.getExe myQbtAdd} -u http://127.0.0.1:${toString cfg.webuiPort} %U";
            icon = "${pkgs.qbittorrent}/share/icons/hicolor/scalable/apps/qbittorrent.svg";
            noDisplay = true;
            terminal = false;
            mimeTypes = [
              "application/x-bittorrent"
              "x-scheme-handler/magnet"
            ];
            categories = [
              "Network"
              "FileTransfer"
            ];
          })
        ];

        xdg.mime = {
          enable = true;
          defaultApplications = {
            "application/x-bittorrent" = "qbittorrent-add.desktop";
            "x-scheme-handler/magnet" = "qbittorrent-add.desktop";
          };
        };
      };
    };

  perSystem =
    { pkgs, ... }:
    {
      packages.myQbtAdd = pkgs.writeShellApplication {
        name = "my-qbt-add";
        meta.mainProgram = "my-qbt-add";
        runtimeInputs = with pkgs; [
          curl
          libnotify
        ];
        text = ''
          usage() {
            echo "usage: my-qbt-add [-u <webui-base-url>] <magnet-url|torrent-file|torrent-url>..." >&2
          }

          base="http://127.0.0.1:8085"
          while getopts "u:" opt; do
            case "$opt" in
              u)
                base="$OPTARG"
                ;;
              *)
                usage
                exit 2
                ;;
            esac
          done
          shift $((OPTIND - 1))

          if [ "$#" -lt 1 ]; then
            usage
            exit 2
          fi

          fail() {
            echo "$1" >&2
            notify-send -u critical "qBittorrent" "$1" 2>/dev/null || true
            exit 1
          }

          for target in "$@"; do
            path="''${target#file://}"
            if [ ! -f "$path" ]; then
              # Percent-encoded fallback (file:///home/user/My%20Files/x.torrent)
              printf -v decoded '%b' "''${path//%/\x}"
              if [ -f "$decoded" ]; then
                path="$decoded"
              fi
            fi

            if [ -f "$path" ]; then
              code=$(curl -sS -o /dev/null -w '%{http_code}' \
                -F "torrents=@''${path}" \
                "''${base}/api/v2/torrents/add") ||
                fail "Cannot reach the WebUI at ''${base}"
            else
              code=$(curl -sS -o /dev/null -w '%{http_code}' \
                --data-urlencode "urls=''${target}" \
                "''${base}/api/v2/torrents/add") ||
                fail "Cannot reach the WebUI at ''${base}"
            fi

            case "$code" in
              2??)
                notify-send "qBittorrent" "Added: ''${target}" 2>/dev/null || true
                ;;
              *)
                fail "Failed to add (HTTP ''${code}): ''${target}"
                ;;
            esac
          done
        '';
      };
    };
}
