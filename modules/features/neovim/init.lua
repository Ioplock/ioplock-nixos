-- Plugins and runtime tools are provided by the Neovim wrapper in neovim.nix.
-- Keep this entry point small so startup order remains obvious.

vim.loader.enable()

require("opts")
require("keymap")

-- UI and project workflow ----------------------------------------------------

local snacks = require("snacks")

snacks.setup({
	bigfile = { enabled = true },
	dashboard = {
		enabled = true,
		preset = {
			keys = {
				{ icon = " ", key = "f", desc = "Find File", action = ":lua Snacks.dashboard.pick('files')" },
				{ icon = " ", key = "n", desc = "New File", action = ":ene | startinsert" },
				{ icon = " ", key = "g", desc = "Find Text", action = ":lua Snacks.dashboard.pick('live_grep')" },
				{ icon = " ", key = "r", desc = "Recent Files", action = ":lua Snacks.dashboard.pick('oldfiles')" },
				{ icon = " ", key = "s", desc = "Restore Session", section = "session" },
				{ icon = " ", key = "q", desc = "Quit", action = ":qa" },
			},
		},
		-- The omitted startup section is specific to lazy.nvim, while Nix owns
		-- plugin installation for this configuration.
		sections = {
			{ section = "header" },
			{ section = "keys", gap = 1, padding = 1 },
		},
	},
	explorer = { enabled = false },
	indent = { enabled = true },
	input = { enabled = true },
	notifier = { enabled = true, timeout = 2500 },
	picker = { enabled = true },
	quickfile = { enabled = true },
})

require("neo-tree").setup({
	close_if_last_window = true,
	log_to_file = false,
	filesystem = {
		filtered_items = { visible = true },
		follow_current_file = { enabled = true },
		hijack_netrw_behavior = "open_current",
		use_libuv_file_watcher = true,
	},
	window = { width = 30 },
})

require("lualine").setup({
	options = { globalstatus = true, theme = "auto" },
})

require("bufferline").setup({
	options = {
		always_show_bufferline = false,
		diagnostics = "nvim_lsp",
		offsets = {
			{ filetype = "neo-tree", text = "Explorer", text_align = "center" },
		},
	},
})

require("noice").setup({
	lsp = {
		override = {
			["vim.lsp.util.convert_input_to_markdown_lines"] = true,
		},
	},
	presets = {
		command_palette = true,
		long_message_to_split = true,
		lsp_doc_border = true,
	},
})

require("todo-comments").setup({})
require("flash").setup({})
require("mini.pairs").setup({})
require("mini.surround").setup({})
require("mini.ai").setup({})
require("grug-far").setup({})
require("persistence").setup({})
require("trouble").setup({})
require("harpoon"):setup({})
require("nvim-ts-autotag").setup({})

require("gitsigns").setup({
	on_attach = function(bufnr)
		local gitsigns = require("gitsigns")
		local function map(lhs, rhs, desc)
			vim.keymap.set("n", lhs, rhs, { buffer = bufnr, desc = desc, silent = true })
		end

		map("]h", function()
			gitsigns.nav_hunk("next")
		end, "Next Git hunk")
		map("[h", function()
			gitsigns.nav_hunk("prev")
		end, "Previous Git hunk")
		map("<leader>ghp", gitsigns.preview_hunk, "Preview hunk")
		map("<leader>ghs", gitsigns.stage_hunk, "Stage hunk")
		map("<leader>ghr", gitsigns.reset_hunk, "Reset hunk")
		map("<leader>ghb", gitsigns.blame_line, "Blame line")
	end,
})

local which_key = require("which-key")
which_key.setup({})
which_key.add({
	{ "<leader>b", group = "buffer" },
	{ "<leader>c", group = "code" },
	{ "<leader>f", group = "find" },
	{ "<leader>g", group = "git" },
	{ "<leader>gh", group = "hunk" },
	{ "<leader>q", group = "session" },
	{ "<leader>s", group = "search" },
	{ "<leader>t", group = "toggle" },
	{ "<leader>x", group = "diagnostics" },
})

