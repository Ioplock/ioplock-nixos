{
  self,
  inputs,
  ...
}:
{
  flake.wrappers.neovim =
    {
      pkgs,
      wlib,
      ...
    }:
    {
      imports = [ wlib.wrapperModules.neovim ];

      settings = {
        aliases = [
          "vi"
          "vim"
        ];
        config_directory = ./neovim;
      };

      # Nix owns plugin installation; Lua only configures these plugins.
      specs.general = with pkgs.vimPlugins; [
        # === Core / dependencies ===
        plenary-nvim # Lua helpers for neo-tree and harpoon
        nui-nvim # UI library for neo-tree and noice
        nvim-web-devicons # File icons for neo-tree, bufferline, lualine

        # === File navigation ===
        neo-tree-nvim # Sidebar file tree
        snacks-nvim # Pickers, dashboard, input, notifications, and utilities

        # === Completion and snippets ===
        blink-cmp # Completion UI and native snippet engine
        friendly-snippets # VSCode-format snippet collection loaded by blink.cmp

        # === LSP / Treesitter / Diagnostics ===
        nvim-lspconfig # Bridge so `vim.lsp.enable()` works
        lazydev-nvim # Better Lua help when editing nvim config
        (nvim-treesitter.withAllGrammars) # Syntax highlight for all languages
        nvim-ts-autotag # Auto-close JSX/HTML tags
        conform-nvim # Manual formatting
        nvim-lint # Standalone Nix lint diagnostics
        trouble-nvim # Diagnostics list

        # === Git ===
        gitsigns-nvim # Git gutter signs and hunk actions

        # === UI ===
        lualine-nvim # Status line
        bufferline-nvim # Buffer tabs
        which-key-nvim # Discoverable leader mappings
        noice-nvim # Command line, messages, and LSP progress UI
        todo-comments-nvim # Highlight TODO/FIXME annotations

        # === Editing and project workflow ===
        flash-nvim # Fast motion
        harpoon2 # Pinned-file navigation
        grug-far-nvim # Project-wide search and replace
        persistence-nvim # Session save and restore
        mini-nvim # Pairs, surround, text objects, and buffer removal
      ];

      # Runtime tools stay on the wrapped editor's PATH; Mason is unnecessary.
      extraPackages = with pkgs; [
        # --- Core ---
        curl
        fd
        git
        lazygit
        ripgrep
        wl-clipboard

        # --- Nix ---
        alejandra
        nixd
        statix

        # --- Python ---
        basedpyright
        ruff

        # --- Next.js / React / TypeScript ---
        prettierd
        tailwindcss-language-server
        vscode-langservers-extracted
        vtsls

        # --- Lua ---
        lua-language-server
        stylua
      ];
    };

  flake.nixosModules.neovim = { pkgs, ... }: {
    environment.systemPackages = [
      self.packages.${pkgs.stdenv.hostPlatform.system}.myNeovim
    ];
  };

  perSystem = { pkgs, ... }: {
    packages.myNeovim = inputs.wrapper-modules.wrappers.neovim.wrap {
      inherit pkgs;
      imports = [ self.wrapperModules.neovim ];
    };
  };
}
