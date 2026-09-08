{ self, inputs, ... }:
{
  flake.nixosModules.fonts =
    { pkgs, ... }:
    {
      # Nerd Font glyphs for the quickshell status bar (settings gear, window,
      # keyboard, volume icons). Without it the bar renders tofu boxes on
      # hosts without an out-of-flake font source (mimosa had none; acrux
      # previously relied on a home-manager profile).
      fonts.packages = [
        pkgs.nerd-fonts.jetbrains-mono
        # MS-metric-compatible document fonts for LibreOffice/Office files.
        pkgs.liberation_ttf # Times/Arial/Courier clones
        pkgs.carlito # Calibri-metric clone
        pkgs.dejavu_fonts
        pkgs.noto-fonts
      ];
    };
}
