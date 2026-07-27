SWIFT_DIR   := swift
RELEASE_DIR := $(SWIFT_DIR)/.build/release
PREFIX      ?= $(HOME)/bin
ROOT        := $(shell pwd)

.PHONY: build debug install uninstall test clean check

## Build the Swift binaries (reminders, apple-mail, apple-calendar) in release mode
build:
	cd $(SWIFT_DIR) && swift build -c release

debug:
	cd $(SWIFT_DIR) && swift build

## Symlink the dispatcher and each tool into $(PREFIX)
install: build
	@mkdir -p $(PREFIX)
	ln -sf $(ROOT)/bin/apple $(PREFIX)/apple
	ln -sf $(ROOT)/notes/apple-notes $(PREFIX)/apple-notes
	ln -sf $(ROOT)/contacts/apple-contacts $(PREFIX)/apple-contacts
	ln -sf $(ROOT)/$(RELEASE_DIR)/apple-mail $(PREFIX)/apple-mail
	ln -sf $(ROOT)/$(RELEASE_DIR)/apple-calendar $(PREFIX)/apple-calendar
	ln -sf $(ROOT)/$(RELEASE_DIR)/reminders $(PREFIX)/reminders
	@echo "Installed to $(PREFIX). Ensure it is on your PATH."

uninstall:
	rm -f $(PREFIX)/apple $(PREFIX)/apple-notes $(PREFIX)/apple-contacts \
	      $(PREFIX)/apple-mail $(PREFIX)/apple-calendar $(PREFIX)/reminders

## Swift unit tests. The Notes suite drives live Notes.app; run notes/run-tests by hand.
test:
	cd $(SWIFT_DIR) && swift test

## Smoke-check that every tool answers --help and produces JSON
check: debug
	@bin/apple --which
	@echo
	@for tool in notes mail reminders calendar contacts; do \
		printf '%-10s ' "$$tool"; \
		bin/apple $$tool --help >/dev/null 2>&1 && echo ok || echo FAILED; \
	done

clean:
	cd $(SWIFT_DIR) && swift package clean
	rm -rf $(SWIFT_DIR)/.build
	find . -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true
