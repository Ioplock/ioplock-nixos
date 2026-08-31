local o = vim.opt

-- Appearance
vim.g.have_nerd_font = true
o.termguicolors = true
o.number = true
o.relativenumber = true
o.signcolumn = "yes"
o.cursorline = true
o.wrap = false
o.scrolloff = 8
o.sidescrolloff = 8
o.showmode = false

-- Editing
o.expandtab = true
o.tabstop = 2
o.softtabstop = 2
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
o.confirm = true
o.inccommand = "split"
o.timeoutlen = 400
o.updatetime = 250
o.undofile = true

-- Window border for floating windows (Neovim 0.11+)
o.winborder = "single"

-- Autocommands --------------------------------------------------------------

local general = vim.api.nvim_create_augroup("user_general", { clear = true })

vim.api.nvim_create_autocmd("TextYankPost", {
	group = general,
	desc = "Highlight copied text",
	callback = function()
		vim.hl.on_yank({ timeout = 150 })
	end,
})

vim.api.nvim_create_autocmd("FileType", {
	group = general,
	desc = "Enable Treesitter when a parser is available",
	callback = function(args)
		if vim.bo[args.buf].buftype == "" then
			-- Not every detected filetype has a parser. Syntax highlighting remains
			-- the fallback for those buffers.
			pcall(vim.treesitter.start, args.buf)
		end
	end,
})

vim.api.nvim_create_autocmd("FileType", {
	group = general,
	pattern = "python",
	desc = "Use standard Python indentation",
	callback = function(args)
		vim.bo[args.buf].tabstop = 4
		vim.bo[args.buf].softtabstop = 4
		vim.bo[args.buf].shiftwidth = 4
	end,
})
