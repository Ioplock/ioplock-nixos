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
        hostKeys = [
          {
            type = "ed25519";
            path = "/etc/ssh/ssh_host_ed25519_key";
          }
        ];
      };
    };
}
