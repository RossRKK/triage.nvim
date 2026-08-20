-- Thin wrapper around gitsigns' change_base, so triage never has to care
-- whether gitsigns is loaded yet. Setting a repo's base to the merge-base makes
-- the sign column show every line changed on the branch; nil restores HEAD.
--
-- Bases are per repo root and applied buffer-locally, never with gitsigns'
-- global flag: review mode is a property of one repo, and a global base would
-- be re-validated against every attached buffer — buffers from *another* repo
-- (another workspace tab) then error on a ref their repo can't resolve.

local M = {}

---@type table<string, string> normalized repo root -> commit-ish review base
M.bases = {}

--- Normalized repo root containing a buffer's file, or nil (unnamed buffers
--- deliberately resolve to nil rather than falling back to cwd — a scratch
--- buffer belongs to no repo).
---@param buf integer? buffer handle, 0/nil for current
---@return string?
function M.buf_root(buf)
  local name = vim.api.nvim_buf_get_name(buf or 0)
  if name == "" then
    return nil
  end
  local root = vim.fs.root(name, ".git")
  return root and vim.fs.normalize(root) or nil
end

--- The review base a buffer should diff against, or nil for the default HEAD
--- base. For gitsigns' on_attach: buffers that attach after their repo's base
--- was chosen inherit it via this lookup.
---@param buf integer?
---@return string?
function M.base_for(buf)
  local root = M.buf_root(buf)
  return root and M.bases[root] or nil
end

--- Set (or with nil, clear) the review base for one repo, re-basing that
--- repo's loaded buffers — and only those — buffer-locally.
---@param root string repo toplevel
---@param base string? commit-ish, or nil for the default HEAD base
function M.set_base(root, base)
  root = vim.fs.normalize(root)
  M.bases[root] = base
  local ok, gs = pcall(require, "gitsigns")
  if not ok then
    return
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and M.buf_root(buf) == root then
      vim.api.nvim_buf_call(buf, function()
        -- pcall: change_base errors on buffers gitsigns isn't attached to.
        pcall(gs.change_base, base, false)
      end)
    end
  end
end

return M
