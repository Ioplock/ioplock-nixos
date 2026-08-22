{ self, inputs, ... }:
{
  flake.nixosModules.user =
    { config, lib, ... }:
    {
      options.myUser = lib.mkOption {
        description = "Primary user account for this host.";
        type = lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Login name of the primary user.";
            };
            fullName = lib.mkOption {
              type = lib.types.str;
              description = "Display name of the primary user, used as git user.name.";
            };
            email = lib.mkOption {
              type = lib.types.str;
              description = "Email address of the primary user, used as git user.email.";
            };
            extraGroups = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ "wheel" ];
              description = "Supplementary groups for the primary user.";
            };
            linger = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Start the user manager at boot, before login.";
            };
            authorizedKeys = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "SSH public keys authorized to log in as the primary user.";
            };
          };
        };
      };

      config.users.users.${config.myUser.name} = {
        isNormalUser = true;
        extraGroups = config.myUser.extraGroups;
        inherit (config.myUser) linger;
        openssh.authorizedKeys.keys = config.myUser.authorizedKeys;
      };
    };
}
