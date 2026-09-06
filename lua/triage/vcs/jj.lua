-- The jj backend: everything triage needs to describe a change, asked of jj.
--
-- SNAPSHOT DISCIPLINE, the one rule this file exists to keep. Any jj command
-- without --ignore-working-copy snapshots the working copy: it takes the repo
-- lock and writes a new operation. The greeter watches the operation head to
-- learn that the change moved, and reacts by asking for another report. So a
-- report that snapshots re-triggers itself, forever.
--
-- Therefore: every query here passes --ignore-working-copy, and the ONE place a
-- snapshot happens is M.snapshot(), called from the save path. Saving writes one
-- operation, the watcher fires once, the refresh it triggers writes none, and
-- the system settles. Uncommitted edits are visible to the report because the
-- save snapshotted them into @ first -- which is also why jj needs no separate
-- "unstaged vs untracked" handling: the working copy IS the commit.

local sh = require("triage.vcs.sh")

local M = {}

--- Directory that marks a workspace root, for the synchronous lookups.
M.marker = ".jj"

--- Run jj in `root` (async), never snapshotting.
---@param root string
---@param args string[]
---@return string[] lines, integer code
local function jj(root, args)
  local cmd = { "jj", "--ignore-working-copy", "--color=never", "--no-pager", "-R", root }
  vim.list_extend(cmd, args)
  return sh.sh(cmd)
end

-- Roots already reported as stale, so the notice below is shown once rather
-- than on every save.
local warned_stale = {}

--- Count the commits in a revset.
---@param root string
---@param revset string
---@return integer
local function count(root, revset)
  local lines = jj(root, { "log", "--no-graph", "-r", revset, "-T", '"x\n"' })
  return #lines
end

--- One field of the working copy, via a template.
---@param root string
---@param template string
---@param revset string?
---@return string?
local function field(root, template, revset)
  local out = jj(root, { "log", "--no-graph", "-r", revset or "@", "-T", template })
  local v = out[1]
  return (v and v ~= "") and v or nil
end

--- Workspace root containing the cwd, or nil (async).
---@return string?
function M.repo_root()
  local out = sh.sh({ "jj", "--ignore-working-copy", "root" })
  local root = out[1]
  return (root and root ~= "") and root or nil
end

--- Is `root` a jj workspace?
---@param root string
---@return boolean
function M.is_repo(root)
  return (vim.uv or vim.loop).fs_stat(root .. "/.jj") ~= nil
end

--- The directories a caller should watch to notice the change moving, plus the
--- repo's name.
---
--- One directory does it: `.jj/repo/op_heads/heads` holds a single file, renamed
--- by every jj operation. HEAD and refs stay put under jj (a colocated repo's
--- git HEAD is detached and only moves on export), so watching the git dirs
--- would miss `jj new`, `jj edit`, an abandon, and every jjui action.
---
--- The name comes from the MAIN workspace, not this one: a secondary workspace's
--- own directory is named for its slug ("rkk-main-fork"), where the project is
--- what the label should say.
---@param root string
---@return string? git_dir, string? common_dir, string? repo
function M.dirs(root)
  local heads = root .. "/.jj/repo/op_heads/heads"
  return heads, heads, vim.fs.basename(M.origin(root))
end

--- The MAIN workspace's root for the repo `root` belongs to. `.jj/repo` is a
--- directory there and a file pointing at it in every secondary workspace.
---@param root string
---@return string
function M.origin(root)
  local uv = vim.uv or vim.loop
  local repo = root .. "/.jj/repo"
  local stat = uv.fs_stat(repo)
  if not stat or stat.type == "directory" then
    return root
  end
  local f = io.open(repo, "r")
  if not f then
    return root
  end
  local target = vim.trim(f:read("*a") or "")
  f:close()
  if target == "" then
    return root
  end
  return vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(root .. "/.jj/" .. target)))
end

--- What the change is called, what it is, and what it tracks.
---
--- jj has no current branch. The nearest bookmark at or under the working copy
--- is the closest thing -- a fresh change on top of `feat/x` carries no bookmark
--- of its own but IS the work on feat/x -- and its remote, if it has one, is the
--- upstream.
---@param root string
---@return string? branch, string? head, string? upstream
function M.head(root)
  local branch = field(root, 'bookmarks.join(",")', "latest(heads(::@ & bookmarks()), 1)")
  branch = branch and vim.split(branch, ",", { plain = true })[1] or nil
  local head = field(root, "change_id.shortest(8)")
  local upstream
  if branch then
    local remotes = jj(root, {
      "bookmark",
      "list",
      "--all-remotes",
      "-T",
      'if(remote && remote != "git" && name == "' .. branch .. '", remote ++ "\n", "")',
    })
    if remotes[1] then
      upstream = branch .. "@" .. remotes[1]
    end
  end
  return branch, head, upstream
end

