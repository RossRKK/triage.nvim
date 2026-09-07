-- The jj backend against a real, throwaway jj repo. Only what a fake can't
-- cover: the revsets the backend hands to jj.

local assert = require("luassert")

local has_jj = vim.fn.executable("jj") == 1

--- Drive `fn` in the coroutine the sh plumbing expects and wait for it.
local function run(fn)
  local result
  local co = coroutine.create(function()
    result = { fn() }
  end)
  coroutine.resume(co)
  vim.wait(10000, function()
    return coroutine.status(co) == "dead"
  end)
  assert.equals("dead", coroutine.status(co), "backend call did not finish")
  return unpack(result)
end

--- A jj repo with a master bookmark that has moved on since the change forked.
---
---   master:  A -- B(edits base.txt)
---   @:       A -- C(adds ours.txt)
local function diverged_repo()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  local function jj(...)
    local out = vim
      .system(
        { "jj", "--color=never", "--no-pager", ... },
        { cwd = root, text = true, env = { JJ_USER = "t", JJ_EMAIL = "t@t" } }
      )
      :wait()
    assert.equals(0, out.code, "jj " .. table.concat({ ... }, " ") .. ": " .. (out.stderr or ""))
    return out.stdout
  end
  -- Not colocated: jj 0.41 colocates by default, but a .git dir puts gitsigns
  -- (and git refs) back in charge -- see triage.gitsigns.jj_owns. The revset
  -- paths under test are the ones for a jj-only workspace.
  jj("git", "init", "--config", "git.colocate=false")
  -- No remote here, and jj's default trunk() falls back to root() without one.
  jj("config", "set", "--repo", 'revset-aliases."trunk()"', "master")
  vim.fn.writefile({ "a" }, root .. "/base.txt")
  jj("commit", "-m", "A")
  -- Move master on with B first, then fork the change off A, so master has a
  -- commit the change lacks. B edits a file the change also has: a two-point
  -- diff from trunk then reports base.txt as modified, which a deletion (the
  -- backend drops those) would not have caught.
  vim.fn.writefile({ "b" }, root .. "/base.txt")
  jj("commit", "-m", "B")
  jj("bookmark", "create", "master", "-r", "@-")
  jj("new", "master-")
  vim.fn.writefile({ "ours" }, root .. "/ours.txt")
  jj("describe", "-m", "C")
  return root, jj
end

describe("triage.vcs.jj.changed", function()
  if not has_jj then
    pending("jj not installed")
    return
  end
  local backend = require("triage.vcs.jj")
  local root

  before_each(function()
    root = diverged_repo()
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
  end)

  it("lists only this change's files when trunk has moved on", function()
    local base = run(function()
      return backend.default_base(root, nil)
    end)
    assert.equals("trunk()", base)
    local files = run(function()
      return backend.changed(root, base)
    end)
    assert.same({ ["ours.txt"] = true }, files)
  end)
end)

