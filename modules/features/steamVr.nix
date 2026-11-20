{ self, inputs, ... }:
{
  flake.nixosModules.steamVr =
    { pkgs, lib, ... }:
    {
      systemd.user.services.steamvr-launcher-compat = {
        description = "SteamVR compatibility launcher for the SteamRT3 client";
        wantedBy = [ "graphical-session.target" ];
        partOf = [ "graphical-session.target" ];
        serviceConfig = {
          ExecStart = lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.mySteamVrLauncherCompat;
          Restart = "always";
          RestartSec = "2s";
        };
      };
    };

  perSystem =
    { pkgs, ... }:
    {
      packages.mySteamVrLauncherCompat = pkgs.writeShellApplication {
        name = "steamvr-launcher-compat";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.gawk
          pkgs.steam-run
          pkgs.systemd
        ];
        text = ''
          # SteamRT3 only owns an Instance<N> name, but SteamVR asks for the
          # unsuffixed name. Start the alias through Steam's own service so
          # it inherits the right runtime and exits with Steam.
          # https://github.com/ValveSoftware/SteamVR-for-Linux/issues/936
          pv="$HOME/.local/share/Steam/steamrt64/pv-runtime/steam-runtime-steamrt/pressure-vessel"
          bus_name=com.steampowered.PressureVessel.LaunchAlongsideSteam

          while true; do
            if [ -x "$pv/bin/steam-runtime-launch-client" ] &&
               ! busctl --user status "$bus_name" >/dev/null 2>&1; then
              instance=$(busctl --user list --no-legend --no-pager |
                awk -v prefix="$bus_name.Instance" 'index($1, prefix) == 1 && !found { print $1; found = 1 }')
              if [ -n "$instance" ]; then
                exec steam-run "$pv/bin/steam-runtime-launch-client" --bus-name="$instance" -- \
                  "$pv/libexec/steam-runtime-tools-0/x86_64-linux-gnu-srt-launcher-service" \
                  --alongside-steam --bus-name="$bus_name"
              fi
            fi
            sleep 2
          done
        '';
      };
    };
}
