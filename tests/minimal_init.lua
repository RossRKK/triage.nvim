-- Runtime for the headless test suite: this plugin plus plenary (busted harness
-- + luassert). plenary is reused from the Neovim config's lazy install so CI and
-- a local run share one copy. No neo-tree/gitsigns: the specs cover the pure
-- logic in triage/init.lua and fake whatever plugin objects it touches.

local root = vim.fn.fnamemodify(vim.fn.expand("<sfile>:p"), ":h:h")
local plenary = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"

if vim.fn.isdirectory(plenary) == 0 then
  error("plenary.nvim not found at " .. plenary .. " -- open nvim once to let lazy install it")
end

vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(plenary)
vim.opt.swapfile = false
