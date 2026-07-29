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

# `make dev` shades these tools with the local debug build; every other tool is
# symlinked to whatever is already installed, so its TCC grant is untouched.
# reminders/calendar/contacts are deliberately not in this list: they disclaim,
# so their grant is bound to the binary's path and a debug build at a new path
# re-prompts. mail and notes are attributed to the calling terminal, so shading
# them costs nothing, and messages reads chat.db under the same Full Disk
# Access grant. Override to work on one of the others:
#   make dev DEV_TOOLS="apple-contacts"
DEV_TOOLS ?= apple-mail apple-notes apple-messages
DEVBIN    := $(ROOT)/.dev-bin

.PHONY: build debug install uninstall test clean check set-version bump dist tag \
        completions install-completions install-skills uninstall-skills \
        dev dev-off dev-path

## Build the Swift binaries in release mode
##
## The three EventKit/Contacts tools embed an Info.plist carrying their usage
## description; the linker puts it in __TEXT,__info_plist but leaves it outside
## the signature, and macOS ignores an unbound one. Re-signing binds it. Without
## this, the permission dialog never appears and the status stays notDetermined.
build:
	cd $(SWIFT_DIR) && swift build -c release
	@for tool in reminders apple-calendar apple-contacts; do \
		codesign -s - -f "$(RELEASE_DIR)/$$tool" 2>/dev/null || true; \
	done

debug:
	cd $(SWIFT_DIR) && swift build

## Generate zsh completions for the ArgumentParser tools into completions/
## (_apple, _apple-notes and _apple-contacts are hand-written and committed)
completions: build
	@for tool in reminders apple-mail apple-calendar apple-contacts apple-messages; do \
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
	ln -sf $(ROOT)/$(RELEASE_DIR)/apple-messages $(PREFIX)/apple-messages
	ln -sf $(ROOT)/$(RELEASE_DIR)/apple-calendar $(PREFIX)/apple-calendar
	ln -sf $(ROOT)/$(RELEASE_DIR)/reminders $(PREFIX)/reminders
	@echo "Installed to $(PREFIX). Ensure it is on your PATH."

uninstall:
	rm -f $(PREFIX)/apple $(PREFIX)/apple-notes $(PREFIX)/apple-contacts \
	      $(PREFIX)/apple-mail $(PREFIX)/apple-calendar $(PREFIX)/reminders \
	      $(PREFIX)/apple-messages

## Build debug and shade the installed tools with it, for fast iteration.
##
## ~/bin is *after* /opt/homebrew/bin on a normal PATH, so `make install`
## cannot override a brew install — hence a separate dir you put first.
## Re-run after every edit; the debug build is a couple of seconds.
dev: debug
	@mkdir -p $(DEVBIN)
	@# The dispatcher is a wrapper rather than a symlink: bin/apple resolves
	@# its own directory by following symlinks back to the checkout, so a
	@# symlinked dispatcher would look for tools in bin/ and never see this
	@# dir. APPLE_TOOLS_BIN is the documented way to say "look here first".
	@printf '#!/usr/bin/env bash\nexport APPLE_TOOLS_BIN="%s"\nexec "%s/bin/apple" "$$@"\n' \
		"$(DEVBIN)" "$(ROOT)" > $(DEVBIN)/apple
	@chmod +x $(DEVBIN)/apple
	@for name in $(DEV_TOOLS); do \
		case "$$name" in \
			apple-notes) src="$(ROOT)/notes/apple-notes" ;; \
			*)           src="$(ROOT)/$(SWIFT_DIR)/.build/debug/$$name" ;; \
		esac; \
		if [ ! -x "$$src" ]; then echo "error: no such tool '$$name'"; exit 1; fi; \
		ln -sf "$$src" "$(DEVBIN)/$$name"; \
		echo "  dev    $$name"; \
	done
	@# Everything not being worked on points at the installed copy, so
	@# `apple status` stays truthful and no grant gets re-prompted.
	@for name in apple-notes apple-mail apple-calendar apple-contacts apple-messages reminders; do \
		case " $(DEV_TOOLS) " in *" $$name "*) continue ;; esac; \
		if installed="$$(command -v $$name 2>/dev/null)"; then \
			ln -sf "$$installed" "$(DEVBIN)/$$name"; \
			echo "  system $$name  ($$installed)"; \
		else \
			rm -f "$(DEVBIN)/$$name"; \
			echo "  MISSING $$name  (not installed; 'apple $$name' will fail)"; \
		fi; \
	done
	@echo
	@echo "Put this first on PATH (once per shell, or in ~/.zshrc):"
	@echo "  export PATH=\"$(DEVBIN):\$$PATH\""

## Print just the export line, for `eval "$(make -s dev-path)"`
dev-path:
	@echo 'export PATH="$(DEVBIN):$$PATH"'

