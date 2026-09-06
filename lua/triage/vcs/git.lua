-- The git backend: the queries triage has always run, behind the shared VCS
-- interface so the jj backend can stand beside them (see vcs/init.lua).
--
-- Nothing here changed in being moved; the commands are the ones this plugin has
-- always used, including the merge-result diff that the jj backend doesn't need.

local sh = require("triage.vcs.sh")

local M = {}

--- Directory that marks a repo root, for the synchronous lookups.
M.marker = ".git"

--- Run git in `root` (async).
---@param root string
---@param args string[]
---@return string[]
local function git(root, args)
  local cmd = { "git", "-C", root }
  vim.list_extend(cmd, args)
  return (sh.sh(cmd))
end

--- Toplevel of the repo containing cwd, or nil if not in a work tree (async).
---@return string?
function M.repo_root()
  local out = sh.sh({ "git", "rev-parse", "--show-toplevel" })
  local root = out[1]
  return (root and root ~= "") and root or nil
end

--- Is `root` inside a git work tree?
---@param root string
---@return boolean
function M.is_repo(root)
  return #git(root, { "rev-parse", "--git-dir" }) > 0
end

--- The directories to watch for "the branch moved", plus the repo's name.
---
--- For a linked worktree the two differ: the git dir is the worktree's own
--- (HEAD, index, reflog), the common dir is the MAIN checkout's .git (refs,
--- packed-refs, FETCH_HEAD). The common dir's parent names the repo -- "ionics",
--- not the worktree directory "rkk-some-branch".
---@param root string
---@return string? git_dir, string? common_dir, string? repo
function M.dirs(root)
  local dirs = git(root, { "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir" })
  local git_dir = dirs[1] and vim.fs.normalize(dirs[1]) or nil
  local common = dirs[2] and vim.fs.normalize(dirs[2]) or nil
  return git_dir, common, common and vim.fn.fnamemodify(common, ":h:t") or nil
end

--- Branch, short HEAD, and upstream.
---@param root string
---@return string? branch, string? head, string? upstream
function M.head(root)
  return git(root, { "symbolic-ref", "--quiet", "--short", "HEAD" })[1],
    git(root, { "rev-parse", "--short", "HEAD" })[1],
    git(root, { "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}" })[1]
end

