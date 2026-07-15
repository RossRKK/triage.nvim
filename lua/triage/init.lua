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

-- Absolute path -> "changed"|"approved"|"rejected"|"revised", rebuilt on refresh.
M.status_by_path = {}

-- Directory absolute path -> rolled-up status of its descendants (the highest-
-- priority child status; see do_refresh for the ordering).
M.folder_status = {}

-- Whether review mode is currently active (a git repo with a usable merge-base).
M.active = false

-- The branch the active review is diffed against (the resolved review base), for
-- the status string. nil while inactive.
M.base = nil

-- Toggle: when false, gitsigns stays on its normal HEAD base and the explorer
-- decorator is dormant. Defaults off; turn on per-branch with <leader>rt.
M.enabled = false

-- User-chosen branch to review against, overriding auto-detection. nil = auto
-- (origin/HEAD, else main/master). Set with <leader>rb / :ReviewBase.
M.target_override = nil

local uv = vim.uv or vim.loop

--- Run a command asynchronously, yielding the current coroutine until it exits.
--- MUST be called from within a coroutine (refresh/mark drive one). Returns the
--- stdout lines and the exit code; stdout is returned even on a non-zero exit so
--- callers like merged_tree can read a conflicted merge's tree oid.
---@param cmd string[]
---@return string[] lines, integer code
local function sh(cmd)
  local co = assert(coroutine.running(), "review: git must run inside a coroutine")
  vim.system(cmd, { text = true }, function(obj)
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
---@param root string
---@return string?
local function review_branch(root)
  return M.target_override or default_branch(root)
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

---@param root string
---@return string
local function decisions_file(root)
  -- Sanitise the repo path into a single filename component.
  local key = root:gsub("[/\\:]", "%%")
  return state_dir() .. "/" .. key
end

--- Load decisions: relative path -> Decision.
---@param root string
---@return table<string, Decision>
local function load_decisions(root)
  local decisions = {}
  local path = decisions_file(root)
  if vim.fn.filereadable(path) == 0 then
    return decisions
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

--- Clear all review state and reset gitsigns; used by the inactive paths.
local function deactivate()
  M.status_by_path = {}
  M.folder_status = {}
  M.active = false
  M.base = nil
  require("triage.gitsigns").set_base(nil)
  M.redraw_tree()
end

--- The async body of a refresh. Runs inside a coroutine; every git() call yields
--- without blocking the UI. Builds new state in locals and only commits it at the
--- end, so a partial run never leaves half-updated tables on screen.
---@param mygen integer generation this run belongs to
local function do_refresh(mygen)
  local function stale()
    return mygen ~= refresh_gen
  end

  if not M.enabled then
    return deactivate()
  end

  local root = repo_root()
  if stale() then
    return
  end
  if not root then
    return deactivate()
  end

  local branch = review_branch(root)
  local base_sha = branch and rev(root, branch)
  local head_sha = rev(root, "HEAD")
  -- Files the merge would actually change vs the default branch. This is the
  -- merge-result diff, so files the branch changed to content the default branch
  -- already has don't appear. Cached on the two shas, so it's free (no git) when
  -- neither HEAD nor the base has moved since the last refresh.
  local committed = branch
    and base_sha
    and head_sha
    and committed_changed(root, branch, base_sha, head_sha)
  if stale() then
    return
  end
  if not branch or not committed then
    return deactivate()
  end

  local changed = {} -- rel path -> true (dedup)
  for rel in pairs(committed) do
    changed[rel] = true
  end
  -- Also include uncommitted work (staged + unstaged edits, and untracked
  -- files) so you can review changes before committing them. These are the
  -- cheaper git calls and change on save, so they're recomputed every time.
  for _, rel in ipairs(git(root, { "diff", "--name-only", "--diff-filter=d", "HEAD" })) do
    changed[rel] = true
  end
  for _, rel in ipairs(git(root, { "ls-files", "--others", "--exclude-standard" })) do
    changed[rel] = true
  end
  if stale() then
    return
  end

  local decisions = load_decisions(root)
  local status_by_path = {}
  local still = {} -- prune decisions for files no longer in the diff

  for rel in pairs(changed) do
    local abs = vim.fs.normalize(root .. "/" .. rel)
    local decision = decisions[rel]
    if not decision then
      status_by_path[abs] = "changed"
    else
      local matches = decision.hash == blob_hash(root, rel)
      if decision.status == "rejected" then
        -- Keep the rejection on record either way: an edited-since rejected file
        -- becomes "revised" (the flag was acted on — re-review the fix), not a
        -- plain "changed" that would lose the fact you'd flagged it.
        status_by_path[abs] = matches and "rejected" or "revised"
        still[rel] = decision
      elseif matches then
        status_by_path[abs] = "approved"
        still[rel] = decision
      else
        -- Approved file edited again: just needs a fresh look; drop the record.
        status_by_path[abs] = "changed"
      end
    end
  end
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
  local nroot = vim.fs.normalize(root)
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

  -- Commit the freshly built state atomically.
  M.status_by_path = status_by_path
  M.folder_status = folder_status
  M.active = true
  M.base = branch
  -- Drop decisions for files that no longer differ (e.g. after a rebase).
  if next(decisions) then
    save_decisions(root, still)
  end
  -- Per-line signs: diff the buffer against the default-branch tip, so a line
  -- that matches what's already on the branch shows no sign — consistent with
  -- the merge-result file list above.
  require("triage.gitsigns").set_base(branch)
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
    if ref then
      local root = repo_root()
      if not root then
        return vim.notify("review: not in a git repo", vim.log.levels.WARN)
      end
      if not rev(root, ref) then
        return vim.notify("review: no such ref: " .. ref, vim.log.levels.ERROR)
      end
    end
    M.target_override = ref
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
---@return "APPROVE"|"REQUEST_CHANGES"|"COMMENT"|nil
function M.verdict()
  local priority = { approved = 1, rejected = 2, changed = 3, revised = 4 }
  local worst
  for _, st in pairs(M.status_by_path) do
    if not worst or priority[st] > priority[worst] then
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
  if not M.enabled then
    return ""
  end
  local base = M.base or M.target_override or "…"
  -- Git-merge glyph (U+F419): the review diffs what merging into `base` would
  -- change, so a merge icon reads truer than a plain branch. Bytes, not the raw
  -- glyph, so it can't be lost when the file is edited.
  local merge = "\xef\x90\x99"
  return vim.trim(merge .. " " .. base)
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
      for _, path in ipairs(targets) do
        local rel = path:sub(#nroot + 2)
        if status then
          local hash = blob_hash(root, rel)
          if hash then
            decisions[rel] = { status = status, hash = hash }
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

--- Turn review mode on/off (gitsigns base + explorer colours). Fires the
--- on_toggle hook so a companion (e.g. nitpick's inline comments) can follow the
--- same switch; the wiring lives in user config, not here.
function M.toggle()
  M.enabled = not M.enabled
  vim.notify("review mode " .. (M.enabled and "on" or "off"))
  if M.opts.on_toggle then
    M.opts.on_toggle(M.enabled)
  end
  M.refresh()
end

--- Ref the diff view compares against: the review base if review mode set one,
--- else the default branch tip — so the diff still shows branch-level changes
--- when the sign-column review mode is off (mirrors the fallback in git.lua).
---@return string
local function diff_base()
  local base = require("triage.gitsigns").current
  if base then
    return base
  end
  if M.target_override then
    return M.target_override
  end
  local default = vim.fn.systemlist({
    "git",
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
--- (even if the sign-column review mode is off); restore the prior base when off.
function M.toggle_diff()
  local ok, gs = pcall(require, "gitsigns")
  if not ok then
    vim.notify("review: gitsigns not available", vim.log.levels.WARN)
    return
  end
  M.inline_diff = not M.inline_diff
  local gsbase = require("triage.gitsigns")
  gs.toggle_deleted(M.inline_diff)
  gs.toggle_linehl(M.inline_diff)
  gs.toggle_word_diff(M.inline_diff)
  -- set_base refreshes gitsigns, which is what renders the toggles above; do it
  -- last so enabling and disabling both repaint in one pass.
  if M.inline_diff then
    M._diff_prev_base = gsbase.current
    gsbase.set_base(diff_base())
  else
    gsbase.set_base(M._diff_prev_base)
    M._diff_prev_base = nil
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
---@param opts? { base?: string, on_toggle?: fun(enabled: boolean), keys?: table<string, string|false> }
---   base       default review base (e.g. "develop"); nil auto-detects origin/HEAD → main/master.
---   on_toggle  fired by the toggle action with the new enabled state — wire a
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
    approve = { function()
      M.mark("approved")
    end, "Review: mark approved" },
    reject = { function()
      M.mark("rejected")
    end, "Review: mark rejected" },
    unmark = { function()
      M.mark(nil)
    end, "Review: clear decision (untriage)" },
    toggle = { M.toggle, "Review: toggle review mode" },
    base = { function()
      vim.ui.input(
        { prompt = "Review target (empty = auto): ", default = M.target_override or "" },
        function(input)
          if input ~= nil then
            M.set_target(input)
          end
        end
      )
    end, "Review: set target branch" },
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
      if M._pending then
        M._pending:stop()
      end
      M._pending = vim.defer_fn(M.refresh, 150)
    end,
  })
  vim.defer_fn(M.refresh, 200)
end

return M
