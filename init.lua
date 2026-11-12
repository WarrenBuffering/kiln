-- Kiln is isolated from the user's normal Neovim configuration.
local home = vim.env.KILN_HOME or vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
vim.opt.runtimepath:prepend(home)
vim.g.mapleader = " "
vim.g.maplocalleader = " "

vim.opt.termguicolors = true
vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.signcolumn = "yes"
vim.opt.cursorline = true
vim.opt.mouse = "a"
vim.opt.hidden = true
vim.opt.splitright = true
vim.opt.splitbelow = true
vim.opt.equalalways = false
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.incsearch = true
vim.opt.hlsearch = true
vim.opt.scrolloff = 5
vim.opt.sidescrolloff = 5
vim.opt.updatetime = 300
vim.opt.timeoutlen = 400
vim.opt.completeopt = { "menuone", "noselect" }
vim.opt.expandtab = true
vim.opt.tabstop = 2
vim.opt.shiftwidth = 2
vim.opt.smartindent = true
vim.opt.wrap = false
vim.opt.showmode = false
vim.opt.laststatus = 2
vim.opt.fillchars = { eob = " ", vert = "│" }
vim.opt.listchars = { tab = "→ ", trail = "·", extends = "›", precedes = "‹" }
vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.writebackup = false
vim.opt.undofile = false
vim.opt.modeline = false
vim.opt.autoread = true
vim.opt.title = false
vim.opt.shortmess:append("I")
vim.cmd("filetype plugin indent on")
vim.cmd("syntax enable")
require("kiln.theme").setup()

vim.keymap.set("n", "<Esc>", "<Cmd>nohlsearch<CR>", { silent = true, desc = "Clear search highlight" })
vim.keymap.set({ "n", "i" }, "<C-h>", function() vim.cmd("wincmd h") end, { desc = "Focus left pane" })
vim.keymap.set({ "n", "i" }, "<C-j>", function() vim.cmd("wincmd j") end, { desc = "Focus lower pane" })
vim.keymap.set({ "n", "i" }, "<C-k>", function() vim.cmd("wincmd k") end, { desc = "Focus upper pane" })
vim.keymap.set({ "n", "i" }, "<C-l>", function() vim.cmd("wincmd l") end, { desc = "Focus right pane" })

vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    require("kiln").setup({ root = vim.env.KILN_ROOT or vim.fn.getcwd(), demo = vim.env.KILN_DEMO == "1" })
  end,
})