--- behind, ahead across `ref...HEAD` (nil if the ref doesn't resolve).
---@param root string
---@param ref string
---@return integer? behind, integer? ahead
function M.span(root, ref)
  local out = git(root, { "rev-list", "--left-right", "--count", ref .. "...HEAD" })[1]
  if not out then
    return nil, nil
  end
  local behind, ahead = out:match("^(%d+)%s+(%d+)$")
  return tonumber(behind), tonumber(ahead)
end

--- Best guess at the branch we're reviewing against.
---@param root string
---@param configured string? opts.base, if the user set one
---@return string?
function M.default_base(root, configured)
  -- An explicitly configured base wins over auto-detection (opts.base, e.g.
  -- "develop"); accept it bare or as an origin/ ref, whichever resolves first.
  if configured and configured ~= "" then
    for _, candidate in ipairs({ configured, "origin/" .. configured }) do
      if #git(root, { "rev-parse", "--verify", "--quiet", candidate }) > 0 then
        return candidate
      end
    end
    return nil
  end
  -- Prefer the remote's advertised default (origin/HEAD -> origin/main|master).
  local head = git(root, { "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD" })[1]
  if head and head ~= "" then
    return head
  end
  for _, candidate in ipairs({ "origin/main", "origin/master", "main", "master" }) do
    if #git(root, { "rev-parse", "--verify", "--quiet", candidate }) > 0 then
      return candidate
    end
  end
  return nil
end

--- Resolve a ref to its commit sha (cheap; used for cache keys).
---@param root string
---@param ref string
---@return string?
function M.rev(root, ref)
  local sha = git(root, { "rev-parse", "--verify", "--quiet", ref })[1]
  return (sha and sha ~= "") and sha or nil
end

--- Tree oid of merging HEAD into `branch`, or nil.
local function merged_tree(root, branch)
  -- `--write-tree` writes the merged tree and prints its oid on the first line.
  -- On a conflicted merge git exits non-zero but still prints the tree oid first;
  -- sh() keeps stdout regardless of exit code, so git() is fine here.
  local out = git(root, { "merge-tree", "--write-tree", branch, "HEAD" })
  local tree = out[1]
  if not tree or not tree:match("^%x%x%x%x%x%x%x") then
    return nil
  end
  return tree
end

-- Cache of the expensive merge-result step, keyed by the two commits it depends
-- on. The merge tree -- and therefore the set of files the merge changes -- only
-- moves when HEAD or the base branch moves, so on a focus/save where neither
-- changed we skip `git merge-tree` (seconds on a big monorepo) entirely.
---@type { root: string, base: string, head: string, files: table<string, boolean> }?
local merge_cache = nil

--- Files this branch is responsible for, relative to `base`.
---
--- The merge-result diff, so files the branch changed to content the base
--- already has don't appear -- then the cheap working-tree additions on top.
---@param root string
---@param base string
---@return table<string, true>?
function M.changed(root, base)
  local base_sha, head_sha = M.rev(root, base), M.rev(root, "HEAD")
  if not base_sha or not head_sha then
    return nil
  end
  local committed
  if
    merge_cache
    and merge_cache.root == root
    and merge_cache.base == base_sha
    and merge_cache.head == head_sha
  then
    committed = merge_cache.files
  else
    local tree = merged_tree(root, base)
    if not tree then
      return nil
    end
    committed = {}
    for _, rel in ipairs(git(root, { "diff", "--name-only", "--diff-filter=d", base, tree })) do
      committed[rel] = true
    end
    merge_cache = { root = root, base = base_sha, head = head_sha, files = committed }
  end

  local changed = {}
  for rel in pairs(committed) do
    changed[rel] = true
  end
  -- The cheap git calls, and they change on save, so they're recomputed every
  -- time rather than cached.
  for _, rel in ipairs(git(root, { "diff", "--name-only", "--diff-filter=d", "HEAD" })) do
    changed[rel] = true
  end
  for _, rel in ipairs(git(root, { "ls-files", "--others", "--exclude-standard" })) do
    changed[rel] = true
  end
  return changed
end

--- How many paths the working tree changes (the "uncommitted" count).
---@param root string
---@return integer
function M.dirty(root)
  return #git(root, { "status", "--porcelain", "--untracked-files=normal" })
end

--- Blob hashes for many working-tree files in ONE git process (rel -> hash),
--- instead of a spawn per file -- refresh needs a hash for every decided file,
--- which is O(review size) on every save otherwise. `--stdin-paths` prints one
--- hash per input line in order, so the result aligns by index; but it aborts
--- on the first unreadable path, misaligning the rest, so a non-zero exit falls
--- back to per-file hashing (which simply skips the unreadable ones).
---@param root string
---@param rels string[]
---@return table<string, string>
function M.hashes(root, rels)
  local out = {}
  if #rels == 0 then
    return out
  end
  local lines, code =
    sh.sh({ "git", "-C", root, "hash-object", "--stdin-paths" }, table.concat(rels, "\n") .. "\n")
  if code == 0 and #lines == #rels then
    for i, rel in ipairs(rels) do
      out[rel] = lines[i]
    end
    return out
  end
  for _, rel in ipairs(rels) do
    local hash = M.hash(root, rel)
    if hash then
      out[rel] = hash
    end
  end
  return out
end

--- Current blob hash of a working-tree file, or nil.
---@param root string
---@param rel string
---@return string?
function M.hash(root, rel)
  local hash = git(root, { "hash-object", "--", rel })[1]
  return (hash and hash ~= "") and hash or nil
end

--- Drop generated files from a review list.
---
--- One `git check-attr` process for the whole list, not one per file. Its output
--- is `<path>: <attr>: <value>` and a path may itself contain ": ", so each line
--- is parsed from the right.
---@param root string
---@param rels string[]
---@return string[]
function M.filter_generated(root, rels)
  if #rels == 0 then
    return rels
  end
  local lines, code = sh.sh({
    "git",
    "-C",
    root,
    "check-attr",
    "--stdin",
    "linguist-generated",
    "generated",
  }, table.concat(rels, "\n") .. "\n")
  -- On any trouble, review everything rather than silently hiding files.
  if code ~= 0 then
    return rels
  end
  local generated = {}
  for _, line in ipairs(lines) do
    local rel, _, value = line:match("^(.*): ([^:]+): (.*)$")
    if rel and (value == "set" or value == "true") then
      generated[rel] = true
    end
  end
  local kept = {}
  for _, rel in ipairs(rels) do
    if not generated[rel] then
      kept[#kept + 1] = rel
    end
  end
  return kept
end

--- Nothing to snapshot: git's working tree is already what the queries read.
function M.snapshot() end

return M