describe("triage.toggle_diff base in a jj workspace", function()
  if not has_jj then
    pending("jj not installed")
    return
  end
  local root

  before_each(function()
    root = diverged_repo()
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
  end)

  -- The old path shelled out to git, and without a .git it fell back to the
  -- literal "origin/main", which is not a revset jj can show a file at.
  it("hands jjsigns a revset, not a git ref name", function()
    assert.equals("trunk()", require("triage")._diff_base(vim.fs.normalize(root)))
  end)

  -- Colocated, gitsigns draws: git resolves refs, not revsets, so the base must
  -- come back as a ref name -- a revset there silently matches nothing.
  it("hands gitsigns a git ref in a colocated repo", function()
    local colocated = vim.fn.tempname()
    vim.fn.mkdir(colocated, "p")
    vim.system({ "jj", "--color=never", "git", "init" }, { cwd = colocated }):wait()
    local base = require("triage")._diff_base(vim.fs.normalize(colocated))
    vim.fn.delete(colocated, "rf")
    assert.equals("origin/main", base)
  end)

  -- Review mode's base comes from the VCS backend, and `.jj` picks the jj one
  -- even when colocated -- so it hands the gitsigns gutter a revset. gitsigns
  -- attaching with one dies on "Not a valid object name", losing the attach
  -- outright: no signs, and the inline diff toggles nothing. The commit id is
  -- the name both languages accept.
  it("resolves a revset to a commit id before the gitsigns gutter sees it", function()
    local gsbase = require("triage.gitsigns")
    local colocated = vim.fn.tempname()
    vim.fn.mkdir(colocated, "p")
    local function jj(...)
      local out = vim
        .system(
          { "jj", "--color=never", "--no-pager", ... },
          { cwd = colocated, text = true, env = { JJ_USER = "t", JJ_EMAIL = "t@t" } }
        )
        :wait()
      assert.equals(0, out.code, "jj " .. table.concat({ ... }, " ") .. ": " .. (out.stderr or ""))
      return out.stdout
    end
    jj("git", "init", "--config", "git.colocate=true")
    jj("config", "set", "--repo", 'revset-aliases."trunk()"', "master")
    vim.fn.writefile({ "a" }, colocated .. "/base.txt")
    jj("commit", "-m", "A")
    jj("bookmark", "create", "master", "-r", "@-")
    local want = vim.trim(jj("log", "--no-graph", "-r", "trunk()", "-T", "commit_id"))

    local nroot = vim.fs.normalize(colocated)
    gsbase.set_base(nroot, "trunk()")
    local got = gsbase.bases[nroot]
    -- A ref git owns is not jj revset syntax (`origin/main` is `main@origin`),
    -- so it must survive untouched rather than being dropped as unresolvable.
    gsbase.set_base(nroot, "origin/main")
    local passthrough = gsbase.bases[nroot]
    gsbase.bases[nroot] = nil
    vim.fn.delete(colocated, "rf")

    assert.equals(want, got)
    assert.equals("origin/main", passthrough)
  end)

  -- A refresh that finds review mode off deactivates the repo, which used to
  -- reset the gutter base too -- under an open inline diff, which had just set
  -- it. The view then silently showed working-copy edits instead of the branch.
  it("keeps the inline diff's base through a refresh with review mode off", function()
    local triage = require("triage")
    local gsbase = require("triage.gitsigns")
    local nroot = vim.fs.normalize(root)
    local prev_cwd = vim.fn.getcwd()
    vim.cmd.cd(root)
    triage.inline_diff = true
    triage._diff_prev = { root = nroot, base = nil }
    gsbase.set_base(nroot, "trunk()")
    triage.refresh()
    -- refresh is fire-and-forget; give its jj calls time to land.
    vim.wait(1500)
    vim.cmd.cd(prev_cwd)
    triage.inline_diff = false
    triage._diff_prev = nil
    assert.equals("trunk()", gsbase.bases[nroot])
  end)
end)

describe("triage.vcs.jj.head", function()
  if not has_jj then
    pending("jj not installed")
    return
  end
  local backend = require("triage.vcs.jj")

  it("names the change after a local bookmark, not a stale remote one", function()
    local root, jj = diverged_repo()
    -- Push master so origin knows it, then move local master on. The pushed
    -- commit now carries `master@origin` beside any local bookmark, which is
    -- what a workspace forked off master looks like once master advances.
    local remote = vim.fn.tempname()
    vim.fn.mkdir(remote, "p")
    vim.system({ "git", "init", "--bare", "-q", remote }):wait()
    jj("git", "remote", "add", "origin", remote)
    jj("git", "push", "--bookmark", "master", "--allow-new")
    jj("bookmark", "create", "rkk/feat", "-r", "master")
    jj("bookmark", "set", "master", "-r", "@", "--allow-backwards")
    jj("new", "rkk/feat")
    local names = jj("log", "-r", "rkk/feat", "--no-graph", "-T", 'bookmarks ++ "\\n"')
    assert.truthy(names:find("master@origin", 1, true), "setup: expected a remote bookmark, got " .. names)
    local branch = run(function()
      return backend.head(root)
    end)
    assert.equals("rkk/feat", branch)
  end)
end)
