-- Process plumbing shared by the VCS backends.
--
-- Everything here runs inside the coroutine refresh/report drive: sh() yields
-- until the process exits, so the backends read as straight-line code while
-- never blocking the editor.

local M = {}

--- Run a command asynchronously, yielding the current coroutine until it exits.
--- MUST be called from within a coroutine. Returns the stdout lines and the exit
--- code; stdout is returned even on a non-zero exit so callers like merged_tree
--- can read a conflicted merge's tree oid.
---@param cmd string[]
---@param stdin string? fed to the process (used to batch hash-object paths)
---@param cwd string? working directory for the process
---@return string[] lines, integer code
function M.sh(cmd, stdin, cwd)
  local co = assert(coroutine.running(), "triage: vcs commands must run inside a coroutine")
  -- No optional locks: everything run here is a read-only query, but git status
  -- opportunistically refreshes the index, and that lock-file churn is visible
  -- to anything watching the git dir -- including watchers (the greeter's) that
  -- respond by asking for another report, a permanent feedback loop.
  vim.system(
    cmd,
    { text = true, stdin = stdin, cwd = cwd, env = { GIT_OPTIONAL_LOCKS = "0" } },
    function(obj)
      vim.schedule(function()
        local lines = {}
        for line in (obj.stdout or ""):gmatch("[^\r\n]+") do
          lines[#lines + 1] = line
        end
        coroutine.resume(co, lines, obj.code)
      end)
    end
  )
  return coroutine.yield()
end

--- Content hash of a working-tree file, computed in-process.
---
--- The ledger records what a file looked like when it was triaged, so a decision
--- self-invalidates once the file is edited again; any stable hash of the bytes
--- does that job. git has `hash-object` for it, jj has no equivalent, and
--- hashing here costs no process at all -- so the jj backend uses this and the
--- git backend keeps hash-object, whose values are already on disk in existing
--- ledgers.
---@param path string absolute
---@return string?
function M.file_hash(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data and vim.fn.sha256(data) or nil
end

return M
