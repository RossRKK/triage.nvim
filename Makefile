# Run the test suite under headless Neovim (plenary's busted harness).
# Exits non-zero on any failure. One file: make test FILE=tests/triage_spec.lua
# With nvim, plenary and gitsigns from the flake: nix develop -c make test
FILE ?= tests/

# Without the VIM/VIMRUNTIME an enclosing nvim's terminal exports, which point
# at that nvim's runtime rather than this one's.
.PHONY: test
test:
	env -u VIM -u VIMRUNTIME nvim --headless -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory $(FILE) { minimal_init = 'tests/minimal_init.lua' }"
