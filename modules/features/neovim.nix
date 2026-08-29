{ self, inputs, ... }:
{
  flake.wrappers.neovim =
    { pkgs, wlib, lib, ... }:
    {
      imports = [ wlib.wrapperModules.neovim ];

      settings.config_directory = ./neovim;

      # All plugins are declared here; Nix puts them on runtimepath.
      # Lua in ./neovim/init.lua does `require("plugin").setup({})`.
      # Keep this list sorted by purpose so you instantly see what each does.
      specs.general = with pkgs.vimPlugins; [
        # === Core / dependencies ===
        plenary-nvim # Lua helpers for neo-tree, telescope, harpoon
        nui-nvim # UI library for neo-tree and noice
        nvim-notify # Nice notification popups (used by noice)
        nvim-web-devicons # File icons for neo-tree, bufferline, lualine

        # === File navigation (your picks) ===
        neo-tree-nvim # VSCode-like sidebar file tree - press Ctrl+B (recommended)
        snacks-nvim # Fast picker for Ctrl+P files, grep, buffers + dashboard + indent guides

        # === Completion & snippets (VSCode-like typing) ===
        blink-cmp # Fast completion popup (Rust) - like VSCode Ctrl+Space
        luasnip # Snippet engine for blink
        friendly-snippets # VSCode snippet collection (for, useState, def, etc)

        # === LSP / Treesitter / Diagnostics ===
        nvim-lspconfig # Bridge so `vim.lsp.enable()` works
        lazydev-nvim # Better Lua help when editing nvim config
        (nvim-treesitter.withAllGrammars) # Syntax highlight for all languages
        nvim-ts-autotag # Auto-close JSX/HTML tags - crucial for Next.js/React
        conform-nvim # Formatter (manual with <leader>f per your choice)
        nvim-lint # Shows lint errors like VSCode Problems panel
        trouble-nvim # Pretty diagnostics list - VSCode Problems view

        # === Git (VSCode Source Control) ===
        gitsigns-nvim # Git gutter signs + hunk preview

        # === VSCode-like UI ===
        lualine-nvim # Bottom status line (mode, branch, errors)
        bufferline-nvim # Top tabs like VSCode editor tabs
        which-key-nvim # Popup that shows you available keys (like Ctrl+Shift+P)
        noice-nvim # Fancy command line and LSP progress toasts
        dressing-nvim # Better input/select boxes (VSCode quick input)
        todo-comments-nvim # Highlights TODO/FIXME like VSCode extension

        # === Multi-file & editing helpers (VSCode-like) ===
        flash-nvim # Jump anywhere with `S` - faster than mouse
        harpoon2 # Pin 4 files to Ctrl+1..4 for instant switch (Next.js workflow)
        grug-far-nvim # Project search/replace with live preview (Ctrl+Shift+F)
        persistence-nvim # Auto-restore last session like VSCode reopen
        mini-nvim # Collection: mini.pairs (auto brackets), mini.surround, mini.ai (better text objects), mini.icons
      ];

      # Binaries that Neovim needs at runtime (like VSCode extensions' servers).
      # Nix puts these on PATH for the wrapped nvim, you call them via vim.lsp.enable().
      # No mason.nvim needed - Nix is your package manager.
      extraPackages = with pkgs; [
        # --- Core search (for snacks picker) ---
        ripgrep # Fast grep for picker live_grep
        fd # Fast file finder for picker
        fzf # Fallback fuzzy finder
        lazygit # Git UI inside nvim via snacks.lazygit

        # --- Nix (your stack) ---
        nil # Nix LSP (nil_ls)
        nixd # Nix LSP with better docs (nixd)
        alejandra # Nix formatter (used by conform)
        statix # Nix linter

        # --- Python ---
        basedpyright # Python type checker LSP
        ruff # Python formatter + linter (super fast)

        # --- Next.js / React / TypeScript ---
        vtsls # TypeScript LSP (faster than tsserver, for Next.js)
        vscode-langservers-extracted # JSON, HTML, CSS, ESLint LSPs
        tailwindcss-language-server # Tailwind CSS completions
        prettierd # JS/TS/JSON formatter daemon
        eslint_d # JS/TS linter daemon

        # --- Lua (for editing nvim config) ---
        lua-language-server # Lua LSP (lua_ls)
        stylua # Lua formatter
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
