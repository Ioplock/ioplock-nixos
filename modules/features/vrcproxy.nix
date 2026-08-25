# vrcproxy — ad-hoc HTTPS inspection of VRChat traffic from this machine.
#
# Not a service: everything is run on demand and leaves only ~/.mitmproxy
# (the CA) behind. The tool drives mitmproxy scoped to VRChat domains only
# and toggles the Windows system proxy *inside VRChat's Proton prefix*,
# so no firewall rules are touched and no other application is affected.
#
# Usage:
#   nix run .#myVrcProxy               # alias for `serve`
#   nix run .#myVrcProxy -- trust      # install mitmproxy CA into the prefix
#   nix run .#myVrcProxy -- on         # point VRChat at the local proxy
#   nix run .#myVrcProxy -- off        # restore direct connectivity
#   nix run .#myVrcProxy -- status     # show current prefix proxy state
#
# Environment overrides: VRC_APPID, VRC_PROXY_PORT, VRC_WEB_PORT,
# VRC_PROXY_DUMP (path — records all intercepted flows to a .flows file).
{ self, inputs, ... }:
{
  perSystem =
    {
      pkgs,
      lib,
      self',
      ...
    }:
    {
      packages.myVrcProxy = pkgs.writeShellApplication {
        name = "vrc-proxy";

        runtimeInputs = with pkgs; [
          mitmproxy
          protontricks
          coreutils
          gnused
        ];

        text = ''
          cmd="''${1:-serve}"
          case "$cmd" in -h|--help|help) cmd=usage ;; esac

          appid="''${VRC_APPID:-438100}"
          port="''${VRC_PROXY_PORT:-8080}"
          web_port="''${VRC_WEB_PORT:-8081}"
          conf="$HOME/.mitmproxy"
          ca_cert="$conf/mitmproxy-ca-cert.cer"
          allow='.*\.vrchat\.(cloud|com)'
          reg_key='HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

          usage() {
            cat <<EOF
          vrc-proxy — inspect VRChat HTTPS traffic (read-only MITM)

            serve     start mitmweb scoped to *.vrchat.cloud / *.vrchat.com
            trust     import the mitmproxy CA into VRChat's Proton prefix
            on        route VRChat through the local proxy (prefix registry)
            off       remove the prefix proxy setting
            status    show the prefix's current proxy registry values

          Env: VRC_APPID=''${appid} VRC_PROXY_PORT=''${port} VRC_WEB_PORT=''${web_port}
               VRC_PROXY_DUMP=<path>  record intercepted flows to a file

          Order of operations:
            1. vrc-proxy serve        (keep running)
            2. vrc-proxy trust        (once per prefix recreation)
            3. vrc-proxy on           (launch VRChat via Steam)

          Only VRChat domains are decrypted; everything else passes through
          untouched, including EasyAnti-Cheat endpoints. Photon UDP traffic
          is never seen by this tool. Intercepting your own client is still
          modding-adjacent territory — observe, don't replay or fuzz.
          EOF
          }

          ensure_ca() {
            mkdir -p "$conf"
            if [ ! -f "$ca_cert" ]; then
              echo "generating mitmproxy CA in $conf ..."
              timeout 3s mitmdump --set "confdir=$conf" \
                --listen-port "$((port + 9))" >/dev/null 2>&1 || true
            fi
            if [ ! -f "$ca_cert" ]; then
              echo "error: CA generation failed" >&2
              exit 1
            fi
          }

          # Run a command inside the VRChat prefix. protontricks -c executes
          # on the host shell with the prefix's Wine environment set, and
          # every protontricks-specific flag must come BEFORE the appid.
          pt() {
            cmdline="$1"
            if ! protontricks --no-runtime -c "$cmdline" "$appid" 2>/dev/null; then
              protontricks -c "$cmdline" "$appid"
            fi
          }

          # /home/x/y -> Z:\\home\\x\\y (path visible from inside the prefix)
          win_path() {
            printf 'Z:%s' "''${1//\//\\}"
          }

          case "$cmd" in
            usage) usage ;;
            serve)
              ensure_ca
              echo "proxy : http://127.0.0.1:$port  (intercepting: $allow)"
              echo "ui    : http://127.0.0.1:$web_port"
              echo "CA    : $ca_cert"
              dump_args=()
              if [ -n "''${VRC_PROXY_DUMP:-}" ]; then
                mkdir -p "$(dirname "$VRC_PROXY_DUMP")"
                dump_args=(-w "$VRC_PROXY_DUMP")
                echo "dump  : $VRC_PROXY_DUMP"
              fi
              exec mitmweb \
                --set "confdir=$conf" \
                --listen-host 127.0.0.1 --listen-port "$port" \
                --web-host 127.0.0.1 --web-port "$web_port" \
                --set web_open_browser=false \
                --set "allow_hosts=$allow" \
                "''${dump_args[@]}"
              ;;
            trust)
              ensure_ca
              wp="$(win_path "$ca_cert")"
              echo "importing $wp into Root store of app $appid ..."
              pt "wine certutil -addstore -f Root '$wp'"
              echo "done. If VRChat was installed before importing, restart it."
              ;;
            on)
              pt "wine reg add '$reg_key' /v ProxyServer /t REG_SZ /d '127.0.0.1:$port' /f"
              pt "wine reg add '$reg_key' /v ProxyEnable /t REG_DWORD /d 1 /f"
              echo "VRChat prefix now proxies via 127.0.0.1:$port"
              ;;
            off)
              pt "wine reg add '$reg_key' /v ProxyEnable /t REG_DWORD /d 0 /f"
              echo "VRChat prefix proxy disabled"
              ;;
            status)
              pt "wine reg query '$reg_key' /v ProxyServer"
              pt "wine reg query '$reg_key' /v ProxyEnable"
              ;;
            *)
              usage
              echo "error: unknown command '$cmd'" >&2
              exit 1
              ;;
          esac
        '';
      };

      apps.myVrcProxy = {
        type = "app";
        program = lib.getExe self'.packages.myVrcProxy;
      };
    };
}
