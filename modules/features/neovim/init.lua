-- Minimal VSCode-like init.lua for nix-wrapper-modules
-- Loaded as INIT_MAIN via settings.config_directory = ./neovim
-- Plugins come from Nix (specs.general); this file only configures them.
-- You are new to nvim, so every block is commented like in the Nix file.

require("opts")
require("keymap")

-- Portable fallback so this config also works outside Nix (e.g. plain `nvim` without wrapper)
do
  local ok = pcall(require, vim.g.nix_info_plugin_name)
  if not ok then
    package.loaded[vim.g.nix_info_plugin_name] = setmetatable({}, {
      __call = function(_, default) return default end,
    })
  end
end

-- Nix manages plugins, but some plugins (snacks.dashboard startup, which-key) check for lazy.nvim.
-- We install lazy.nvim via Nix (see neovim.nix) and keep dashboard `startup` disabled to avoid
-- unguarded `require("lazy.stats").stats()` when dashboard is opened. No stub needed now that
-- lazy.nvim is on runtimepath; `package.loaded.lazy` stays nil until actually required, so
-- which-key's `if package.loaded.lazy then` branch is skipped unless you explicitly `:Lazy`.

-- === Core notifications (must be early, used by noice) ===
pcall(function()
  require("notify").setup({ stages = "fade", timeout = 2000 })
  vim.notify = require("notify")
end)

-- === VSCode-like UI ===
pcall(function()
  require("lualine").setup({ options = { theme = "auto", globalstatus = true } }) -- bottom status bar
end)
pcall(function()
  require("bufferline").setup({}) -- top tabs like VSCode
end)
pcall(function()
  require("noice").setup({ lsp = { override = { ["vim.lsp.util.convert_input_to_markdown_lines"] = true } } }) -- fancy cmdline + LSP popups
end)
pcall(function()
  require("dressing").setup({}) -- better vim.ui.input/select (VSCode quick input)
end)
pcall(function()
  require("todo-comments").setup({}) -- highlights TODO/FIXME
end)
pcall(function()
  require("which-key").setup({}) -- shows keys after you press <leader>
end)
pcall(function()
  require("gitsigns").setup({}) -- git gutter signs
end)

