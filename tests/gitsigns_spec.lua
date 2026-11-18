-- The since-decision toggle against the real gitsigns: it must accept a
-- decision tree as a buffer's base and draw the hunks since the decision.
-- Uses the Neovim config's lazy install of gitsigns, as minimal_init does plenary.

local assert = require("luassert")

local gitsigns_dir = vim.fn.stdpath("data") .. "/lazy/gitsigns.nvim"

describe("since-decision toggle under gitsigns", function()
  if vim.fn.executable("git") == 0 or vim.fn.isdirectory(gitsigns_dir) == 0 then
    pending("needs git and gitsigns.nvim")
    return
  end
  vim.opt.runtimepath:prepend(gitsigns_dir)
  require("gitsigns").setup({})
  local triage = require("triage")

  local root, buf

  ---@param cmd string[]
  ---@return string
  local function git(cmd)
    local full = { "git", "-c", "user.name=t", "-c", "user.email=t@t" }
    local out = vim.system(vim.list_extend(full, cmd), { cwd = root, text = true }):wait()
    assert.equals(0, out.code, table.concat(cmd, " ") .. ": " .. (out.stderr or ""))
    return vim.trim(out.stdout)
  end

  ---@return string
  local function ledger()
    return vim.fn.stdpath("state") .. "/review/" .. root:gsub("[/\\:.]", "%%") .. ".triage"
  end

  --- Wait for gitsigns to show exactly these hunks, as "<type> <first line>+<count>".
  ---@param want string[]
  local function hunks_become(want)
    local got
    local ok = vim.wait(5000, function()
      got = vim.tbl_map(function(h)
        return ("%s %d+%d"):format(h.type, h.added.start, h.added.count)
      end, require("gitsigns").get_hunks(buf) or {})
      return vim.deep_equal(got, want)
    end)
    assert.is_true(ok, "hunks " .. vim.inspect(got) .. ", wanted " .. vim.inspect(want))
  end

  before_each(function()
    root = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(root .. "/src/deep", "p")
    git({ "init", "-q", "-b", "master" })
    vim.fn.writefile({ "one", "two", "three" }, root .. "/src/deep/f.txt")
    git({ "add", "-A" })
    git({ "commit", "-q", "-m", "c1" })
    -- Decided on an uncommitted edit, so only the stored blob has that content.
    vim.fn.writefile({ "one", "TWO", "three" }, root .. "/src/deep/f.txt")
    local blob = git({ "hash-object", "-w", "src/deep/f.txt" })
    vim.fn.mkdir(vim.fs.dirname(ledger()), "p")
    vim.fn.writefile({ "approved " .. blob .. " src/deep/f.txt" }, ledger())
    -- The agent's change since: one line added at the end.
    vim.fn.writefile({ "one", "TWO", "three", "four" }, root .. "/src/deep/f.txt")
    vim.cmd.edit(root .. "/src/deep/f.txt")
    buf = vim.api.nvim_get_current_buf()
  end)

  after_each(function()
    require("triage.gitsigns").buf_bases = {}
    vim.cmd("bwipeout! " .. buf)
    vim.fn.delete(ledger())
    vim.fn.delete(root, "rf")
  end)

  it("shows only the change since the decision, then the review base again", function()
    -- Against the index: the decided edit and the addition since.
    hunks_become({ "change 2+1", "add 4+1" })
    triage.toggle_since_decision()
    hunks_become({ "add 4+1" })
    triage.toggle_since_decision()
    hunks_become({ "change 2+1", "add 4+1" })
  end)
end)
