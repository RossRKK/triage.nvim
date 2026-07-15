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

-- Status -> glyph + highlight. The trailing space separates the glyph from the
-- filename that follows it in the renderer. Highlights are defined in
-- triage/init.lua's set_hl (themeable, glyph-only colouring).
local icon_by_status = {
  changed = { text = "● ", highlight = "ReviewChanged" },
  approved = { text = "✓ ", highlight = "ReviewApproved" },
  rejected = { text = "✗ ", highlight = "ReviewRejected" },
  revised = { text = "↻ ", highlight = "ReviewRevised" },
}

--- A neo-tree renderer component: the triage glyph for a path. Directories show
--- their rolled-up descendant status. Placed before "name" in the file/directory
--- renderers (see plugins/explorer.lua). (The PR-comment speech bubble is a
--- separate component in nitpick's adapter.)
---@return table chunk
function M.status_component(_, node, _)
  local review = require("triage")
  local status = node.type == "directory" and review.folder(node.path) or review.status(node.path)
  local icon = status and icon_by_status[status]
  -- neo-tree renders a single chunk; empty text is a no-op.
  return icon or { text = "" }
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