-- Completion, formatting, linting, and LSP ----------------------------------

require("lazydev").setup({})

local blink = require("blink.cmp")
blink.setup({
	appearance = { nerd_font_variant = "mono" },
	completion = {
		documentation = { auto_show = true, auto_show_delay_ms = 400 },
	},
	keymap = { preset = "default" },
	signature = { enabled = true },
	sources = { default = { "lsp", "path", "snippets", "buffer" } },
})

local conform = require("conform")
conform.setup({
	default_format_opts = { lsp_format = "fallback" },
	formatters_by_ft = {
		css = { "prettierd" },
		html = { "prettierd" },
		javascript = { "prettierd" },
		javascriptreact = { "prettierd" },
		json = { "prettierd" },
		jsonc = { "prettierd" },
		lua = { "stylua" },
		markdown = { "prettierd" },
		["markdown.mdx"] = { "prettierd" },
		nix = { "alejandra" },
		python = { "ruff_format" },
		scss = { "prettierd" },
		typescript = { "prettierd" },
		typescriptreact = { "prettierd" },
		yaml = { "prettierd" },
	},
})

vim.keymap.set({ "n", "x" }, "<leader>cf", function()
	conform.format({ async = true })
end, { desc = "Format buffer" })

local lint = require("lint")
lint.linters_by_ft = { nix = { "statix" } }
vim.api.nvim_create_autocmd("BufWritePost", {
	group = vim.api.nvim_create_augroup("user_lint", { clear = true }),
	pattern = "*.nix",
	desc = "Lint Nix after saving",
	callback = function(args)
		vim.api.nvim_buf_call(args.buf, function()
			lint.try_lint()
		end)
	end,
})

vim.diagnostic.config({
	float = { border = "single", source = true },
	severity_sort = true,
	signs = true,
	underline = true,
	update_in_insert = false,
	virtual_text = { spacing = 2, source = "if_many" },
})

vim.lsp.config("*", {
	capabilities = blink.get_lsp_capabilities(),
})

-- basedpyright owns hover/type information; Ruff supplies fast diagnostics and
-- code actions without competing for hover responses.
vim.lsp.config("ruff", {
	on_attach = function(client)
		client.server_capabilities.hoverProvider = false
	end,
})

vim.lsp.enable({
	"basedpyright",
	"cssls",
	"eslint",
	"html",
	"jsonls",
	"lua_ls",
	"nixd",
	"ruff",
	"tailwindcss",
	"vtsls",
})

local lsp_group = vim.api.nvim_create_augroup("user_lsp", { clear = true })
vim.api.nvim_create_autocmd("LspAttach", {
	group = lsp_group,
	desc = "Configure LSP keymaps",
	callback = function(args)
		local function map(lhs, rhs, desc)
			vim.keymap.set("n", lhs, rhs, { buffer = args.buf, desc = desc, silent = true })
		end

		map("gd", vim.lsp.buf.definition, "Go to definition")
		map("gD", vim.lsp.buf.declaration, "Go to declaration")
		map("gri", vim.lsp.buf.implementation, "Go to implementation")
		map("grr", vim.lsp.buf.references, "Go to references")
		map("K", vim.lsp.buf.hover, "Hover documentation")
		map("<leader>ca", vim.lsp.buf.code_action, "Code action")
		map("<leader>cr", vim.lsp.buf.rename, "Rename symbol")
		map("<leader>th", function()
			local enabled = vim.lsp.inlay_hint.is_enabled({ bufnr = args.buf })
			vim.lsp.inlay_hint.enable(not enabled, { bufnr = args.buf })
		end, "Toggle inlay hints")
	end,
})

vim.keymap.set("n", "[d", function()
	vim.diagnostic.jump({ count = -1, float = true })
end, { desc = "Previous diagnostic" })
vim.keymap.set("n", "]d", function()
	vim.diagnostic.jump({ count = 1, float = true })
end, { desc = "Next diagnostic" })
vim.keymap.set("n", "<leader>cd", vim.diagnostic.open_float, { desc = "Line diagnostics" })
