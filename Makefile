PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin

.PHONY: install uninstall test lint help

help:
	@echo "slipway — machine-wide port-range registry"
	@echo
	@echo "Targets:"
	@echo "  install    Install slipway to $(BINDIR)/slipway"
	@echo "  uninstall  Remove slipway from $(BINDIR)"
	@echo "  test       Run the test suite"
	@echo "  lint       Shellcheck the script"
	@echo
	@echo "Vars: PREFIX (default: \$$HOME/.local), BINDIR (default: \$$PREFIX/bin)"

install:
	install -d "$(BINDIR)"
	install -m 0755 bin/slipway "$(BINDIR)/slipway"
	@echo "installed: $(BINDIR)/slipway"
	@echo "make sure $(BINDIR) is on your PATH"

uninstall:
	rm -f "$(BINDIR)/slipway"
	@echo "removed: $(BINDIR)/slipway"

test:
	@bash tests/test.sh

lint:
	@shellcheck bin/slipway tests/test.sh
