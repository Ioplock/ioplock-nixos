local o = vim.opt

-- Appearance
o.termguicolors = true
o.number = true
o.relativenumber = true
o.signcolumn = "yes"
o.cursorline = true
o.wrap = false
o.scrolloff = 8

-- Editing
o.expandtab = true
o.tabstop = 2
o.shiftwidth = 2
o.smartindent = true
o.ignorecase = true
o.smartcase = true

-- Search
o.hlsearch = true
o.incsearch = true

-- Clipboard / mouse
o.clipboard = "unnamedplus"
o.mouse = "a"

-- Splits
o.splitbelow = true
o.splitright = true

-- Misc
o.updatetime = 250
o.swapfile = false
o.undofile = true

-- Window border for floating windows (Neovim 0.11+)
o.winborder = "single"
