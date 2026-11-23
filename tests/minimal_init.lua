-- Runtime for the headless test suite: this plugin plus plenary (busted harness
-- + luassert). The flake's shell and check set PLENARY_DIR; without them,
-- plenary comes from the Neovim config's lazy install. No neo-tree/gitsigns: the
-- specs fake whatever plugin objects they touch, except gitsigns_spec, which
-- loads gitsigns itself.

local root = vim.fn.fnamemodify(vim.fn.expand("<sfile>:p"), ":h:h")
local plenary = vim.env.PLENARY_DIR or (vim.fn.stdpath("data") .. "/lazy/plenary.nvim")

if vim.fn.isdirectory(plenary) == 0 then
  error("plenary.nvim not found at " .. plenary .. " -- run the suite with `nix develop -c make test`")
end

vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(plenary)
vim.opt.swapfile = false
