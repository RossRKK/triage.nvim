-- Pure logic in triage/init.lua: the triage rollup and the path lookups.

local assert = require("luassert")
local triage = require("triage")

describe("triage.verdict", function()
  ---@param state table<string, string> abs-path -> status
  local function verdict_of(state)
    triage.status_by_path = {}
    for path, st in pairs(state) do
      triage.status_by_path["/repo/" .. path] = st
    end
    return triage.verdict("/repo")
  end

  after_each(function()
    triage.status_by_path = {}
  end)

  it("is nil when nothing changed", function()
    assert.is_nil(verdict_of({}))
  end)

  it("approves when every file is approved", function()
    assert.equals("APPROVE", verdict_of({ a = "approved", b = "approved" }))
  end)

  it("requests changes on a lone rejection", function()
    assert.equals("REQUEST_CHANGES", verdict_of({ a = "rejected" }))
  end)

  it("requests changes when a rejection sits among approvals", function()
    assert.equals("REQUEST_CHANGES", verdict_of({ a = "approved", b = "rejected" }))
  end)

  -- A rejection is a standing verdict: it blocks even while files are still
  -- untriaged, rather than softening into a COMMENT until the review is done.
  it("requests changes when a rejection sits among untriaged files", function()
    assert.equals("REQUEST_CHANGES", verdict_of({ a = "changed", b = "rejected" }))
  end)

  it("stays COMMENT while an untriaged file sits among approvals", function()
    assert.equals("COMMENT", verdict_of({ a = "approved", b = "changed" }))
  end)

  it("treats revised as pending", function()
    assert.equals("COMMENT", verdict_of({ a = "revised" }))
  end)

  it("ranks a rejection above revised", function()
    assert.equals("REQUEST_CHANGES", verdict_of({ a = "revised", b = "rejected" }))
  end)

  -- Reviews are per repo: another repo's pending files must not soften this
  -- repo's verdict (state is one merged table keyed by absolute path).
  it("ignores other repos' entries when scoped to a root", function()
    triage.status_by_path = { ["/repo/a.lua"] = "approved", ["/elsewhere/b.lua"] = "changed" }
    assert.equals("APPROVE", triage.verdict("/repo"))
  end)
end)

describe("triage.status", function()
  before_each(function()
    triage.status_by_path = { ["/repo/a.lua"] = "approved" }
  end)

  after_each(function()
    triage.status_by_path = {}
  end)

  it("is nil for a nil path", function()
    assert.is_nil(triage.status(nil))
  end)

  it("is nil for an untracked path", function()
    assert.is_nil(triage.status("/repo/other.lua"))
  end)

  it("looks up a tracked path", function()
    assert.equals("approved", triage.status("/repo/a.lua"))
  end)

  -- Callers pass raw explorer node paths, which are not normalized.
  it("normalizes the path before looking it up", function()
    assert.equals("approved", triage.status("/repo/sub/../a.lua"))
  end)
end)

describe("triage.folder", function()
  before_each(function()
    triage.folder_status = { ["/repo/src"] = "changed" }
  end)

  after_each(function()
    triage.folder_status = {}
  end)

  it("is nil for a nil path", function()
    assert.is_nil(triage.folder(nil))
  end)

  it("is nil for a directory with no rolled-up status", function()
    assert.is_nil(triage.folder("/repo/docs"))
  end)

  it("looks up a rolled-up directory", function()
    assert.equals("changed", triage.folder("/repo/src"))
  end)

  it("normalizes the path before looking it up", function()
    assert.equals("changed", triage.folder("/repo/docs/../src"))
  end)
end)

describe("triage.is_enabled", function()
  local prev_cwd

  before_each(function()
    prev_cwd = vim.fn.getcwd()
  end)

  after_each(function()
    vim.cmd.cd(prev_cwd)
  end)

  -- Removing a git worktree deletes the directory a tab is still cd'd into.
  it("is false when the cwd has been deleted", function()
    local gone = vim.fn.tempname()
    vim.fn.mkdir(gone, "p")
    vim.cmd.cd(gone)
    vim.fn.delete(gone, "rf")
    assert.is_false(triage.is_enabled())
  end)
end)

describe("triage._base_choices", function()
  it("lists commits in log order, ticked if approved, then the labelled auto base", function()
    local got = triage._base_choices("origin/main", "#412", {
      { rev = "bbb", subject = "second", pushed = false, patch_id = "p2" },
      { rev = "aaa", subject = "first", pushed = true, patch_id = "p1" },
    }, { p1 = true })
    assert.same({
      { ref = "bbb", text = "  local  bbb  second" },
      { ref = "aaa", text = "\xe2\x9c\x93 pushed aaa  first" },
      { text = "  auto   origin/main · #412" },
    }, got)
  end)

  it("leaves the auto row unlabelled for the default branch", function()
    assert.same(
      { { text = "  auto   origin/main" } },
      triage._base_choices("origin/main", nil, {}, {})
    )
  end)

  it("can't tick a commit with no diff to identify it by", function()
    local got = triage._commit_choices({ { rev = "ccc", subject = "merge", pushed = false } }, {})
    assert.same({ { ref = "ccc", text = "  local  ccc  merge" } }, got)
  end)
end)
