-- The git backend against a real, throwaway git repo: the fork point the review
-- gutter diffs against.

local assert = require("luassert")

local has_git = vim.fn.executable("git") == 1

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

--- A git repo whose master has moved on since the branch forked.
---
---   master:  A -- B(edits base.txt)
---   HEAD:    A -- C(adds ours.txt)
local function diverged_repo()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  local function git(...)
    local out = vim
      .system({ "git", "-c", "user.name=t", "-c", "user.email=t@t", ... }, { cwd = root, text = true })
      :wait()
    assert.equals(0, out.code, "git " .. table.concat({ ... }, " ") .. ": " .. (out.stderr or ""))
    return vim.trim(out.stdout)
  end
  git("init", "-q", "-b", "master")
  -- What a clone has and the sync fallback in triage._diff_base reads.
  git("symbolic-ref", "refs/remotes/origin/HEAD", "refs/heads/master")
  vim.fn.writefile({ "a" }, root .. "/base.txt")
  git("add", "-A")
  git("commit", "-q", "-m", "A")
  local a = git("rev-parse", "HEAD")
  vim.fn.writefile({ "b" }, root .. "/base.txt")
  git("commit", "-q", "-am", "B")
  git("checkout", "-q", "-b", "topic", a)
  vim.fn.writefile({ "ours" }, root .. "/ours.txt")
  git("add", "-A")
  git("commit", "-q", "-m", "C")
  return root, git, a
end

describe("triage.vcs.git.fork_point", function()
  if not has_git then
    pending("git not installed")
    return
  end
  local backend = require("triage.vcs.git")
  local root, git, a

  before_each(function()
    root, git, a = diverged_repo()
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
  end)

  it("is the merge base, not the branch tip", function()
    local got = run(function()
      return backend.fork_point(root, "master")
    end)
    assert.equals(a, got)
    assert.is_not.equals(git("rev-parse", "master"), got)
  end)

  it("falls back to the ref name when git has no merge base", function()
    local got = run(function()
      return backend.fork_point(root, "no-such-branch")
    end)
    assert.equals("no-such-branch", got)
  end)

  -- The inline-diff fallback (review mode off) takes the sync git path.
  it("drives the inline diff's fallback base", function()
    local got = require("triage")._diff_base(vim.fs.normalize(root))
    assert.equals(a, got)
  end)
end)

--- An empty repo with a commit helper, for building stacks by hand.
local function stack_repo()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  local function git(...)
    local out = vim
      .system({ "git", "-c", "user.name=t", "-c", "user.email=t@t", ... }, { cwd = root, text = true })
      :wait()
    assert.equals(0, out.code, "git " .. table.concat({ ... }, " ") .. ": " .. (out.stderr or ""))
    return vim.trim(out.stdout)
  end
  local n = 0
  local function commit()
    n = n + 1
    vim.fn.writefile({ tostring(n) }, root .. "/f" .. n .. ".txt")
    git("add", "-A")
    git("commit", "-q", "-m", "c" .. n)
    return git("rev-parse", "HEAD")
  end
  git("init", "-q", "-b", "master")
  commit()
  return root, git, commit
end

