-- Thin wrapper around the sign column's change_base, so triage never has to
-- care which one is drawing or whether it is loaded yet. Setting a repo's base
-- to the merge-base makes the sign column show every line changed on the branch;
-- nil restores the default (git's HEAD, jj's `@-`).
--
-- Two backends, because gitsigns cannot attach in a jj workspace: it needs a git
-- repo, and a secondary jj workspace has none. jjsigns fills that gap and takes
-- the same call, so review mode drives whichever is actually on screen.
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
  return require("triage.vcs").root(name)
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

--- Whether jjsigns — not gitsigns — is the gutter for `root`. A jj workspace
--- alone is not enough: jjsigns stands down in a COLOCATED repo (its
--- `only_without_git`), where gitsigns attaches and `@-` is git's HEAD. Routing
--- a re-base or an inline toggle to the backend that isn't attached there is a
--- silent no-op, so both callers must agree on this answer.
---@param root string repo toplevel
---@return boolean
function M.jj_owns(root)
  local uv = vim.uv or vim.loop
  if not uv.fs_stat(root .. "/.jj") then
    return false
  end
  if not uv.fs_stat(root .. "/.git") then
    return true -- no git repo: gitsigns cannot attach here at all
  end
  -- Colocated. jjsigns stands down unless it was configured to take over.
  local ok, jjsigns = pcall(require, "jjsigns")
  return ok and jjsigns.opts ~= nil and jjsigns.opts.only_without_git == false
end

--- A base the gitsigns gutter can actually resolve. The jj backend names
--- revisions as revsets (`trunk()`, `@-`); git has never heard of them, and
--- gitsigns attaching with one dies on `fatal: Not a valid object name` -- the
--- attach is lost outright, so the gutter goes blank rather than merely showing
--- the wrong base. A COLOCATED repo is exactly that pairing: the backend is jj
--- (`.jj` exists, see vcs/init.lua) while the gutter is gitsigns (jjsigns stands
--- down). Resolve to the commit id, the one name both languages accept.
---
--- Unresolvable revisions pass through untouched: a git ref is not valid jj
--- revset syntax either (`origin/main` is `main@origin` there), so a jj that
--- says no is usually just git's own base arriving by the git path. Handing it
--- back unchanged leaves those working as before, and leaves a genuinely broken
--- base to fail where it would have anyway.
---
--- Sync on purpose -- the callers (review-mode enable, the inline-diff toggle)
--- run outside the coroutine vcs.sh requires. `--ignore-working-copy` keeps the
--- snapshot discipline vcs/jj.lua exists to hold.
---@param root string normalized repo root
---@param base string? commit-ish or revset
---@return string? a git-resolvable ref where one was found, else `base`
local function git_resolvable(root, base)
  local uv = vim.uv or vim.loop
  if not base or not uv.fs_stat(root .. "/.jj") then
    return base
  end
  local id = vim.fn.systemlist({
    "jj",
    "-R",
    root,
    "--ignore-working-copy",
    "--color=never",
    "--no-pager",
    "log",
    "--no-graph",
    "-r",
    base,
    "-T",
    "commit_id",
  })[1]
  if vim.v.shell_error ~= 0 or not id or not id:match("^%x+$") then
    return base
  end
  return id
end

--- Set (or with nil, clear) the review base for one repo, re-basing that
--- repo's loaded buffers — and only those — buffer-locally.
---@param root string repo toplevel
---@param base string? commit-ish, or nil for the default HEAD base
function M.set_base(root, base)
  root = vim.fs.normalize(root)
  -- jjsigns takes a revset and keeps its own per-root bases, so one call
  -- re-bases every buffer under this root.
  if M.jj_owns(root) then
    M.bases[root] = base
    -- jj-only workspace with jjsigns absent: nothing draws there, nothing to do.
    local jj_ok, jjsigns = pcall(require, "jjsigns")
    return jj_ok and jjsigns.change_base(base, root) or nil
  end
  -- Store what the gutter was actually given, not what the caller asked for:
  -- base_for feeds this straight back to gitsigns' on_attach for buffers that
  -- attach later, and diff_base returns it verbatim for the inline toggle.
  base = git_resolvable(root, base)
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
