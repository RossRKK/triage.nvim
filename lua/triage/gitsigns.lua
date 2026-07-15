-- Thin wrapper around gitsigns' change_base, so triage never has to care
-- whether gitsigns is loaded yet. Setting the base to the merge-base makes the
-- sign column show every line changed on the branch; nil restores HEAD.

local M = {}

M.current = nil

---@param base string? commit-ish, or nil for the default HEAD base
function M.set_base(base)
  M.current = base
  local ok, gs = pcall(require, "gitsigns")
  if not ok then
    return
  end
  -- global = true applies to all buffers, present and future.
  pcall(gs.change_base, base, true)
end

return M
