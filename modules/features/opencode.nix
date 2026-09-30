{ self, inputs, ... }:
{
  flake.wrappers.opencode =
    { wlib, ... }:
    {
      imports = [ wlib.wrapperModules.opencode ];

      settings = {
        provider.openrouter.models."deepseek/deepseek-v4-flash-0731" = {
          name = "DeepSeek V4 Flash (max)";
          reasoningEffort = "max";
        };

        mcp.context7 = {
          type = "remote";
          url = "https://mcp.context7.com/mcp";
        };
      };
    };

  flake.nixosModules.opencode =
    { pkgs, ... }:
    {
      environment.systemPackages = [
        self.packages.${pkgs.stdenv.hostPlatform.system}.myOpencode
        pkgs.mcp-nixos
      ];
    };

  perSystem =
    { pkgs, ... }:
    {
      wrappers.packages.opencode = true;

      packages.myOpencode = inputs.wrapper-modules.wrappers.opencode.wrap {
        inherit pkgs;
        imports = [ self.wrapperModules.opencode ];
      };

      packages.myOpencodeProxy = inputs.wrapper-modules.wrappers.opencode.wrap {
        inherit pkgs;
        imports = [ self.wrapperModules.opencode ];
        binName = "opencode-proxy";
        env = {
          HTTP_PROXY = "http://127.0.0.1:1080";
          HTTPS_PROXY = "http://127.0.0.1:1080";
          ALL_PROXY = "socks5://127.0.0.1:1080";
        };
      };
    };
}
