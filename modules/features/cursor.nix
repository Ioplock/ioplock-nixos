{ self, inputs, ... }:
{
  # System-wide cursor theme. vanilla-dmz ships the DMZ-Black / DMZ-White /
  # Vanilla-DMZ cursor sets. Installed here it lands under
  # /run/current-system/sw/share/icons (already on XCURSOR_PATH), so niri and
  # other Wayland/X11 clients can find real arrow + hand images instead of
  # falling back to niri's hardcoded 64px default cursor (which renders large
  # and shows no hand shape on hover).
  #
  # TODO: migrate to stylix (as acrux's home-manager flake does with
  # stylix.cursor = { name = "DMZ-Black"; package = pkgs.vanilla-dmz; }) so
  # the cursor theme is centralized with the rest of the theming instead of a
  # hand-rolled NixOS module.
  flake.nixosModules.cursor =
    { pkgs, ... }:
    {
      environment.systemPackages = [
        pkgs.vanilla-dmz
      ];

      environment.sessionVariables = {
        XCURSOR_THEME = "DMZ-Black";
        XCURSOR_SIZE = "24";
      };
    };
}