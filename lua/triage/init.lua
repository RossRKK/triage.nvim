-- triage.nvim — branch "review mode".
--
-- Treats the branch as a review unit: "under review" is what merging this branch
-- into the default branch would actually change (the merge-result diff), so a
-- change the default branch already has — even one the branch made independently
-- — is not flagged. Two surfaces consume this:
--   * gitsigns, based on the default-branch tip so its sign-column marks show the
--     lines that differ from what's already there (see lua/plugins/git.lua).
--   * the file explorer, which colours changed files via a renderer component
--     behind triage/adapter (see triage/adapter/neotree.lua).
--
-- The file list combines the merge-result diff (committed branch work) with your
-- uncommitted changes and untracked files, so you can review before committing.
--
-- Files can be triaged: marked "approved" (looked at, fine) or "rejected"
-- (flagged to come back to). Either records the file's current blob hash. An
-- approved file that's edited again flips back to "changed" (re-review it fresh);
-- a rejected file that's edited becomes "revised" — the flag was acted on, so
-- re-review the fix — keeping the fact you'd flagged it rather than losing it.
--
-- This module knows nothing about PR comments. A companion plugin (nitpick.nvim)
-- draws GitHub review comments; wiring the two together — one toggle drives both,
-- and the comment plugin borrows M.verdict as its submit event — lives in user
-- config via the setup() hooks below (opts.on_toggle) and M.verdict, not here.

local M = {}

-- User configuration, populated by M.setup(). See setup() for the accepted keys.
M.opts = {}

-- Status -> glyph and highlight group. Public so every surface that shows a
-- triage status — the explorer component, a dashboard, a statusline — draws the
-- same mark in the same colour. The groups are defined in setup's set_hl.
M.icons = {
  changed = { text = "\xe2\x97\x8f", hl = "ReviewChanged" }, -- ●
  approved = { text = "\xe2\x9c\x93", hl = "ReviewApproved" }, -- ✓
  rejected = { text = "\xe2\x9c\x97", hl = "ReviewRejected" }, -- ✗
  revised = { text = "\xe2\x86\xbb", hl = "ReviewRevised" }, -- ↻
}

-- Absolute path -> "changed"|"approved"|"rejected"|"revised", rebuilt on refresh.
M.status_by_path = {}

-- Directory absolute path -> rolled-up status of its descendants (the highest-
-- priority child status; see do_refresh for the ordering).
M.folder_status = {}

-- Review state is keyed by repo root, not held globally: a review is a property
-- of one repo, and (in a one-project-per-tab setup) switching tabs changes the
-- cwd — a single global toggle/base would make that switch re-run the review
-- against whichever repo the new tab is in, and re-base gitsigns for buffers
-- whose repo can't even resolve the other repo's ref.

-- Repos with review mode turned on: normalized root -> true. Defaults off;
-- toggled per repo with <leader>rt.
M.enabled_roots = {}

-- Active reviews: normalized root -> the branch being diffed against (the
-- resolved review base). Absent while that repo's review is inactive.
M.reviews = {}

-- User-chosen branches to review against, overriding auto-detection: normalized
-- root -> ref. Absent = auto (origin/HEAD, else main/master). <leader>rb.
M.target_override = {}

local uv = vim.uv or vim.loop

--- Normalized repo root containing the cwd, or nil. Sync (no git process) so
--- the statusline and toggle can use it; walks the literal path, so unlike
--- `git rev-parse` it won't see through a symlinked cwd.
---@return string?
local function cwd_root()
  local root = vim.fs.root(vim.fn.getcwd(), ".git")
  return root and vim.fs.normalize(root) or nil
end

