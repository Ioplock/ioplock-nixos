vim.g.mapleader = " "
vim.g.maplocalleader = " "

local map = vim.keymap.set
local opts = { noremap = true, silent = true }

-- Window navigation
map("n", "<M-h>", "<C-w>h", opts)
map("n", "<M-j>", "<C-w>j", opts)
map("n", "<M-k>", "<C-w>k", opts)
map("n", "<M-l>", "<C-w>l", opts)

-- Move lines in visual mode
map("v", "J", ":m '>+1<CR>gv=gv", opts)
map("v", "K", ":m '<-2<CR>gv=gv", opts)

-- Clear search highlight
map("n", "<leader><esc>", "<cmd>nohlsearch<CR>", opts)

-- Resize
map("n", "<C-h>", ":vertical resize -2<CR>", opts)
map("n", "<C-l>", ":vertical resize +2<CR>", opts)
map("n", "<C-k>", ":resize -2<CR>", opts)
map("n", "<C-j>", ":resize +2<CR>", opts)

-- Center on half-page jumps
map("n", "<C-d>", "5<C-d>zz", opts)
map("n", "<C-u>", "5<C-u>zz", opts)
