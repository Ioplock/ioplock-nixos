{ self, inputs, ... }:
{
  flake.nixosModules.wivrn =
    { config, ... }:
    {
      services.wivrn = {
        enable = true;
        autoStart = true;
        openFirewall = true;
        highPriority = true;

        steam = {
          importOXRRuntimes = true;
          package = config.programs.steam.package;
        };

        # Use AMD's VA-API encoder rather than the experimental Vulkan path.
        config = {
          enable = true;
          json.encoder = {
            encoder = "vaapi";
            codec = "h265";
          };
        };
      };
    };
}
