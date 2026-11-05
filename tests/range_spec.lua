-- Reviewing a range of the branch's commits, end to end against a real git
-- repo: <leader>rb picks a top and a bottom, the top is checked out, the bottom
-- becomes the review base, and approved commits come back ticked.

local assert = require("luassert")
local triage = require("triage")

local has_git = vim.fn.executable("git") == 1

describe("triage commit range review", function()
  if not has_git then
    pending("git not installed")
    return
  end

  local root, git, commits, saved_select, saved_cwd
  -- Answers for successive vim.ui.select calls, and the rows each one offered.
  local answers, offered

  ---@return string
  local function approved_file()
    return vim.fn.stdpath("state") .. "/review/" .. root:gsub("[/\\:.]", "%%") .. ".approved"
  end

  before_each(function()
    root = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(root, "p")
    function git(...)
      local out = vim
        .system({ "git", "-c", "user.name=t", "-c", "user.email=t@t", ... }, { cwd = root, text = true })
        :wait()
      assert.equals(0, out.code, "git " .. table.concat({ ... }, " ") .. ": " .. (out.stderr or ""))
      return vim.trim(out.stdout)
    end
    git("init", "-q", "-b", "master")
    git("commit", "-q", "--allow-empty", "-m", "c1")
    git("checkout", "-q", "-b", "topic")
    -- commits[i] is the short sha of c(i+1): c2, c3, c4, oldest first.
    commits = {}
    for n = 2, 4 do
      vim.fn.writefile({ tostring(n) }, root .. "/f" .. n .. ".txt")
      git("add", "-A")
      git("commit", "-q", "-m", "c" .. n)
      commits[#commits + 1] = git("rev-parse", "--short", "HEAD")
    end

    saved_cwd = vim.fn.getcwd()
    vim.cmd.cd(root)
    saved_select = vim.ui.select
    answers, offered = {}, {}
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.select = function(items, opts, on_choice)
      local texts = {}
      for i, item in ipairs(items) do
        texts[i] = opts.format_item(item)
      end
      offered[#offered + 1] = texts
      local idx = table.remove(answers, 1)
      on_choice(items[idx], idx)
    end
    triage.away, triage.target_override = {}, {}
  end)

  after_each(function()
    vim.ui.select = saved_select
    vim.cmd.cd(saved_cwd)
    vim.fn.delete(approved_file())
    vim.fn.delete(root, "rf")
  end)

  local function head()
    return git("rev-parse", "--short", "HEAD"), git("rev-parse", "--abbrev-ref", "HEAD")
  end

  it("checks out the top, bases the review on the bottom, then returns to the tip", function()
    -- Up to c3 (row 2 of c4, c3, c2), from c2 (row 1 of c2, auto).
    answers = { 2, 1 }
    triage.pick_target()
    assert.is_true(vim.wait(5000, function()
      return triage.target_override[root] ~= nil
    end))
    local sha, ref = head()
    assert.equals(commits[2], sha)
    assert.equals("HEAD", ref)
    assert.equals(commits[1], triage.target_override[root])

    -- Back up to the tip from the auto base: the branch, not a detached HEAD.
    answers = { 1, 3 }
    triage.pick_target()
    assert.is_true(vim.wait(5000, function()
      return triage.target_override[root] == nil
    end))
    sha, ref = head()
    assert.equals(commits[3], sha)
    assert.equals("topic", ref)
    assert.is_nil(triage.away[root])
    -- The second pick still listed the whole branch, not just up to c3.
    assert.equals(3, #offered[3])
  end)

  it("keeps auto as the base it was listed from while away from the tip", function()
    answers = { 2, 2 } -- up to c3, from auto
    triage.pick_target()
    assert.is_true(vim.wait(5000, function()
      return triage.target_override[root] ~= nil
    end))
    assert.equals("master", triage.target_override[root])
  end)

  it("ticks the commits approved under review", function()
    answers = { 2, 1 } -- up to c3, from c2: c3 alone is under review
    triage.pick_target()
    assert.is_true(vim.wait(5000, function()
      return triage.target_override[root] ~= nil
    end))
    triage.approve_commits()
    assert.is_true(vim.wait(5000, function()
      return vim.fn.filereadable(approved_file()) == 1
    end))

    answers = {} -- cancel: just look at the rows
    triage.pick_target()
    assert.is_true(vim.wait(5000, function()
      return #offered == 3
    end))
    local tick = triage.icons.approved.text
    assert.equals(" ", offered[3][1]:sub(1, 1)) -- c4
    assert.equals(tick, offered[3][2]:sub(1, #tick)) -- c3
    assert.equals(" ", offered[3][3]:sub(1, 1)) -- c2
  end)
end)
