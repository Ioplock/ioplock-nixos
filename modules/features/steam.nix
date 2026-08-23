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
      };

      # Nested use only; capSysNice deliberately NOT set — the file
      # capability cannot be inherited inside Steam's pressure-vessel
      # sandbox ("failed to inherit capabilities") and kills gamescope
      # at launch when prefixed via %command%.
      programs.gamescope.enable = true;
    };
}