dev-off:
	rm -rf $(DEVBIN)
	@echo "Removed $(DEVBIN). Open a new shell, or strip it from PATH."

## Swift unit tests. The Notes suite drives live Notes.app; run notes/run-tests by hand.
test:
	cd $(SWIFT_DIR) && swift test

## Smoke-check that every tool answers --help and produces JSON
check: debug
	@bin/apple --which
	@echo
	@for tool in notes mail messages reminders calendar contacts; do \
		printf '%-10s ' "$$tool"; \
		bin/apple $$tool --help >/dev/null 2>&1 && echo ok || echo FAILED; \
	done

## Stamp the version from ./VERSION into every tool (or: make set-version V=2026.8.1)
set-version:
	@./scripts/set-version $(V)

## Build a release tarball for the Homebrew tap, and print its sha256
dist: set-version completions
	@# Every tool must carry the version in ./VERSION. `set-version` stamps
	@# four files and can be cut short — piping it into `head` SIGPIPEs it
	@# partway, which shipped v26.728.2 with bin/apple still on 26.728.1.
	@# dist re-runs it, so the tarball was right and only the tagged source
	@# was wrong: silent, and invisible until someone builds from the tag.
	@for f in bin/apple notes/apple-notes swift/Sources/AppleToolsVersion/Version.swift; do \
		grep -q "$(VERSION)" "$$f" \
			|| { echo "error: $$f does not carry $(VERSION); run 'make set-version'"; exit 1; }; \
	done
	@# Skills ship in this tarball, so an edit made after the last dist is a
	@# release that documents the wrong behaviour — which is exactly what
	@# v26.728.0 did.
	@git diff --quiet -- skills/ \
		|| { echo "error: skills/ has uncommitted changes; commit them before releasing"; exit 1; }
	cd $(SWIFT_DIR) && swift build $(SWIFT_UNIV)
	rm -rf $(DIST) $(TARBALL)
	mkdir -p $(DIST)/docs
	@# Ask SwiftPM where the universal binaries landed; the path has moved
	@# between toolchain versions, so don't hardcode it.
	cp "$$(cd $(SWIFT_DIR) && swift build $(SWIFT_UNIV) --show-bin-path)"/reminders \
	   "$$(cd $(SWIFT_DIR) && swift build $(SWIFT_UNIV) --show-bin-path)"/apple-mail \
	   "$$(cd $(SWIFT_DIR) && swift build $(SWIFT_UNIV) --show-bin-path)"/apple-calendar \
	   "$$(cd $(SWIFT_DIR) && swift build $(SWIFT_UNIV) --show-bin-path)"/apple-contacts \
	   "$$(cd $(SWIFT_DIR) && swift build $(SWIFT_UNIV) --show-bin-path)"/apple-messages \
	   $(DIST)/
	cp bin/apple $(DIST)/
	cp notes/apple-notes notes/notestore.py notes/notestore.proto $(DIST)/
	cp README.md CLAUDE.md LICENSE VERSION $(DIST)/
	@# All of docs/, not one named file: CLAUDE.md links to these, and a
	@# release that ships the link but not the target is worse than neither.
	cp docs/*.md $(DIST)/docs/
	mkdir -p $(DIST)/completions $(DIST)/skills $(DIST)/shortcuts
	cp completions/_* $(DIST)/completions/
	cp -R skills/* $(DIST)/skills/
	@# The signed .shortcut files ARE the Notes write path — without them
	@# `apple notes install-shortcuts` has nothing to install and the tool is
	@# read-only. Fail loudly rather than shipping a release that silently
	@# cannot write.
	@ls notes/shortcuts/*.shortcut >/dev/null 2>&1 \
		|| { echo "error: no signed shortcuts in notes/shortcuts/; run 'python3 notes/shortcuts/build-shortcut.py --ship notes/shortcuts/'"; exit 1; }
	cp notes/shortcuts/*.shortcut $(DIST)/shortcuts/
	cp notes/shortcuts/README.md $(DIST)/shortcuts/
	@# Bind the embedded Info.plists. `dist` links its own universal binaries,
	@# so the re-signing done by `build` does not apply to them — without this
	@# the shipped tools cannot show a permission dialog at all.
	@for b in reminders apple-calendar apple-contacts; do \
		codesign -s - -f $(DIST)/$$b 2>/dev/null || true; \
		codesign -dv $(DIST)/$$b 2>&1 | grep -q "Info.plist entries" \
			|| { echo "error: $$b has no bound Info.plist"; exit 1; }; \
	done
	@# Confirm the binaries really are universal before shipping them.
	@for b in reminders apple-mail apple-calendar apple-contacts apple-messages; do \
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
