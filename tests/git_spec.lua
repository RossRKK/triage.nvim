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
