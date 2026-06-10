{ self, inputs, ... }:
{
  flake.nixosModules.ssh =
    { ... }:
    {
      # Allows VS Code Remote SSH to run its downloaded, non-NixOS server binaries.
      programs.nix-ld.enable = true;

      services.openssh = {
        enable = true;
        ports = [ 22 ];
      };
    };
}
