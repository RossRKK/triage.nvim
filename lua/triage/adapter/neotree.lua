-- neo-tree adapter for the triage UI.
--
-- All of triage.nvim's coupling to a specific file explorer lives behind this
-- interface (see triage/adapter/init.lua, which selects the active one):
--
--   status_component(config, node, state) -> chunk   a neo-tree renderer
--     component that draws the ●/✓/✗/↻ triage glyph before a node's name.
--     Coloured glyph only; the name is left alone.
--   cursor_path() -> string?   absolute path of the node under the cursor when
--     the explorer is focused, else nil (so callers fall back to the buffer).
--   redraw()   repaint the explorer so the component picks up new status.
--
-- To port the triage UI to another explorer, write a sibling module exposing the
-- same three and re-point triage/adapter/init.lua at it.

local M = {}

-- The glyphs come from triage.icons, so the tree and every other surface mark a
-- status the same way; only the neo-tree chunk shape (and the trailing space
-- that separates the glyph from the filename) is this adapter's business.
---@param status string
---@return table chunk
local function icon(status)
  local spec = require("triage").icons[status]
  return spec and { text = spec.text .. " ", highlight = spec.hl } or nil
end

--- A neo-tree renderer component: the triage glyph for a path. Directories show
--- their rolled-up descendant status. Placed before "name" in the file/directory
--- renderers (see plugins/explorer.lua). (The PR-comment speech bubble is a
--- separate component in nitpick's adapter.)
---@return table chunk
function M.status_component(_, node, _)
  local review = require("triage")
  local status = node.type == "directory" and review.folder(node.path) or review.status(node.path)
  -- neo-tree renders a single chunk; empty text is a no-op.
  return (status and icon(status)) or { text = "" }
end

--- Absolute path of the node under the cursor, but only while the filesystem
--- explorer is the focused window — otherwise nil, so the caller uses the current
--- buffer instead. neo-tree buffers carry the "neo-tree" filetype.
---@return string?
function M.cursor_path()
  if vim.bo.filetype ~= "neo-tree" then
    return nil
  end
  local ok, manager = pcall(require, "neo-tree.sources.manager")
  if not ok then
    return nil
  end
  local state = manager.get_state("filesystem")
  if not state or not state.tree then
    return nil
  end
  local node = state.tree:get_node()
  return node and node.path or nil
end

--- Repaint the filesystem explorer so the review component re-runs. Safe to call
--- when neo-tree isn't loaded or no tree is open.
function M.redraw()
  local ok, manager = pcall(require, "neo-tree.sources.manager")
  if ok then
    pcall(manager.refresh, "filesystem")
  end
end

return M
