-- Minimal init.lua for nix-wrapper-modules neovim
-- Loaded as INIT_MAIN via settings.config_directory
-- Plugins are provided by Nix (specs.general); this file only configures them.

require("opts")
require("keymap")

-- Portable nix-info fallback for non-Nix runs (e.g. `nvim` without wrapper)
do
  local ok = pcall(require, vim.g.nix_info_plugin_name)
  if not ok then
    package.loaded[vim.g.nix_info_plugin_name] = setmetatable({}, {
      __call = function(_, default)
        return default
      end,
    })
  end
end

-- Plugin setups - plain Lua, pcall guarded so missing plugins don't break startup
pcall(function()
  require("gitsigns").setup({})
end)

pcall(function()
  require("which-key").setup({})
end)

-- LSP: enable servers provided via runtimePkgs
-- Add more with `vim.lsp.enable("server_name")` as you install them
pcall(function()
  vim.lsp.enable("nil_ls")
end)
pcall(function()
  vim.lsp.enable("nixd")
end)
pcall(function()
  vim.lsp.enable("lua_ls")
end)

-- Treesitter: start highlighting for any filetype where parser exists
vim.api.nvim_create_autocmd("FileType", {
  callback = function()
    pcall(vim.treesitter.start)
  end,
})
