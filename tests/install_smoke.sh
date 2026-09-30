#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
plugin_root="$PWD"
smoke_root="$(mktemp -d)"
trap 'rm -rf "$smoke_root"' EXIT

export XDG_CONFIG_HOME="$smoke_root/config"
export XDG_DATA_HOME="$smoke_root/data"
export XDG_STATE_HOME="$smoke_root/state"
export XDG_CACHE_HOME="$smoke_root/cache"
export NVIM_APPNAME=pair-smoke
export PAIR_TEST_PLUGIN_ROOT="$plugin_root"

mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"

# A package install uses only Neovim's native packpath, with no user config.
manual_root="$XDG_DATA_HOME/$NVIM_APPNAME/site/pack/pair/start/pair.nvim"
mkdir -p "$(dirname "$manual_root")"
ln -s "$plugin_root" "$manual_root"
nvim --headless -u NORC -l "$plugin_root/tests/install_smoke.lua"
rm "$manual_root"

# lazy.nvim sees the same source tree as a newly installed GitHub plugin.
git clone --quiet --depth=1 https://github.com/folke/lazy.nvim.git "$smoke_root/lazy.nvim"
export PAIR_TEST_LAZY_ROOT="$smoke_root/lazy.nvim"
cat > "$smoke_root/lazy-init.lua" <<'LUA'
vim.opt.rtp:prepend(vim.env.PAIR_TEST_LAZY_ROOT)
require("lazy").setup({ {
  dir = vim.env.PAIR_TEST_PLUGIN_ROOT,
  lazy = false,
} }, {
  root = vim.fn.stdpath("data") .. "/lazy",
  lockfile = vim.fn.stdpath("config") .. "/lazy-lock.json",
  checker = { enabled = false },
  change_detection = { enabled = false },
})
LUA
nvim --headless -u "$smoke_root/lazy-init.lua" \
  -l "$plugin_root/tests/install_smoke.lua"
