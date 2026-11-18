-- Triage decisions end to end against a real git repo: marking a file, editing
-- it, and what the ledger and status make of the edit.

local assert = require("luassert")
local triage = require("triage")

local has_git = vim.fn.executable("git") == 1

describe("triage decisions", function()
  if not has_git then
    pending("git not installed")
    return
  end

  local root, git, saved_cwd
  local rel = "dir/sub/f.txt"

  ---@return string
  local function ledger()
    return vim.fn.stdpath("state") .. "/review/" .. root:gsub("[/\\:.]", "%%") .. ".triage"
  end

  ---@return string
  local function abs()
    return root .. "/" .. rel
  end

  --- Refresh and wait until the file under review shows `status`.
  ---@param status TriageStatus
  local function refreshed_to(status)
    triage.refresh()
    assert.is_true(
      vim.wait(5000, function()
        return triage.status(abs()) == status
      end),
      "never became " .. status .. ", is " .. tostring(triage.status(abs()))
    )
  end

  --- Mark the file and wait until it shows as marked.
  ---@param status ReviewStatus
  local function marked(status)
    triage.mark(status, abs())
    refreshed_to(status)
  end

  before_each(function()
    root = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(root .. "/dir/sub", "p")
    function git(...)
      local out = vim
        .system({ "git", "-c", "user.name=t", "-c", "user.email=t@t", ... }, { cwd = root, text = true })
        :wait()
      assert.equals(0, out.code, "git " .. table.concat({ ... }, " ") .. ": " .. (out.stderr or ""))
      return vim.trim(out.stdout)
    end
    git("init", "-q", "-b", "master")
    git("symbolic-ref", "refs/remotes/origin/HEAD", "refs/heads/master")
    git("commit", "-q", "--allow-empty", "-m", "c1")
    git("checkout", "-q", "-b", "topic")
    vim.fn.writefile({ "decided" }, abs())

    saved_cwd = vim.fn.getcwd()
    vim.cmd.cd(root)
    triage.enabled_roots[root] = true
    refreshed_to("changed")
  end)

  after_each(function()
    triage.enabled_roots[root] = nil
    triage.status_by_path, triage.folder_status = {}, {}
    vim.cmd.cd(saved_cwd)
    vim.fn.delete(ledger())
    vim.fn.delete(root, "rf")
  end)

  it("stores the decided content under the hash the ledger records", function()
    marked("approved")
    local hash = vim.fn.readfile(ledger())[1]:match("^approved (%x+) " .. vim.pesc(rel) .. "$")
    assert.is_not_nil(hash)
    assert.equals("decided", git("cat-file", "-p", hash))
  end)

  it("keeps an approval edited since as stale, with the decided hash", function()
    marked("approved")
    local before = vim.fn.readfile(ledger())
    vim.fn.writefile({ "edited" }, abs())
    refreshed_to("stale")
    assert.same(before, vim.fn.readfile(ledger()))
  end)

  it("keeps a rejection edited since as revised", function()
    marked("rejected")
    vim.fn.writefile({ "edited" }, abs())
    refreshed_to("revised")
  end)

  it("ranks a stale file above untriaged ones in its folder", function()
    vim.fn.writefile({ "other" }, root .. "/dir/sub/g.txt")
    marked("approved")
    vim.fn.writefile({ "edited" }, abs())
    refreshed_to("stale")
    assert.equals("stale", triage.folder(root .. "/dir/sub"))
  end)
end)
