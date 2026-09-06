-- Which VCS backend answers for a directory.
--
-- jj wins wherever `.jj` exists, colocated repos included: a repo with jj set up
-- at all is one the user drives through jj, and its git HEAD is detached for any
-- ordinary jj working state -- so asking git would report a branch that isn't
-- there. This is the same rule the surrounding config uses to pick jjui over
-- lazygit and jj workspaces over git worktrees.

local M = {}

---@alias TriageBackend table the module in vcs/git.lua or vcs/jj.lua

--- The backend for a directory, or nil if it is under neither VCS.
---@param dir string
---@return TriageBackend?
function M.for_dir(dir)
  if vim.fs.root(dir, ".jj") then
    return require("triage.vcs.jj")
  end
  if vim.fs.root(dir, ".git") then
    return require("triage.vcs.git")
  end
  return nil
end

--- The backend for a known repo root (which marker sits AT `root`).
---@param root string
---@return TriageBackend
function M.for_root(root)
  local uv = vim.uv or vim.loop
  if uv.fs_stat(root .. "/.jj") then
    return require("triage.vcs.jj")
  end
  return require("triage.vcs.git")
end

--- Normalized repo root containing `dir`, under either VCS, or nil. Sync (no
--- process), so the statusline and toggle can use it; walks the literal path, so
--- unlike `git rev-parse` it won't see through a symlinked cwd.
---@param dir string
---@return string?
function M.root(dir)
  local root = vim.fs.root(dir, ".jj") or vim.fs.root(dir, ".git")
  return root and vim.fs.normalize(root) or nil
end

return M
