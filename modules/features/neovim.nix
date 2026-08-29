{ self, inputs, ... }:
{
  flake.wrappers.neovim =
    { pkgs, wlib, lib, ... }:
    {
      imports = [ wlib.wrapperModules.neovim ];

      settings.config_directory = ./neovim;

      specs.general = with pkgs.vimPlugins; [
        plenary-nvim
        nvim-treesitter.withAllGrammars
        nvim-lspconfig
        blink-cmp
        gitsigns-nvim
        which-key-nvim
      ];

      extraPackages = with pkgs; [
        ripgrep
        fd
        nil
        nixd
        lua-language-server
        stylua
      ];
    };

  flake.nixosModules.neovim =
    { pkgs, ... }:
    {
      environment.systemPackages = [
        self.packages.${pkgs.stdenv.hostPlatform.system}.myNeovim
      ];
    };

  perSystem =
    { pkgs, ... }:
    {
      packages.myNeovim = inputs.wrapper-modules.wrappers.neovim.wrap {
        inherit pkgs;
        imports = [ self.wrapperModules.neovim ];
      };
    };
}
