{ self, inputs, ... }:
{
  flake.nixosModules.steam =
    { pkgs, ... }:
    {
      programs.steam = {
        enable = true;

        remotePlay.openFirewall = true;
        localNetworkGameTransfers.openFirewall = true;

        protontricks.enable = true;

        extraCompatPackages = with pkgs; [
          proton-ge-bin
        ];

        # SteamVR's first-run tool (vrstartup) is a Qt app that bundles only
        # the xcb platform plugin and aborts on a Wayland session before it
        # can register OpenVR paths ("could not load Qt platform plugin
        # wayland;xcb"). Route its Qt through xwayland-satellite instead.
        package = pkgs.steam.override {
          extraProfile = ''
            export QT_QPA_PLATFORM=xcb
          '';
        };
      };

      # Nested use only; capSysNice deliberately NOT set — the file
      # capability cannot be inherited inside Steam's pressure-vessel
      # sandbox ("failed to inherit capabilities") and kills gamescope
      # at launch when prefixed via %command%.
      programs.gamescope.enable = true;
    };
}
