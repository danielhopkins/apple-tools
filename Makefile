SWIFT_DIR   := swift
RELEASE_DIR := $(SWIFT_DIR)/.build/release
PREFIX      ?= $(HOME)/bin
# Claude reads one config dir per session, chosen by CLAUDE_CONFIG_DIR, and a
# machine can have several profiles (personal / work). Install skills into all
# of them so they are there whichever profile the session runs under.
# Override with: make install-skills CLAUDE_DIRS="/path/to/.claude"
CLAUDE_DIRS ?= $(wildcard $(HOME)/.claude-personal $(HOME)/.claude-inevitable $(HOME)/.claude)
ZSH_COMPLETIONS ?=
ROOT        := $(shell pwd)
SWIFT_UNIV  := --configuration release --arch arm64 --arch x86_64
VERSION     := $(shell tr -d '[:space:]' < VERSION)
DIST        := apple-tools-$(VERSION)
TARBALL     := $(DIST).tar.gz

.PHONY: build debug install uninstall test clean check set-version bump dist tag \
        completions install-completions install-skills uninstall-skills

## Build the Swift binaries (reminders, apple-mail, apple-calendar) in release mode
build:
	cd $(SWIFT_DIR) && swift build -c release

debug:
	cd $(SWIFT_DIR) && swift build

## Generate zsh completions for the ArgumentParser tools into completions/
## (_apple, _apple-notes and _apple-contacts are hand-written and committed)
completions: build
	@for tool in reminders apple-mail apple-calendar apple-contacts; do \
		$(RELEASE_DIR)/$$tool --generate-completion-script zsh > completions/_$$tool \
			&& echo "  completions/_$$tool"; \
	done

## Install zsh completions somewhere already on your fpath
install-completions: completions
	@dir="$(ZSH_COMPLETIONS)"; \
	if [ -z "$$dir" ]; then \
		if [ -d "$$HOME/.oh-my-zsh/custom/completions" ]; then \
			dir="$$HOME/.oh-my-zsh/custom/completions"; \
		else \
			dir="$$HOME/.zsh/completions"; \
		fi; \
	fi; \
	mkdir -p "$$dir"; \
	for f in completions/_*; do ln -sf "$(ROOT)/$$f" "$$dir/$$(basename $$f)"; done; \
	echo "Installed completions to $$dir"; \
	case ":$$FPATH:" in \
		*":$$dir:"*) ;; \
		*) echo "Add to ~/.zshrc before compinit:"; \
		   echo "  fpath=($$dir \$$fpath)";; \
	esac; \
	echo "Then: rm -f ~/.zcompdump && exec zsh"

## Symlink the Claude skills into every Claude config dir on this machine
install-skills:
	@if [ -z "$(CLAUDE_DIRS)" ]; then \
		echo "error: no Claude config dir found. Pass one:"; \
		echo "  make install-skills CLAUDE_DIRS=~/.claude"; exit 1; \
	fi
	@for dir in $(CLAUDE_DIRS); do \
		mkdir -p "$$dir/skills"; \
		for skill in skills/*/; do \
			name=$$(basename $$skill); \
			ln -sfn "$(ROOT)/skills/$$name" "$$dir/skills/$$name"; \
		done; \
		echo "  $$dir/skills/  <- $$(ls -d skills/*/ | wc -l | tr -d ' ') skills"; \
	done
	@echo "Installed. Skills are picked up on the next Claude Code session."

uninstall-skills:
	@for dir in $(CLAUDE_DIRS); do \
		for skill in skills/*/; do \
			name=$$(basename $$skill); \
			if [ -L "$$dir/skills/$$name" ]; then \
				rm -f "$$dir/skills/$$name"; echo "  removed $$dir/skills/$$name"; \
			fi; \
		done; \
	done

## Symlink the dispatcher and each tool into $(PREFIX)
install: build
	@mkdir -p $(PREFIX)
	ln -sf $(ROOT)/bin/apple $(PREFIX)/apple
	ln -sf $(ROOT)/notes/apple-notes $(PREFIX)/apple-notes
	ln -sf $(ROOT)/$(RELEASE_DIR)/apple-contacts $(PREFIX)/apple-contacts
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

## Stamp the version from ./VERSION into every tool (or: make set-version V=2026.8.1)
set-version:
	@./scripts/set-version $(V)

## Build a release tarball for the Homebrew tap, and print its sha256
dist: set-version completions
	cd $(SWIFT_DIR) && swift build $(SWIFT_UNIV)
	rm -rf $(DIST) $(TARBALL)
	mkdir -p $(DIST)/docs
	@# Ask SwiftPM where the universal binaries landed; the path has moved
	@# between toolchain versions, so don't hardcode it.
	cp "$$(cd $(SWIFT_DIR) && swift build $(SWIFT_UNIV) --show-bin-path)"/reminders \
	   "$$(cd $(SWIFT_DIR) && swift build $(SWIFT_UNIV) --show-bin-path)"/apple-mail \
	   "$$(cd $(SWIFT_DIR) && swift build $(SWIFT_UNIV) --show-bin-path)"/apple-calendar \
	   "$$(cd $(SWIFT_DIR) && swift build $(SWIFT_UNIV) --show-bin-path)"/apple-contacts \
	   $(DIST)/
	cp bin/apple $(DIST)/
	cp notes/apple-notes notes/notestore.py notes/notestore.proto $(DIST)/
	cp README.md CLAUDE.md LICENSE VERSION $(DIST)/
	cp docs/apple-notes-api.md $(DIST)/docs/
	mkdir -p $(DIST)/completions $(DIST)/skills
	cp completions/_* $(DIST)/completions/
	cp -R skills/* $(DIST)/skills/
	@# Confirm the binaries really are universal before shipping them.
	@for b in reminders apple-mail apple-calendar apple-contacts; do \
		archs="$$(lipo -archs $(DIST)/$$b)"; \
		case "$$archs" in \
			*arm64*) ;; \
			*) echo "error: $$b missing arm64 (has: $$archs)"; exit 1;; \
		esac; \
		case "$$archs" in \
			*x86_64*) ;; \
			*) echo "error: $$b missing x86_64 (has: $$archs)"; exit 1;; \
		esac; \
	done
	tar -czf $(TARBALL) $(DIST)
	rm -rf $(DIST)
	@echo
	@echo "$(TARBALL)"
	@shasum -a 256 $(TARBALL)
	@echo
	@echo "Next: create the 'v$(VERSION)' release, attach the tarball, then update"
	@echo "Formula/apple-tools.rb in the homebrew-formulae tap with that sha256."

## Tag the current commit with the version in ./VERSION (tags carry a v prefix)
tag:
	git tag -a v$(VERSION) -m "apple-tools $(VERSION)"
	@echo "Tagged v$(VERSION). Push with: git push origin v$(VERSION)"

## Bump to today's next CalVer (YY.MMDD.Patch) and stamp it everywhere
bump:
	@./scripts/set-version --bump

clean:
	cd $(SWIFT_DIR) && swift package clean
	rm -rf $(SWIFT_DIR)/.build $(DIST) $(TARBALL)
	find . -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true
