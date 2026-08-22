{ self, inputs, ... }:
{
  flake.nixosModules.sunshine =
    { config, ... }:
    {
      # Sunshine is a systemd *user* service bound to graphical-session.target,
      # which uwsm activates for the autologin niri session. KMS capture needs
      # CAP_SYS_ADMIN; the forced-EDID head provides the display.
      # Moonlight discovers hosts via mDNS; the upstream module enables
      # avahi advertisement but does not open the mDNS port itself.
      networking.firewall.allowedUDPPorts = [ 5353 ];

      services.sunshine = {
        enable = true;
        autoStart = true;
        capSysAdmin = true;
        openFirewall = true;

        settings = {
          # Exactly two keys: the NixOS module only passes the rendered config
          # file when more than one setting differs from defaults, and any
          # settings at all lock out web-UI configuration (declarative mode).
          sunshine_name = "mimosa";
          # Immutable flat JSON {username,password,salt}; password is uppercase
          # hex of SHA256(plaintext+salt). Pairing state lives separately in
          # ~/.config/sunshine/sunshine_state.json and survives forever.
          credentials_file = config.sops.secrets.sunshine-credentials.path;
        };
      };
    };
}