-- === File explorer + picker (your choices) ===
pcall(function()
  require("neo-tree").setup({
    filesystem = { hijack_netrw_behavior = "open_current", filtered_items = { visible = true } },
    window = { width = 30 },
  })
  -- Ctrl+B toggles sidebar like VSCode Ctrl+Shift+E
  vim.keymap.set("n", "<C-b>", "<cmd>Neotree toggle<CR>", { desc = "Toggle file tree (neo-tree)" })
end)
pcall(function()
  local snacks = require("snacks")
  snacks.setup({
    picker = { enabled = true }, -- Ctrl+P file finder
    explorer = { enabled = false }, -- we use neo-tree, so keep snacks explorer off
    dashboard = {
      enabled = true,
      sections = {
        { section = "header" },
        { section = "keys", gap = 1, padding = 1 },
        -- startup section disabled to avoid `require("lazy.stats")` error (we don't use lazy.nvim)
      },
    },
    indent = { enabled = true }, -- indent guides
    notifier = { enabled = true },
    bigfile = { enabled = true },
  })
  -- VSCode-like picker keys (snacks.picker is LazyVim default)
  vim.keymap.set("n", "<C-p>", function() snacks.picker.files() end, { desc = "Find files (Ctrl+P)" })
  vim.keymap.set("n", "<C-S-p>", function() snacks.picker.commands() end, { desc = "Command palette" })
  vim.keymap.set("n", "<leader>fg", function() snacks.picker.grep() end, { desc = "Live grep" })
  vim.keymap.set("n", "<leader>fb", function() snacks.picker.buffers() end, { desc = "Find buffers" })
  vim.keymap.set("n", "<leader>fr", function() snacks.picker.recent() end, { desc = "Recent files" })
end)

-- === Multi-file fast switching (harpoon) ===
pcall(function()
  local harpoon = require("harpoon")
  harpoon:setup()
  -- Mark file, then jump 1..4 - perfect for Next.js: page.tsx <-> component <-> utils <-> api
  vim.keymap.set("n", "<leader>a", function() harpoon:list():add() end, { desc = "Harpoon add file" })
  vim.keymap.set("n", "<C-e>", function() harpoon.ui:toggle_quick_menu(harpoon:list()) end, { desc = "Harpoon menu" })
  vim.keymap.set("n", "<C-1>", function() harpoon:list():select(1) end, { desc = "Harpoon file 1" })
  vim.keymap.set("n", "<C-2>", function() harpoon:list():select(2) end, { desc = "Harpoon file 2" })
  vim.keymap.set("n", "<C-3>", function() harpoon:list():select(3) end, { desc = "Harpoon file 3" })
  vim.keymap.set("n", "<C-4>", function() harpoon:list():select(4) end, { desc = "Harpoon file 4" })
end)

-- === Completion (VSCode Ctrl+Space) ===
pcall(function()
  require("luasnip.loaders.from_vscode").lazy_load() -- loads friendly-snippets (VSCode snippets)
end)
pcall(function()
  require("blink.cmp").setup({
    keymap = { preset = "default" },
    appearance = { nerd_font_variant = "mono" },
    completion = { documentation = { auto_show = true } },
    sources = { default = { "lsp", "path", "snippets", "buffer" } },
  })
end)

-- === Editing helpers (VSCode-like) ===
pcall(function()
  require("flash").setup({}) -- press `s` to jump anywhere
  vim.keymap.set({ "n", "x", "o" }, "s", function() require("flash").jump() end, { desc = "Flash jump" })
end)
pcall(function()
  require("mini.pairs").setup({}) -- auto-close brackets/quotes like VSCode
end)
pcall(function()
  require("mini.surround").setup({}) -- ysiw" to surround word with quotes
end)
pcall(function()
  require("mini.ai").setup({}) -- better text objects (e.g. `ci)` inside parens, works in JSX)
end)
pcall(function()
  require("mini.icons").setup({}) -- icons, fallback for web-devicons
end)

-- === Project search/replace + session ===
pcall(function()
  require("grug-far").setup({}) -- Ctrl+Shift+F project replace with live preview
  vim.keymap.set("n", "<C-S-f>", "<cmd>GrugFar<CR>", { desc = "Search/replace project" })
end)
pcall(function()
  require("persistence").setup({}) -- auto-restore session like VSCode workspace
  vim.keymap.set("n", "<leader>qs", function() require("persistence").load() end, { desc = "Restore session" })
end)

-- === Diagnostics / Problems (VSCode Ctrl+Shift+M) ===
pcall(function()
  require("trouble").setup({})
  vim.keymap.set("n", "<leader>xx", "<cmd>Trouble diagnostics toggle<CR>", { desc = "Diagnostics (Trouble)" })
end)

-- === Formatting & Linting (manual per your choice) ===
pcall(function()
  require("conform").setup({
    formatters_by_ft = {
      lua = { "stylua" },
      nix = { "alejandra" },
      python = { "ruff_format" },
      javascript = { "prettierd", "prettier" },
      typescript = { "prettierd", "prettier" },
      javascriptreact = { "prettierd", "prettier" },
      typescriptreact = { "prettierd", "prettier" },
      json = { "prettierd" },
    },
  })
  -- Manual format only - press <leader>f like VSCode Shift+Alt+F
  vim.keymap.set({ "n", "v" }, "<leader>f", function() require("conform").format({ async = true, lsp_fallback = true }) end, { desc = "Format file" })
end)
pcall(function()
  require("lint").linters_by_ft = {
    python = { "ruff" },
    nix = { "statix" },
  }
  vim.api.nvim_create_autocmd({ "BufWritePost" }, {
    callback = function() require("lint").try_lint() end, -- lint on save, but format stays manual
  })
end)

-- === LSP: servers for your stack (Python/Nix/Next.js/React) ===
-- Binaries come from Nix extraPackages, no mason needed
pcall(function()
  -- Make LSP use blink.cmp capabilities (better completion)
  local caps = require("blink.cmp").get_lsp_capabilities()
  vim.lsp.config("*", { capabilities = caps })
end)
pcall(function() vim.lsp.enable("nil_ls") end) -- Nix (nil)
pcall(function() vim.lsp.enable("nixd") end) -- Nix (nixd, shows docs)
pcall(function() vim.lsp.enable("lua_ls") end) -- Lua for editing nvim config
pcall(function() vim.lsp.enable("basedpyright") end) -- Python
pcall(function() vim.lsp.enable("ruff") end) -- Python linter/formatter LSP
pcall(function() vim.lsp.enable("vtsls") end) -- TypeScript/JavaScript for Next.js/React (faster than tsserver)
pcall(function() vim.lsp.enable("tailwindcss") end) -- Tailwind CSS
pcall(function() vim.lsp.enable("jsonls") end) -- JSON (from vscode-langservers)
pcall(function() vim.lsp.enable("eslint") end) -- ESLint for JS/TS

-- === Treesitter: highlight + JSX auto-tag ===
vim.api.nvim_create_autocmd("FileType", {
  callback = function() pcall(vim.treesitter.start) end,
})
pcall(function() require("nvim-ts-autotag").setup({}) end) -- auto-close <div> tags

-- === Keymaps for VSCode habits ===
-- Already in lua/keymap.lua: Alt-hjkl window moves, Ctrl-hjkl resize, etc.
-- Add VSCode-like buffer close that keeps layout (like Ctrl+W but not closing window)
pcall(function()
  vim.keymap.set("n", "<leader>bd", function() require("mini.bufremove").delete(0, false) end, { desc = "Close buffer keep window" })
end)
