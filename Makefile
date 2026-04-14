PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
LIBDIR ?= $(PREFIX)/lib/slipway
BASH_COMPLETION_DIR ?= $(PREFIX)/etc/bash_completion.d
ZSH_COMPLETION_DIR  ?= $(PREFIX)/share/zsh/site-functions

.PHONY: install uninstall install-completions test lint help

help:
	@echo "slipway — machine-wide port-range registry"
	@echo
	@echo "Targets:"
	@echo "  install              Install slipway to $(BINDIR)/slipway"
	@echo "  install-completions  Install bash+zsh completions"
	@echo "  uninstall            Remove slipway from $(BINDIR) and completions"
	@echo "  test                 Run the test suite"
	@echo "  lint                 Shellcheck the script"
	@echo
	@echo "Vars: PREFIX (default: \$$HOME/.local), BINDIR, BASH_COMPLETION_DIR, ZSH_COMPLETION_DIR"

install:
	install -d "$(BINDIR)" "$(LIBDIR)"
	install -m 0755 bin/slipway "$(BINDIR)/slipway"
	install -m 0644 lib/slipway/commands.sh "$(LIBDIR)/commands.sh"
	@echo "installed: $(BINDIR)/slipway + $(LIBDIR)/commands.sh"
	@echo "make sure $(BINDIR) is on your PATH"

install-completions:
	install -d "$(BASH_COMPLETION_DIR)" "$(ZSH_COMPLETION_DIR)"
	install -m 0644 completions/slipway.bash "$(BASH_COMPLETION_DIR)/slipway"
	install -m 0644 completions/_slipway "$(ZSH_COMPLETION_DIR)/_slipway"
	@echo "installed: bash completion → $(BASH_COMPLETION_DIR)/slipway"
	@echo "installed: zsh  completion → $(ZSH_COMPLETION_DIR)/_slipway"

uninstall:
	rm -f "$(BINDIR)/slipway" \
	      "$(LIBDIR)/commands.sh" \
	      "$(BASH_COMPLETION_DIR)/slipway" \
	      "$(ZSH_COMPLETION_DIR)/_slipway"
	@rmdir "$(LIBDIR)" 2>/dev/null || true
	@echo "removed: slipway + lib + completions"

test:
	@bash tests/test.sh

lint:
	@shellcheck -x --source-path=SCRIPTDIR bin/slipway
	@shellcheck lib/slipway/commands.sh tests/test.sh install.sh