describe("triage.vcs.git.parent_branch", function()
  if not has_git then
    pending("git not installed")
    return
  end
  local backend = require("triage.vcs.git")
  local root, git, commit

  before_each(function()
    root, git, commit = stack_repo()
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
  end)

  local function parent(default)
    return run(function()
      return backend.parent_branch(root, default or "master")
    end)
  end

  --   master: c1
  --   feat/a: c1 -- c2
  --   feat/b: c1 -- c2 -- c3   (HEAD)
  local function stack()
    git("checkout", "-q", "-b", "feat/a")
    commit()
    git("checkout", "-q", "-b", "feat/b")
    commit()
  end

  it("finds the branch HEAD is stacked on", function()
    stack()
    assert.equals("feat/a", parent())
  end)

  it("is nil for a branch straight off the default branch", function()
    git("checkout", "-q", "-b", "topic")
    commit()
    assert.is_nil(parent())
  end)

  it("skips the branch's own upstream sitting on its unpushed commits", function()
    stack()
    local mid = commit()
    commit()
    git("update-ref", "refs/remotes/origin/feat/b", mid)
    assert.equals("feat/a", parent())
  end)

  it("ignores a parent the default branch already contains", function()
    stack()
    git("update-ref", "refs/heads/master", git("rev-parse", "feat/a"))
    assert.is_nil(parent())
  end)

  it("ignores a branch on HEAD itself", function()
    stack()
    git("branch", "feat/c")
    assert.equals("feat/a", parent())
  end)

  it("prefers the local branch over its origin copy on the same commit", function()
    stack()
    git("update-ref", "refs/remotes/origin/feat/a", git("rev-parse", "feat/a"))
    assert.equals("feat/a", parent())
  end)

  it("returns the origin copy when the parent isn't checked out locally", function()
    stack()
    git("update-ref", "refs/remotes/origin/feat/a", git("rev-parse", "feat/a"))
    git("branch", "-D", "feat/a")
    assert.equals("origin/feat/a", parent())
  end)

  it("skips a stale local default branch when the default is origin's", function()
    -- Local master stuck on c1; origin/master has moved on to include feat/a.
    stack()
    git("update-ref", "refs/remotes/origin/master", git("rev-parse", "feat/a"))
    assert.is_nil(parent("origin/master"))
  end)
end)

describe("triage.vcs.git.branch_ref", function()
  if not has_git then
    pending("git not installed")
    return
  end
  local backend = require("triage.vcs.git")
  local root, git

  before_each(function()
    root, git = stack_repo()
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
  end)

  local function ref(name)
    return run(function()
      return backend.branch_ref(root, name)
    end)
  end

  it("prefers origin's copy, then the local branch, else nil", function()
    git("branch", "feat/a")
    assert.equals("feat/a", ref("feat/a"))
    git("update-ref", "refs/remotes/origin/feat/a", "HEAD")
    assert.equals("origin/feat/a", ref("feat/a"))
    assert.is_nil(ref("nope"))
  end)
end)

describe("triage review base resolution", function()
  if not has_git then
    pending("git not installed")
    return
  end
  local triage = require("triage")
  local root, git, commit, nroot

  before_each(function()
    root, git, commit = stack_repo()
    nroot = vim.fs.normalize(root)
    git("checkout", "-q", "-b", "feat/a")
    commit()
    git("checkout", "-q", "-b", "feat/b")
    commit()
    git("branch", "pr-base")
    triage.opts = {}
    triage.target_override = {}
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
    triage.opts = {}
    triage.target_override = {}
  end)

  local function resolve()
    return run(function()
      return triage._review_branch(nroot)
    end)
  end

  it("infers the stack parent with no hook or override", function()
    local base, label = resolve()
    assert.equals("feat/a", base)
    assert.equals("stack", label)
  end)

  it("lets the hook (the PR's base) beat inference, and passes it the branch", function()
    local seen
    triage.opts.resolve_base = function(_, branch)
      seen = branch
      return "pr-base", "#7"
    end
    local base, label = resolve()
    assert.equals("feat/b", seen)
    assert.equals("pr-base", base)
    assert.equals("#7", label)
  end)

  it("falls through when the hook names a branch that doesn't exist", function()
    triage.opts.resolve_base = function()
      return "gone"
    end
    assert.equals("feat/a", (resolve()))
  end)

  it("lets the override beat everything", function()
    triage.opts.resolve_base = function()
      return "pr-base", "#7"
    end
    triage.target_override[nroot] = "master"
    local base, label = resolve()
    assert.equals("master", base)
    assert.equals("set", label)
  end)

  it("uses the default branch, unlabelled, when nothing is stacked", function()
    git("checkout", "-q", "-b", "solo", "master")
    commit()
    local base, label = resolve()
    assert.equals("master", base)
    assert.is_nil(label)
  end)
end)
