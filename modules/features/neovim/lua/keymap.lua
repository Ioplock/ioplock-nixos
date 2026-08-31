vim.g.mapleader = " "
vim.g.maplocalleader = " "

local function map(mode, lhs, rhs, desc, extra)
	local opts = vim.tbl_extend("force", { desc = desc, silent = true }, extra or {})
	vim.keymap.set(mode, lhs, rhs, opts)
end

-- Window navigation
map("n", "<M-h>", "<C-w>h", "Focus left window")
map("n", "<M-j>", "<C-w>j", "Focus lower window")
map("n", "<M-k>", "<C-w>k", "Focus upper window")
map("n", "<M-l>", "<C-w>l", "Focus right window")

-- Move lines in visual mode
map("x", "J", ":move '>+1<CR>gv=gv", "Move selection down")
map("x", "K", ":move '<-2<CR>gv=gv", "Move selection up")

-- Clear search highlight
map("n", "<Esc>", "<cmd>nohlsearch<CR>", "Clear search highlight")

-- Resize
map("n", "<C-h>", "<cmd>vertical resize -2<CR>", "Shrink window horizontally")
map("n", "<C-l>", "<cmd>vertical resize +2<CR>", "Grow window horizontally")
map("n", "<C-k>", "<cmd>resize -2<CR>", "Shrink window vertically")
map("n", "<C-j>", "<cmd>resize +2<CR>", "Grow window vertically")

-- Center on half-page jumps
map("n", "<C-d>", "<C-d>zz", "Scroll down half a page")
map("n", "<C-u>", "<C-u>zz", "Scroll up half a page")

-- Files and buffers
map("n", "<C-b>", "<cmd>Neotree toggle<CR>", "Toggle file explorer")
map("n", "<C-p>", function()
	require("snacks").picker.files()
end, "Find files")
map("n", "<C-S-p>", function()
	require("snacks").picker.commands()
end, "Command palette")
map("n", "<leader>fc", function()
	require("snacks").picker.commands()
end, "Commands")
map("n", "<leader>ff", function()
	require("snacks").picker.files()
end, "Files")
map("n", "<leader>fg", function()
	require("snacks").picker.grep()
end, "Grep")
map("n", "<leader>fb", function()
	require("snacks").picker.buffers()
end, "Buffers")
map("n", "<leader>fr", function()
	require("snacks").picker.recent()
end, "Recent files")
map("n", "[b", "<cmd>bprevious<CR>", "Previous buffer")
map("n", "]b", "<cmd>bnext<CR>", "Next buffer")
map("n", "<leader>bd", function()
	require("mini.bufremove").delete(0, false)
end, "Delete buffer")

-- Project workflow
map("n", "<C-S-f>", "<cmd>GrugFar<CR>", "Search and replace project")
map("n", "<leader>sr", "<cmd>GrugFar<CR>", "Search and replace project")
map("n", "<leader>gg", function()
	require("snacks").lazygit()
end, "Lazygit")
map("n", "<leader>qs", function()
	require("persistence").load()
end, "Restore session")
map("n", "<leader>xx", "<cmd>Trouble diagnostics toggle<CR>", "Workspace diagnostics")

-- Harpoon uses leader-number mappings because Ctrl+number is not portable
-- across terminals.
map("n", "<leader>a", function()
	require("harpoon"):list():add()
end, "Add file to Harpoon")
map("n", "<C-e>", function()
	local harpoon = require("harpoon")
	harpoon.ui:toggle_quick_menu(harpoon:list())
end, "Harpoon menu")
for index = 1, 4 do
	local harpoon_index = index
	map("n", "<leader>" .. index, function()
		require("harpoon"):list():select(harpoon_index)
	end, "Harpoon file " .. index)
end

-- Fast motion
map({ "n", "x", "o" }, "s", function()
	require("flash").jump()
end, "Flash jump")
