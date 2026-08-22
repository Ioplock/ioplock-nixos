{ self, inputs, ... }:
{
  flake.nixosModules.ssh =
    { pkgs, ... }:
    {
      # Allows VS Code Remote SSH to run its downloaded, non-NixOS server binaries.
      programs.nix-ld.enable = true;

      # Clients running ghostty export TERM=xterm-ghostty over SSH; without
      # this terminfo every login shell prints "can't find terminal definition".
      environment.systemPackages = [ pkgs.ghostty.terminfo ];

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
