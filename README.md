# triage.nvim

Branch-review mode for Neovim: mark each changed file as reviewed / needs-work as
you go, with the verdict rolled up across the branch. Paints a per-file status
glyph in [neo-tree][], rebases the [gitsigns][] sign column onto the branch
merge-base so the diff you see is the diff under review, and exposes the review
state to your statusline.

Pairs with [nitpick.nvim][] (inline GitHub PR comments), but stands alone.

## Install

[lazy.nvim][]:

```lua
{
  "RossRKK/triage.nvim",
  dependencies = { "nvim-neo-tree/neo-tree.nvim", "lewis6991/gitsigns.nvim" },
  config = function()
    require("triage").setup({})
  end,
}
```

## Setup

`require("triage").setup(opts)` accepts:

| Key         | Type                    | Description                                              |
| ----------- | ----------------------- | ------------------------------------------------------- |
| `on_toggle` | `fun(on: boolean, root: string)` | Called when review mode is toggled, with the repo root it applies to. Wire a companion (e.g. nitpick) here. |
| `resolve_base` | `fun(root: string, branch: string?): string?, string?` | A branch to review against before stack inference -- e.g. the branch's PR base -- and a short label for the statusline. Bare branch name; `origin/` is preferred when it exists. Runs in the refresh coroutine, so keep it a cache read. |
| `base`      | `string?`               | Default branch override (e.g. `"develop"`); nil auto-detects `origin/HEAD`, then main/master. |

The review base is the first of: the `:ReviewBase` override, `resolve_base`, the
branch this one is stacked on (the nearest other branch on HEAD's first-parent
line that the default branch doesn't contain; git only), and the default branch.

The neo-tree glyph is registered as the `triage_status` component
(`require("triage.adapter").status_component`); add it to your neo-tree
filesystem renderers. See the source for the full command/keymap surface.

## Wiring with nitpick.nvim

The two are designed to run as one review mode: a single toggle shows/hides
both, and nitpick submits under triage's verdict. Wire them in one lazy spec —
triage's `on_toggle` reveals nitpick, and nitpick's `verdict` borrows triage's:

```lua
{
  {
    "RossRKK/triage.nvim",
    dependencies = { "nvim-neo-tree/neo-tree.nvim", "lewis6991/gitsigns.nvim" },
    config = function()
      require("triage").setup({
        -- Toggling review mode reveals/hides nitpick's comments too.
        on_toggle = function(on, root)
          require("nitpick").set_shown(on, root)
        end,
      })
    end,
  },
  {
    "RossRKK/nitpick.nvim",
    dependencies = { "RossRKK/triage.nvim", "nvim-neo-tree/neo-tree.nvim" },
    config = function()
      -- nitpick submits its batch under triage's rolled-up verdict.
      require("nitpick").setup({ verdict = require("triage").verdict })
    end,
  },
}
```

Note nitpick additionally needs the [GitHub CLI (`gh`)][gh] on your `PATH`.
triage works on its own; `on_toggle` is optional if you're not pairing it.

## Tests

```bash
make test
```

Headless plenary/busted; covers the verdict rollup and the path lookups.

[neo-tree]: https://github.com/nvim-neo-tree/neo-tree.nvim
[gitsigns]: https://github.com/lewis6991/gitsigns.nvim
[nitpick.nvim]: https://github.com/RossRKK/nitpick.nvim
[lazy.nvim]: https://github.com/folke/lazy.nvim
[gh]: https://cli.github.com/
