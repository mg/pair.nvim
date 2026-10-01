-- A minimal recording config: real Pair UI, no external editor plugins.
vim.opt.rtp:append(assert(vim.env.PAIR_DEMO_PLUGIN_ROOT))
vim.g.mapleader = " "
vim.opt.termguicolors = true
vim.opt.number = true
vim.opt.relativenumber = false
vim.opt.numberwidth = 3
vim.opt.signcolumn = "no"
vim.opt.mouse = "a"
vim.opt.showmode = false
vim.opt.showcmd = false
vim.opt.ruler = false
vim.opt.swapfile = false
vim.opt.undofile = false
vim.opt.scrolloff = 3
vim.opt.sidescrolloff = 2
vim.opt.wrap = false
vim.opt.linebreak = true
vim.opt.expandtab = true
vim.opt.shiftwidth = 4
vim.opt.tabstop = 4
vim.opt.autoindent = true
vim.opt.laststatus = 3
vim.opt.cmdheight = 1
vim.opt.fillchars = { eob = " ", vert = "│" }
vim.cmd("filetype plugin indent on")
vim.cmd("syntax enable")
vim.cmd("colorscheme habamax")

local highlights = {
  Normal = { fg = "#dce4ef", bg = "#171b26" },
  NormalNC = { fg = "#dce4ef", bg = "#171b26" },
  Comment = { fg = "#8a96ae", italic = true },
  Statement = { fg = "#bb9af7" },
  Keyword = { fg = "#bb9af7" },
  PreProc = { fg = "#7dcfff" },
  Type = { fg = "#7dcfff" },
  Function = { fg = "#7aa2f7" },
  Identifier = { fg = "#dce4ef" },
  Constant = { fg = "#ffb678" },
  Number = { fg = "#ffb678" },
  String = { fg = "#9ece6a" },
  Title = { fg = "#7aa2f7", bold = true },
  DiagnosticError = { fg = "#f7768e" },
  DiagnosticWarn = { fg = "#e0af68" },
  DiagnosticInfo = { fg = "#7aa2f7" },
  DiagnosticHint = { fg = "#73daca" },
  Special = { fg = "#7dcfff" },
  LineNr = { fg = "#66718b", bg = "#171b26" },
  CursorLineNr = { fg = "#7dcfff", bold = true },
  Visual = { bg = "#334467" },
  WinSeparator = { fg = "#46516b", bg = "#171b26" },
  WinBar = { fg = "#a9b9d4", bg = "#222838", bold = true },
  WinBarNC = { fg = "#a9b9d4", bg = "#222838", bold = true },
  StatusLine = { fg = "#bdc9de", bg = "#222838" },
  DemoMode = { fg = "#171b26", bg = "#7aa2f7", bold = true },
  DemoHint = { fg = "#7dcfff", bg = "#222838" },
  DiffAdd = { fg = "#dce4ef", bg = "#20352e" },
  DiffDelete = { fg = "#f7768e", bg = "#37242c" },
}
for name, value in pairs(highlights) do vim.api.nvim_set_hl(0, name, value) end
vim.opt.statusline = "%#DemoMode#  %{mode() =~# 'i' ? 'INSERT' : 'NORMAL'}  "
  .. "%#StatusLine#  checkout%=%#DemoHint# CHAT  →  ASK  →  INSERT  "
vim.opt_local.winbar = "  checkout / src / cart.zig"

require("pair").setup({ backend = "codex", remember_selection = false })
