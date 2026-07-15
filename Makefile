# Run the test suite under headless Neovim (plenary's busted harness).
# Exits non-zero on any failure. One file: make test FILE=tests/triage_spec.lua
FILE ?= tests/

.PHONY: test
test:
	nvim --headless -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory $(FILE) { minimal_init = 'tests/minimal_init.lua' }"