--- Is review mode on for a repo (default: the cwd's)?
---@param root string?
---@return boolean
function M.is_enabled(root)
  root = root or cwd_root()
  return (root and M.enabled_roots[root]) == true
end

--- Run a command asynchronously, yielding the current coroutine until it exits.
--- MUST be called from within a coroutine (refresh/mark drive one). Returns the
--- stdout lines and the exit code; stdout is returned even on a non-zero exit so
--- callers like merged_tree can read a conflicted merge's tree oid.
---@param cmd string[]
---@param stdin string? fed to the process (used to batch hash-object paths)
---@return string[] lines, integer code
local function sh(cmd, stdin)
  local co = assert(coroutine.running(), "review: git must run inside a coroutine")
  -- No optional locks: everything run here is a read-only query, but git status
  -- opportunistically refreshes the index, and that lock-file churn is visible
  -- to anything watching the git dir -- including watchers (the greeter's) that
  -- respond by asking for another report, a permanent feedback loop.
  vim.system(
    cmd,
    { text = true, stdin = stdin, env = { GIT_OPTIONAL_LOCKS = "0" } },
    function(obj)
    vim.schedule(function()
      local lines = {}
      for line in (obj.stdout or ""):gmatch("[^\r\n]+") do
        lines[#lines + 1] = line
      end
      coroutine.resume(co, lines, obj.code)
    end)
  end)
  return coroutine.yield()
end

--- Run git in `root` (async).
---@param root string
---@param args string[]
---@return string[]
local function git(root, args)
  local cmd = { "git", "-C", root }
  vim.list_extend(cmd, args)
  return (sh(cmd))
end

--- Toplevel of the repo containing cwd, or nil if not in a work tree (async).
---@return string?
local function repo_root()
  local out = sh({ "git", "rev-parse", "--show-toplevel" })
  local root = out[1]
  return (root and root ~= "") and root or nil
end

--- Best guess at the branch we're reviewing against.
---@param root string
---@return string?
local function default_branch(root)
  -- An explicitly configured base wins over auto-detection (opts.base, e.g.
  -- "develop"); accept it bare or as an origin/ ref, whichever resolves first.
  if M.opts.base and M.opts.base ~= "" then
    for _, candidate in ipairs({ M.opts.base, "origin/" .. M.opts.base }) do
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

--- The branch the current branch is reviewed against: the user's override if set
--- (<leader>rb / :ReviewBase), else the auto-detected default branch.
---@param root string normalized
---@return string?
local function review_branch(root)
  return M.target_override[root] or default_branch(root)
end

--- The tree that would result from merging HEAD into the default branch — i.e.
--- the content of the merge commit you'd get by merging this branch. Returns the
--- tree object id, or nil.
---
--- This is the "what the merge actually applies" view: a file the branch changed
--- to content the default branch already reached contributes nothing, and a file
--- only the default branch changed is taken from there, so neither shows up as a
--- branch change. (Contrast the three-dot merge-base diff GitHub renders, which
--- would still show the former.)
---@param root string
---@param branch string default-branch ref
---@return string?
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

-- ---------------------------------------------------------------------------
-- Decision persistence (per repo, under stdpath("state")/review/).
-- A decision records that a changed file was triaged: marked "approved" (looked
-- at, fine) or "rejected" (looked at, flagged to come back to), together with
-- the blob hash it had at the time so the decision self-invalidates on re-edit.
-- File format: one "<status> <blob-hash> <relative/path>" per line. Legacy files
-- (just "<blob-hash> <relative/path>") are read as approved decisions.
-- ---------------------------------------------------------------------------

---@alias ReviewStatus "approved"|"rejected"
---@class Decision
---@field status ReviewStatus
---@field hash string blob hash recorded when the decision was made

local function state_dir()
  local dir = vim.fn.stdpath("state") .. "/review"
  vim.fn.mkdir(dir, "p")
  return dir
end

-- Sanitise the repo path into a single filename component. Dots are escaped
-- along with the separators and a ".triage" suffix is added so this file can
-- never collide with a sibling plugin's state for a *different* repo (nitpick's
-- "<key>.drafts" in the same directory: without dot-escaping, the suffix-less
-- file for a repo literally named "/a/b.drafts" would be nitpick's drafts file
-- for "/a/b"). nitpick escapes identically — kept in sync by convention, not a
-- shared module, so the plugins stay separable.
---@param root string
---@return string
local function decisions_file(root)
  local key = root:gsub("[/\\:.]", "%%")
  return state_dir() .. "/" .. key .. ".triage"
end

--- Load decisions: relative path -> Decision.
---@param root string
---@return table<string, Decision>
local function load_decisions(root)
  local decisions = {}
  local path = decisions_file(root)
  if vim.fn.filereadable(path) == 0 then
    -- Fall back to the pre-suffix filename so existing decisions survive the
    -- rename; the next save writes the new path.
    local legacy = state_dir() .. "/" .. root:gsub("[/\\:]", "%%")
    if legacy ~= path and vim.fn.filereadable(legacy) == 1 then
      path = legacy
    else
      return decisions
    end
  end
  for _, line in ipairs(vim.fn.readfile(path)) do
    -- Blob hashes are hex, so a leading "approved"/"rejected" word is
    -- unambiguously the status field and not a legacy hash. ("reviewed" is
    -- accepted as an alias for approved, the status's former name.)
    local status, rest = line:match("^(%a+)%s+(.+)$")
    if status == "approved" or status == "reviewed" or status == "rejected" then
      local hash, rel = rest:match("^(%S+)%s+(.+)$")
      if hash and rel then
        decisions[rel] = { status = status == "rejected" and "rejected" or "approved", hash = hash }
      end
    else
      local hash, rel = line:match("^(%S+)%s+(.+)$")
      if hash and rel then
        decisions[rel] = { status = "approved", hash = hash }
      end
    end
  end
  return decisions
end

---@param root string
---@param decisions table<string, Decision>
local function save_decisions(root, decisions)
  local lines = {}
  for rel, decision in pairs(decisions) do
    table.insert(lines, decision.status .. " " .. decision.hash .. " " .. rel)
  end
  table.sort(lines)
  vim.fn.writefile(lines, decisions_file(root))
end

--- Current blob hash of a working-tree file, or nil.
---@param root string
---@param rel string
---@return string?
local function blob_hash(root, rel)
  local hash = git(root, { "hash-object", "--", rel })[1]
  if not hash or hash == "" then
    return nil
  end
  return hash
end

--- Blob hashes for many working-tree files in ONE git process (rel -> hash),
--- instead of a spawn per file — refresh needs a hash for every decided file,
--- which is O(review size) on every save otherwise. `--stdin-paths` prints one
--- hash per input line in order, so the result aligns by index; but it aborts
--- on the first unreadable path, misaligning the rest, so a non-zero exit falls
--- back to per-file hashing (which simply skips the unreadable ones).
---@param root string
---@param rels string[]
---@return table<string, string>
local function blob_hashes(root, rels)
  local out = {}
  if #rels == 0 then
    return out
  end
  local lines, code =
    sh({ "git", "-C", root, "hash-object", "--stdin-paths" }, table.concat(rels, "\n") .. "\n")
  if code == 0 and #lines == #rels then
    for i, rel in ipairs(rels) do
      out[rel] = lines[i]
    end
    return out
  end
  for _, rel in ipairs(rels) do
    out[rel] = blob_hash(root, rel)
  end
  return out
end

--- Resolve a ref to its commit sha (cheap; used for cache keys).
---@param root string
---@param ref string
---@return string?
local function rev(root, ref)
  local sha = git(root, { "rev-parse", "--verify", "--quiet", ref })[1]
  return (sha and sha ~= "") and sha or nil
end

-- Cache of the expensive merge-result step, keyed by the two commits it depends
-- on. The merge tree — and therefore the set of files the merge changes — only
-- moves when HEAD or the base branch moves, so on a focus/save where neither
-- changed we skip `git merge-tree` (seconds on a big monorepo) entirely.
---@type { root: string, base: string, head: string, files: table<string, boolean> }?
local merge_cache = nil

--- Files the merge of HEAD into `branch` would change vs the branch tip, as a
--- rel-path set. Memoised on (root, base sha, head sha).
---@param root string
---@param branch string
---@param base_sha string
---@param head_sha string
---@return table<string, boolean>?
local function committed_changed(root, branch, base_sha, head_sha)
  if
    merge_cache
    and merge_cache.root == root
    and merge_cache.base == base_sha
    and merge_cache.head == head_sha
  then
    return merge_cache.files
  end

  local tree = merged_tree(root, branch)
  if not tree then
    return nil
  end
  local files = {}
  for _, rel in ipairs(git(root, { "diff", "--name-only", "--diff-filter=d", branch, tree })) do
    files[rel] = true
  end
  merge_cache = { root = root, base = base_sha, head = head_sha, files = files }
  return files
end

-- ---------------------------------------------------------------------------

-- Bumped on every refresh; an in-flight async run whose generation is stale
-- (a newer refresh started) discards its results instead of clobbering state.
local refresh_gen = 0

--- Is `path` equal to or under `root` (both normalized)?
---@param path string
---@param root string
---@return boolean
local function under(path, root)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

--- Clear one repo's review state and reset its gitsigns base; used by the
--- inactive paths. Other repos' reviews are untouched.
---@param root string normalized
local function deactivate(root)
  for path in pairs(M.status_by_path) do
    if under(path, root) then
      M.status_by_path[path] = nil
    end
  end
  for path in pairs(M.folder_status) do
    if under(path, root) then
      M.folder_status[path] = nil
    end
  end
  M.reviews[root] = nil
  require("triage.gitsigns").set_base(root, nil)
  M.redraw_tree()
end

--- Drop generated files from a rel-path list, by gitattribute. A repo that
--- marks its generated output (`*.pb.go linguist-generated=true`, the attribute
--- GitHub itself collapses diffs on; plain `generated` is honoured too) is
--- telling us those files aren't for a human to read — and in a repo with a
--- large codegen step they'd otherwise swamp the review with files nobody wrote.
---
--- One `git check-attr` process for the whole list, not one per file. Its output
--- is `<path>: <attr>: <value>` and a path may itself contain ": ", so each line
--- is parsed from the right.
---@param root string
---@param rels string[]
---@return string[]
local function drop_generated(root, rels)
  if #rels == 0 then
    return rels
  end
  local lines, code = sh({
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
    -- "set" for a bare attribute, the literal value for `attr=value`; anything
    -- else ("unspecified", "unset", "false") leaves the file in the review.
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

--- The files under review in `root`: what merging HEAD into `branch` would
--- change, plus the uncommitted work (staged + unstaged edits, and untracked
--- files) so you can review changes before committing them. Async; nil if the
--- merge-result diff can't be computed.
---@param root string
---@param branch string ref to review against
---@return table<string, boolean>? rel path -> true
local function changed_files(root, branch)
  local base_sha = rev(root, branch)
  local head_sha = rev(root, "HEAD")
  -- The merge-result diff, so files the branch changed to content the base
  -- already has don't appear. Cached on the two shas, so it's free (no git)
  -- when neither HEAD nor the base has moved since the last call.
  local committed = base_sha and head_sha and committed_changed(root, branch, base_sha, head_sha)
  if not committed then
    return nil
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
  local rels = vim.tbl_keys(changed)
  changed = {}
  for _, rel in ipairs(drop_generated(root, rels)) do
    changed[rel] = true
  end
  return changed
end

--- Apply the decision ledger to a changed-file set: each file's triage status,
--- plus the decisions still worth keeping (a caller that owns the ledger prunes
--- to this; a read-only caller ignores it). Async — hashes every decided file in
--- one git call rather than a process per file.
---@param root string
---@param changed table<string, boolean> rel path -> true
---@return table<string, string> status abs path -> status
---@return table<string, Decision> keep decisions still worth recording
---@return table<string, Decision> loaded the ledger as it was read
local function decide(root, changed)
  local decisions = load_decisions(root)
  local status_by_path = {}
  local keep = {}

  local decided = {}
  for rel in pairs(changed) do
    if decisions[rel] then
      decided[#decided + 1] = rel
    end
  end
  local hashes = blob_hashes(root, decided)

  for rel in pairs(changed) do
    local abs = vim.fs.normalize(root .. "/" .. rel)
    local decision = decisions[rel]
    if not decision then
      status_by_path[abs] = "changed"
    else
      local matches = decision.hash == hashes[rel]
      if decision.status == "rejected" then
        -- Keep the rejection on record either way: an edited-since rejected file
        -- becomes "revised" (the flag was acted on — re-review the fix), not a
        -- plain "changed" that would lose the fact you'd flagged it.
        status_by_path[abs] = matches and "rejected" or "revised"
        keep[rel] = decision
      elseif matches then
        status_by_path[abs] = "approved"
        keep[rel] = decision
      else
        -- Approved file edited again: just needs a fresh look; drop the record.
        status_by_path[abs] = "changed"
      end
    end
  end
  return status_by_path, keep, decisions
end

--- The async body of a refresh. Runs inside a coroutine; every git() call yields
--- without blocking the UI. Builds new state in locals and only commits it at the
--- end, so a partial run never leaves half-updated tables on screen.
---@param mygen integer generation this run belongs to
local function do_refresh(mygen)
  local function stale()
    return mygen ~= refresh_gen
  end

  local root = repo_root()
  if stale() then
    return
  end
  -- Outside any repo there's nothing to recompute — and nothing to clear:
  -- other repos' reviews are theirs, not this refresh's.
  if not root then
    return
  end
  local nroot = vim.fs.normalize(root)
  if not M.enabled_roots[nroot] then
    return deactivate(nroot)
  end

  local branch = review_branch(nroot)
  local changed = branch and changed_files(root, branch)
  if stale() then
    return
  end
  if not branch or not changed then
    return deactivate(nroot)
  end

  local status_by_path, still, decisions = decide(root, changed)
  if stale() then
    return
  end

  -- Roll each file's status up to its ancestor directories, taking the highest-
  -- priority descendant status, ordered by what needs the reviewer's attention:
  --   revised > changed > rejected > approved
  -- revised (a fix awaiting re-review) and changed (untriaged) are the reviewer's
  -- queue, so a folder surfaces those first — collapsing it must not read as done
  -- while work remains inside. rejected is waiting on the author, not the
  -- reviewer, but still outranks approved so an open flag never hides under a
  -- folder that reads as done; a folder only goes approved once every changed
  -- descendant is approved.
  local priority = { approved = 1, rejected = 2, changed = 3, revised = 4 }
  local folder_status = {}
  for abs, st in pairs(status_by_path) do
    local dir = vim.fs.dirname(abs)
    while dir and #dir >= #nroot and (dir == nroot or dir:sub(1, #nroot + 1) == nroot .. "/") do
      local current = folder_status[dir]
      if not current or priority[st] > priority[current] then
        folder_status[dir] = st
      end
      if dir == nroot then
        break
      end
      dir = vim.fs.dirname(dir)
    end
  end

  -- Commit the freshly built state in one pass: replace this repo's slice of
  -- the merged tables, leaving other repos' entries alone.
  for path in pairs(M.status_by_path) do
    if under(path, nroot) then
      M.status_by_path[path] = nil
    end
  end
  for path in pairs(M.folder_status) do
    if under(path, nroot) then
      M.folder_status[path] = nil
    end
  end
  for path, st in pairs(status_by_path) do
    M.status_by_path[path] = st
  end
  for path, st in pairs(folder_status) do
    M.folder_status[path] = st
  end
  M.reviews[nroot] = branch
  -- Drop decisions for files that no longer differ (e.g. after a rebase).
  if next(decisions) then
    save_decisions(root, still)
  end
  -- Per-line signs: diff the buffer against the default-branch tip, so a line
  -- that matches what's already on the branch shows no sign — consistent with
  -- the merge-result file list above.
  require("triage.gitsigns").set_base(nroot, branch)
  M.redraw_tree()
end

--- Recompute review status without blocking the UI. Returns immediately; the
--- work runs on an async coroutine and applies its results when done.
function M.refresh()
  refresh_gen = refresh_gen + 1
  local mygen = refresh_gen
  coroutine.wrap(function()
    local ok, err = pcall(do_refresh, mygen)
    if not ok then
      vim.notify("review: refresh failed: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)()
end

--- Set the branch to review against, or clear back to auto-detection. Validates
--- the ref resolves before adopting it, then refreshes so the file list, signs
--- and inline diff all move to the new base.
---@param ref string? branch/commit-ish, or nil/"" to clear
function M.set_target(ref)
  if ref then
    ref = vim.trim(ref)
    if ref == "" then
      ref = nil
    end
  end
  coroutine.wrap(function()
    local root = repo_root()
    if not root then
      return vim.notify("review: not in a git repo", vim.log.levels.WARN)
    end
    if ref and not rev(root, ref) then
      return vim.notify("review: no such ref: " .. ref, vim.log.levels.ERROR)
    end
    M.target_override[vim.fs.normalize(root)] = ref
    vim.notify("review target: " .. (ref or "auto"))
    M.refresh()
  end)()
end

--- Status for an absolute path: "changed"|"approved"|"rejected"|"revised"|nil.
---@param abs string?
---@return string?
function M.status(abs)
  if not abs then
    return nil
  end
  return M.status_by_path[vim.fs.normalize(abs)]
end

--- Rolled-up status for a directory (same set as M.status), or nil.
---@param abs string?
---@return string?
function M.folder(abs)
  if not abs then
    return nil
  end
  return M.folder_status[vim.fs.normalize(abs)]
end

--- The review verdict implied by the current triage state, as a GitHub review
--- event. This is the same rollup the tree uses, taken all the way to the repo
--- root: the highest-priority status across every changed file wins, in the same
--- attention order (revised > changed > rejected > approved). Read as a verdict
--- that means: while any file is still untriaged ("changed") or awaiting a
--- re-review ("revised"), you're mid-review, so it's COMMENT — a batch of notes
--- with no standing verdict; only once nothing's pending does a live rejection
--- surface as REQUEST_CHANGES, or an all-approved tree as APPROVE. So an early,
--- partial submit never renders a premature verdict. nil when nothing's changed.
--- Scoped to one repo (default: the cwd's), since the status table now holds
--- every reviewed repo; with no resolvable root, every entry counts.
---@param root string? repo root to scope to
---@return "APPROVE"|"REQUEST_CHANGES"|"COMMENT"|nil
function M.verdict(root)
  root = root or cwd_root()
  local priority = { approved = 1, rejected = 2, changed = 3, revised = 4 }
  local worst
  for path, st in pairs(M.status_by_path) do
    if (not root or under(path, root)) and (not worst or priority[st] > priority[worst]) then
      worst = st
    end
  end
  if not worst then
    return nil
  elseif worst == "approved" then
    return "APPROVE"
  elseif worst == "rejected" then
    return "REQUEST_CHANGES"
  else
    return "COMMENT" -- changed or revised: still mid-review
  end
end

--- The review-mode status string for the statusline: the base being reviewed
--- against. Empty while review mode is off, so the statusline component collapses
--- to nothing. (The comment plugin contributes its own fragment separately; see
--- nitpick.statusline — the two are concatenated by the lualine config.)
---@return string
function M.statusline()
  local root = cwd_root()
  if not root or not M.enabled_roots[root] then
    return ""
  end
  local base = M.reviews[root] or M.target_override[root] or "…"
  -- Git-merge glyph (U+F419): the review diffs what merging into `base` would
  -- change, so a merge icon reads truer than a plain branch. Bytes, not the raw
  -- glyph, so it can't be lost when the file is edited.
  local merge = "\xef\x90\x99"
  return vim.trim(merge .. " " .. base)
end

---@class TriageReport
---@field root string normalized repo root (the worktree, not the main checkout)
---@field repo string repo name — the main checkout's directory, so every
---   worktree of a repo reports the same name rather than its worktree dir
---@field git_dir string? this worktree's git dir (HEAD, index, reflog)
---@field common_dir string? the shared git dir (refs, packed-refs, FETCH_HEAD);
---   the same as git_dir outside a linked worktree. Watch the two to know when
---   the branch has moved.
---@field branch string? current branch, nil when detached
---@field head string? short HEAD sha
---@field base string? the branch under review (the resolved review base)
---@field base_ahead integer? commits on HEAD not in base
---@field upstream string? tracking ref (e.g. "origin/rkk/thing"), nil if unset
---@field ahead integer? commits on HEAD not pushed to upstream
---@field behind integer? commits on upstream not in HEAD
---@field dirty integer files with uncommitted changes
---@field files { path: string, rel: string, status: string }[] under review,
---   sorted by path; status is the same set M.status returns
---@field counts table<string, integer> status -> number of files

--- Everything a branch overview needs, in one async pass: where the branch sits
--- relative to its remote and its review base, and the triaged file list.
---
--- This is M.refresh's view of the branch offered as a plain query — same
--- merge-result diff and same decision ledger — but computed for whichever repo
--- is asked about, without touching review state and regardless of whether
--- review mode is on there. That's what makes it usable from a dashboard: the
--- overview should read the same before you turn review mode on as after.
---
--- The callback runs on the main loop (vim.schedule'd), so it may touch the UI.
---@param opts? { root?: string } repo to report on; default the cwd's
---@param cb fun(report: TriageReport?) nil outside a git repo
function M.report(opts, cb)
  opts = opts or {}
  coroutine.wrap(function()
    local ok, err = pcall(function()
      local root = opts.root and vim.fs.normalize(opts.root) or nil
      -- No explicit root: resolve the cwd's via git, which (unlike cwd_root)
      -- sees through a symlinked cwd.
      if not root then
        local found = repo_root()
        root = found and vim.fs.normalize(found) or nil
      end
      if not root or #git(root, { "rev-parse", "--git-dir" }) == 0 then
        return vim.schedule(function()
          cb(nil)
        end)
      end

      -- Both git directories in one call. For a linked worktree they differ:
      -- the git dir is the worktree's own (HEAD, index, reflog), the common dir
      -- is the MAIN checkout's .git (refs, packed-refs, FETCH_HEAD). Reported as
      -- well as used here, so a caller can watch them for "the branch moved"
      -- without shelling out for the paths itself.
      local dirs =
        git(root, { "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir" })
      local git_dir = dirs[1] and vim.fs.normalize(dirs[1]) or nil
      local common = dirs[2] and vim.fs.normalize(dirs[2]) or nil
      -- The common dir's parent names the repo — "ionics", not the worktree
      -- directory "rkk-some-branch".
      local repo = common and vim.fn.fnamemodify(common, ":h:t") or nil

      local branch = git(root, { "symbolic-ref", "--quiet", "--short", "HEAD" })[1]
      local head = git(root, { "rev-parse", "--short", "HEAD" })[1]
      local upstream =
        git(root, { "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}" })[1]

      --- behind, ahead across `ref...HEAD` (nil if the ref doesn't resolve).
      local function span(ref)
        local out = git(root, { "rev-list", "--left-right", "--count", ref .. "...HEAD" })[1]
        if not out then
          return nil, nil
        end
        local behind, ahead = out:match("^(%d+)%s+(%d+)$")
        return tonumber(behind), tonumber(ahead)
      end

      local behind, ahead
      if upstream and upstream ~= "" then
        behind, ahead = span(upstream)
      else
        upstream = nil
      end

      local base = review_branch(root)
      local base_ahead
      if base then
        _, base_ahead = span(base)
      end

      local files, counts = {}, {}
      local changed = base and changed_files(root, base)
      if changed then
        local status_by_path = decide(root, changed)
        for rel in pairs(changed) do
          local abs = vim.fs.normalize(root .. "/" .. rel)
          local status = status_by_path[abs] or "changed"
          files[#files + 1] = { path = abs, rel = rel, status = status }
          counts[status] = (counts[status] or 0) + 1
        end
        table.sort(files, function(a, b)
          return a.rel < b.rel
        end)
      end

      local dirty = #git(root, { "status", "--porcelain", "--untracked-files=normal" })

      local report = {
        root = root,
        repo = repo,
        git_dir = git_dir,
        common_dir = common,
        branch = (branch and branch ~= "") and branch or nil,
        head = (head and head ~= "") and head or nil,
        base = base,
        base_ahead = base_ahead,
        upstream = upstream,
        ahead = ahead,
        behind = behind,
        dirty = dirty,
        files = files,
        counts = counts,
      }
      vim.schedule(function()
        cb(report)
      end)
    end)
    if not ok then
      vim.notify("review: report failed: " .. tostring(err), vim.log.levels.ERROR)
      vim.schedule(function()
        cb(nil)
      end)
    end
  end)()
end

--- The path the review action should act on: the node under the cursor when in
--- the explorer, otherwise the current buffer's file. nil if neither applies.
---@return string?
local function target_path()
  -- In the explorer, act on the node under the cursor; elsewhere, the buffer.
  local node = require("triage.adapter").cursor_path()
  if node then
    return node
  end
  local name = vim.api.nvim_buf_get_name(0)
  return name ~= "" and name or nil
end

--- Set the triage decision of a file or directory (recursively).
--- Defaults to the explorer node under the cursor / current buffer.
---@param status ReviewStatus|nil "approved"/"rejected", or nil to clear (untriage)
---@param abs string? target path
function M.mark(status, abs)
  -- Resolve the target from cursor/buffer state up front (sync), before the
  -- async git work below can move the cursor or change the current window.
  abs = abs or target_path()
  if not abs or abs == "" then
    return
  end
  abs = vim.fs.normalize(abs)
  local is_dir = vim.fn.isdirectory(abs) == 1

  -- Invalidate any in-flight refresh NOW: its decision pruning loaded the ledger
  -- before this mark writes, so letting it finish would save that stale set over
  -- the decision recorded below. Bumping the generation makes it discard itself
  -- at its next stale() check; the M.refresh() at the end re-runs it fresh.
  refresh_gen = refresh_gen + 1

  coroutine.wrap(function()
    local ok, err = pcall(function()
      local root = repo_root()
      if not root then
        vim.notify("review: not in a git repo", vim.log.levels.WARN)
        return
      end
      local nroot = vim.fs.normalize(root)

      -- Collect the changed files this action covers. For a directory, that's
      -- every changed descendant; for a file, just itself (if it's changed).
      local targets = {}
      if is_dir then
        for path in pairs(M.status_by_path) do
          if path == abs or path:sub(1, #abs + 1) == abs .. "/" then
            table.insert(targets, path)
          end
        end
      elseif M.status_by_path[abs] then
        table.insert(targets, abs)
      end

      if #targets == 0 then
        vim.notify("review: nothing changed here to mark", vim.log.levels.INFO)
        return
      end

      local decisions = load_decisions(root)
      local rels = {}
      for _, path in ipairs(targets) do
        rels[#rels + 1] = path:sub(#nroot + 2)
      end
      local hashes = status and blob_hashes(root, rels) or {}
      for _, rel in ipairs(rels) do
        if status then
          if hashes[rel] then
            decisions[rel] = { status = status, hash = hashes[rel] }
          end
        else
          decisions[rel] = nil
        end
      end
      save_decisions(root, decisions)

      vim.notify(("review: marked %d file(s) %s"):format(#targets, status or "untriaged"))
      M.refresh()
    end)
    if not ok then
      vim.notify("review: mark failed: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)()
end

--- Turn review mode on/off for the cwd's repo (gitsigns base + explorer
--- colours). Fires the on_toggle hook so a companion (e.g. nitpick's inline
--- comments) can follow the same switch; the wiring lives in user config, not
--- here.
function M.toggle()
  local root = cwd_root()
  if not root then
    return vim.notify("review: not in a git repo", vim.log.levels.WARN)
  end
  local on = not M.enabled_roots[root]
  M.enabled_roots[root] = on or nil
  vim.notify("review mode " .. (on and "on" or "off"))
  if M.opts.on_toggle then
    -- The root goes with it: the companion must follow THIS repo's toggle, not
    -- re-resolve the cwd's and risk a different one.
    M.opts.on_toggle(on, root)
  end
  M.refresh()
end

--- Ref the diff view compares against for the current buffer's repo: the review
--- base if review mode set one, else the default branch tip — so the diff still
--- shows branch-level changes when the sign-column review mode is off (mirrors
--- the fallback in git.lua).
---@param root string? the buffer's repo root
---@return string
local function diff_base(root)
  local base = root and require("triage.gitsigns").bases[root]
  if base then
    return base
  end
  if root and M.target_override[root] then
    return M.target_override[root]
  end
  -- Sync call (this runs outside the coroutine paths): anchor it on the current
  -- buffer's repo rather than nvim's cwd, which may be elsewhere.
  local default = vim.fn.systemlist({
    "git",
    "-C",
    root or vim.fn.getcwd(),
    "symbolic-ref",
    "--quiet",
    "--short",
    "refs/remotes/origin/HEAD",
  })[1]
  return (default and default ~= "") and default or "origin/main"
end

-- Combined inline diff: deleted lines rendered inline as virtual text and
-- changed lines (word-level) highlighted on the file buffer itself, against the
-- review base — rather than a side-by-side split. Global gitsigns state, so it's
-- a mode across all buffers, not per-window.
M.inline_diff = false

--- Toggle the combined inline diff. While on, point gitsigns at the review base
--- of the current buffer's repo (even if the sign-column review mode is off);
--- restore that repo's prior base when off.
function M.toggle_diff()
  local ok, gs = pcall(require, "gitsigns")
  if not ok then
    vim.notify("review: gitsigns not available", vim.log.levels.WARN)
    return
  end
  local gsbase = require("triage.gitsigns")
  local root = gsbase.buf_root(0) or cwd_root()
  if not root then
    vim.notify("review: not in a git repo", vim.log.levels.WARN)
    return
  end
  M.inline_diff = not M.inline_diff
  gs.toggle_deleted(M.inline_diff)
  gs.toggle_linehl(M.inline_diff)
  gs.toggle_word_diff(M.inline_diff)
  -- set_base refreshes gitsigns, which is what renders the toggles above; do it
  -- last so enabling and disabling both repaint in one pass.
  if M.inline_diff then
    M._diff_prev = { root = root, base = gsbase.bases[root] }
    gsbase.set_base(root, diff_base(root))
  else
    local prev = M._diff_prev or { root = root }
    gsbase.set_base(prev.root, prev.base)
    M._diff_prev = nil
  end
end

--- Re-render the explorer so its review component picks up new status.
function M.redraw_tree()
  require("triage.adapter").redraw()
end

-- Default keymaps, action -> left-hand side. Override or disable individually
-- via opts.keys (set an action to false/"" to leave it unmapped).
local default_keys = {
  approve = "<leader>rr", -- mark file/folder approved
  reject = "<leader>rj", -- mark file/folder rejected
  unmark = "<leader>ru", -- clear the decision (untriage)
  toggle = "<leader>rt", -- toggle review mode
  base = "<leader>rb", -- set the review target branch
  diff = "<leader>rd", -- toggle the inline diff view
  refresh = "<leader>rR", -- recompute review status
}

--- Configure and activate triage.nvim.
---@param opts? { base?: string, on_toggle?: fun(enabled: boolean, root: string), keys?: table<string, string|false> }
---   base       default review base (e.g. "develop"); nil auto-detects origin/HEAD → main/master.
---   on_toggle  fired by the toggle action with the new enabled state and the
---              repo root it applies to — wire a
---              companion (e.g. nitpick's comments) to follow the same switch.
---   keys       per-action left-hand side; see default_keys. false/"" disables one.
function M.setup(opts)
  M.opts = opts or {}
  -- Resolved attribute (e.g. "fg"/"bg") of a highlight group, chasing links.
  ---@return integer? 24-bit colour, or nil if unset
  local function hl_attr(name, attr)
    return vim.api.nvim_get_hl(0, { name = name, link = false })[attr]
  end

  --- Blend two 24-bit colours: `weight` of `over` on top of `under`.
  ---@return string "#rrggbb"
  local function blend(over, under, weight)
    local function channels(colour)
      return math.floor(colour / 65536) % 256, math.floor(colour / 256) % 256, colour % 256
    end
    local o_r, o_g, o_b = channels(over)
    local u_r, u_g, u_b = channels(under)
    local function mix(o, u)
      return math.floor(o * weight + u * (1 - weight) + 0.5)
    end
    return string.format("#%02x%02x%02x", mix(o_r, u_r), mix(o_g, u_g), mix(o_b, u_b))
  end

  -- Themeable highlight groups for the explorer indicators.
  local function set_hl()
    vim.api.nvim_set_hl(0, "ReviewChanged", { link = "DiagnosticWarn", default = true })
    vim.api.nvim_set_hl(0, "ReviewApproved", { link = "DiagnosticOk", default = true })
    vim.api.nvim_set_hl(0, "ReviewRejected", { link = "DiagnosticError", default = true })
    -- Revised = a rejection that's since been edited; blue reads as "action
    -- pending, re-review" and stays distinct from the red/green/yellow trio.
    vim.api.nvim_set_hl(0, "ReviewRevised", { link = "DiagnosticInfo", default = true })
    -- Inline diff (M.toggle_diff) word-level highlight. gitsigns defaults these
    -- to TermCursor (a loud, wrong-hued cyan in most themes). Give each its own
    -- diff hue — the sign colour (green add / blue change / red delete) tinted
    -- 40% over the line background — so the within-line marks pop in the right
    -- colour instead of blue-on-red. Force (no default) to beat gitsigns' link;
    -- falls back to DiffText if the theme leaves a group's colours unset.
    local inline = {
      GitSignsAddInline = { sign = "GitSignsAdd", line = "DiffAdd" },
      GitSignsChangeInline = { sign = "GitSignsChange", line = "DiffChange" },
      GitSignsDeleteInline = { sign = "GitSignsDelete", line = "DiffDelete" },
    }
    for group, ref in pairs(inline) do
      local hue = hl_attr(ref.sign, "fg")
      local line_bg = hl_attr(ref.line, "bg")
      if hue and line_bg then
        vim.api.nvim_set_hl(0, group, { bg = blend(hue, line_bg, 0.4) })
      else
        vim.api.nvim_set_hl(0, group, { link = "DiffText" })
      end
    end
  end
  vim.api.nvim_create_autocmd("ColorScheme", { callback = set_hl })
  set_hl()

  vim.api.nvim_create_user_command(
    "ReviewRefresh",
    M.refresh,
    { desc = "Recompute branch review status" }
  )
  vim.api.nvim_create_user_command("ReviewToggle", M.toggle, { desc = "Toggle branch review mode" })
  -- Complete :ReviewBase with local and remote branch names matching the prefix.
  local function complete_ref(arg)
    local refs = vim.fn.systemlist({
      "git",
      "-C",
      vim.fs.root(0, ".git") or vim.fn.getcwd(),
      "for-each-ref",
      "--format=%(refname:short)",
      "refs/heads",
      "refs/remotes",
    })
    return vim.tbl_filter(function(r)
      return r:sub(1, #arg) == arg
    end, refs)
  end
  vim.api.nvim_create_user_command("ReviewBase", function(o)
    M.set_target(o.args)
  end, {
    nargs = "?",
    complete = complete_ref,
    desc = "Set review target branch (no arg to auto-detect)",
  })
  vim.api.nvim_create_user_command(
    "ReviewDiff",
    M.toggle_diff,
    { desc = "Toggle inline diff vs review base" }
  )
  vim.api.nvim_create_user_command("ReviewMark", function()
    M.mark("approved")
  end, { desc = "Mark file/folder under cursor approved" })
  vim.api.nvim_create_user_command("ReviewReject", function()
    M.mark("rejected")
  end, { desc = "Mark file/folder under cursor rejected" })
  vim.api.nvim_create_user_command("ReviewUnmark", function()
    M.mark(nil)
  end, { desc = "Clear review decision on file/folder under cursor" })

  -- Action -> (handler, description). Mapped under the user's chosen keys below.
  local actions = {
    approve = {
      function()
        M.mark("approved")
      end,
      "Review: mark approved",
    },
    reject = {
      function()
        M.mark("rejected")
      end,
      "Review: mark rejected",
    },
    unmark = {
      function()
        M.mark(nil)
      end,
      "Review: clear decision (untriage)",
    },
    toggle = { M.toggle, "Review: toggle review mode" },
    base = {
      function()
        local prev = M.target_override[cwd_root() or ""] or ""
        vim.ui.input({ prompt = "Review target (empty = auto): ", default = prev }, function(input)
          if input ~= nil then
            M.set_target(input)
          end
        end)
      end,
      "Review: set target branch",
    },
    diff = { M.toggle_diff, "Review: toggle inline diff view" },
    refresh = { M.refresh, "Review: refresh status" },
  }
  local keys = vim.tbl_extend("force", default_keys, M.opts.keys or {})
  for action, spec in pairs(actions) do
    local lhs = keys[action]
    if lhs and lhs ~= "" then
      vim.keymap.set("n", lhs, spec[1], { desc = spec[2] })
    end
  end

  -- Keep status fresh without being expensive: on save, on regaining focus
  -- (branch may have moved), and once at startup.
  vim.api.nvim_create_autocmd({ "BufWritePost", "FocusGained", "DirChanged" }, {
    callback = function()
      -- Debounce a touch so a burst of events collapses into one git pass.
      -- stop() alone leaves the libuv handle alive, so close it too — a long
      -- session would otherwise accumulate one dead timer per save. defer_fn
      -- timers close themselves once fired, hence the is_closing guard.
      if M._pending and not M._pending:is_closing() then
        M._pending:stop()
        M._pending:close()
      end
      M._pending = vim.defer_fn(M.refresh, 150)
    end,
  })
  vim.defer_fn(M.refresh, 200)
end

return M
