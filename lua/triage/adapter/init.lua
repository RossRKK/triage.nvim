-- The active explorer adapter. This is the single seam between triage.nvim's
-- explorer-agnostic core (triage/init.lua) and the file explorer that draws its
-- triage glyphs.
--
-- To port the triage UI to a different explorer, write a sibling module in this
-- directory exposing the same interface (status_component / cursor_path / redraw;
-- see triage/adapter/neotree.lua) and re-point this require at it.
return require("triage.adapter.neotree")