--- behind, ahead across `ref` and the working copy.
---@param root string
---@param ref string revset
---@return integer? behind, integer? ahead
function M.span(root, ref)
  local safe = "present(" .. ref .. ")"
  if count(root, safe) == 0 then
    return nil, nil
  end
  -- `base..@` is what @ has and the base doesn't -- ahead. The mirror image is
  -- behind. Returned behind-first to match the git backend's rev-list order.
  return count(root, "@.." .. safe), count(root, safe .. "..@")
end

--- The revision the change is reviewed against.
---
--- jj answers this directly with `trunk()`: the default branch of the remote,
--- falling back to a local main/master. It replaces the whole
--- origin/HEAD -> origin/main -> main -> master cascade the git backend walks.
---@param root string
---@param configured string? opts.base, if the user set one
---@return string?
function M.default_base(root, configured)
  if configured and configured ~= "" then
    if count(root, "present(" .. configured .. ")") > 0 then
      return configured
    end
    return nil
  end
  return count(root, "present(trunk())") > 0 and "trunk()" or nil
end

--- Resolve a revset to a stable id (used only as a cache key).
---@param root string
---@param ref string
---@return string?
function M.rev(root, ref)
  return field(root, "commit_id", "present(" .. ref .. ")")
end

--- Files this change is responsible for, relative to `base`.
---
--- One command, and no merge-result machinery: the git backend has to build a
--- merged tree so that files changed to content the base already has drop out,
--- because a git branch can sit behind its base. jj rebases instead of merging,
--- so `@` is already expressed on top of trunk and a plain two-point diff has
--- the same meaning.
---@param root string
---@param base string revset
---@return table<string, true>?
function M.changed(root, base)
  local lines, code = jj(root, { "diff", "--from", base, "--to", "@", "--summary" })
  if code ~= 0 then
    return nil
  end
  local files = {}
  for _, line in ipairs(lines) do
    -- "<letter> <path>"; D(eleted) files have nothing to open or review.
    local status, rel = line:match("^(%a) (.+)$")
    if rel and status ~= "D" then
      files[rel] = true
    end
  end
  return files
end

--- How many files the working copy changes (the "uncommitted" count).
---
--- Against `@-`, which is jj's equivalent of "not committed yet": @ is itself a
--- commit, so there is no index or untracked set to ask about separately.
---@param root string
---@return integer
function M.dirty(root)
  local lines = jj(root, { "diff", "--from", "@-", "--to", "@", "--summary" })
  return #lines
end

--- Content hashes for many working-tree files (rel -> hash).
---
--- Computed in-process: jj has no `hash-object`, and the ledger only needs a
--- stable hash of the bytes to know a decided file was edited since.
---@param root string
---@param rels string[]
---@return table<string, string>
function M.hashes(root, rels)
  local out = {}
  for _, rel in ipairs(rels) do
    local hash = sh.file_hash(root .. "/" .. rel)
    if hash then
      out[rel] = hash
    end
  end
  return out
end

--- Content hash of one working-tree file, or nil.
---@param root string
---@param rel string
---@return string?
function M.hash(root, rel)
  return sh.file_hash(root .. "/" .. rel)
end

--- Drop generated files from a review list.
---
--- git reads `linguist-generated`/`generated` gitattributes for this; jj has no
--- attribute system, so everything is reviewable. Returning the list unchanged
--- errs the same way the git backend does when check-attr fails: show the files
--- rather than silently hide them.
---@param _root string
---@param rels string[]
---@return string[]
function M.filter_generated(_root, rels)
  return rels
end

--- Snapshot the working copy into @, so the queries above (which never
--- snapshot) see saved edits. The only command here that writes an operation --
--- see the note at the top of this file.
---
--- A secondary workspace can go STALE -- another workspace rewrote the commit
--- this one sits on, which happens routinely while working in the main
--- workspace. Every snapshotting command then refuses until `jj workspace
--- update-stale` is run. That recovery touches files on disk, so it is the
--- user's call, not something an editor refresh should do behind their back;
--- the read-only queries all still work (they pass --ignore-working-copy), so
--- the report stays correct about the change and only stops noticing brand-new
--- edits. Say so once per root rather than failing mute.
---@param root string
function M.snapshot(root)
  local out, code = sh.sh({ "jj", "--color=never", "--no-pager", "-R", root, "util", "snapshot" })
  local stale = false
  for _, line in ipairs(out) do
    if line:find("working copy is stale", 1, true) then
      stale = true
    end
  end
  -- jj reports this on stderr, which sh() drops, so a non-zero exit with no
  -- output is treated the same way: something stopped the snapshot.
  if (stale or code ~= 0) and not warned_stale[root] then
    warned_stale[root] = true
    vim.schedule(function()
      vim.notify(
        "triage: jj working copy is stale in " .. vim.fs.basename(root) .. "\nrun `jj workspace update-stale` to catch it up",
        vim.log.levels.WARN
      )
    end)
  end
  if not stale and code == 0 then
    warned_stale[root] = nil
  end
end

return M
