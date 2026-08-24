# The lab is deliberately NOT wired into the root Makefile. Nothing here is
# part of `make build`, `make test` or `make dist`.
LAB     := $(shell pwd)
PREFIX  ?= $(HOME)/bin
LOGDIR  := $(HOME)/Library/Application Support/apple-tools
AGENT   := com.boulderhopkins.apple-index
PLIST   := $(HOME)/Library/LaunchAgents/$(AGENT).plist
UV      := $(shell command -v uv)

.PHONY: build install uninstall install-agent uninstall-agent agent-status \
        install-skill link-installed-skills uninstall-skill demo status test clean

## Build the Swift embedder (Core ML + Apple's models)
build:
	cd vec && swift build -c release

## Build the Core ML weights that ship. Needs uv and a Hugging Face download.
ship-models:
	./coreml/ship-models.sh

## Symlink apple-index into ~/bin
install: build
	@mkdir -p "$(PREFIX)"
	ln -sf "$(LAB)/bin/apple-index" "$(PREFIX)/apple-index"
	@echo "installed $(PREFIX)/apple-index"
	@case ":$$PATH:" in *":$(PREFIX):"*) ;; \
	  *) echo "⚠️  $(PREFIX) is not on your PATH";; esac
	@echo "next:  make install-agent    # start the daemon at login"

uninstall:
	rm -f "$(PREFIX)/apple-index"
	@echo "removed $(PREFIX)/apple-index"

## Install and load the launchd agent that keeps the daemon warm
install-agent: build
	@test -x vec/.build/release/vec || { echo "error: run 'make build' first"; exit 1; }
	@mkdir -p "$(HOME)/Library/LaunchAgents" "$(LOGDIR)"
	@sed -e 's|@VEC@|$(LAB)/vec/.build/release/vec|g' \
	     -e 's|@INDEXDIR@|$(LAB)|g' -e 's|@HOME@|$(HOME)|g' \
	     -e 's|@PATH@|/usr/bin:/bin:/usr/sbin:/sbin:$(HOME)/bin|g' \
	     -e 's|@LOGDIR@|$(LOGDIR)|g' \
	     $(AGENT).plist.in > "$(PLIST)"
	@# ⚠️ bootout is asynchronous. Bootstrapping straight after it fails with
	@# "Input/output error" because the old service is still tearing down.
	-@launchctl bootout gui/$$(id -u)/$(AGENT) 2>/dev/null
	@for i in 1 2 3 4 5 6 7 8 9 10; do 	  launchctl print gui/$$(id -u)/$(AGENT) >/dev/null 2>&1 || break; sleep 1; done
	launchctl bootstrap gui/$$(id -u) "$(PLIST)"
	@echo "loaded $(AGENT)"
	@echo "⚠️  The agent SERVES searches. It cannot INGEST: a launchd agent has"
	@echo "   no Full Disk Access. Refresh from a terminal: apple-index refresh"

uninstall-agent:
	-launchctl bootout gui/$$(id -u)/$(AGENT) 2>/dev/null
	rm -f "$(PLIST)"
	@echo "removed $(AGENT)"

agent-status:
	@launchctl print gui/$$(id -u)/$(AGENT) 2>/dev/null \
	  | grep -E "state|pid|last exit" || echo "not loaded"
	@./bin/apple-index daemon status || true

## Symlink the lab skill into every Claude config dir on this machine
##
## 🛑 The skill lives here, NOT in the repo's skills/ directory. Anything under
## skills/ ships in `make dist`, and this is experimental.
CLAUDE_DIRS ?= $(wildcard $(HOME)/.claude-personal $(HOME)/.claude-inevitable $(HOME)/.claude)

## Point every Claude config dir at the CHECKOUT's skills
##
## ⚠️ THIS OVERWRITES LINKS TO THE INSTALLED COPY. Since 26.824.3 the formula
## ships all five skills to `share/apple-tools/skills`, and a machine may be
## linked there instead. Use this while EDITING a skill, so Claude sees the
## change without a release; use `link-installed-skills` to go back.
install-skill:
	@test -n "$(CLAUDE_DIRS)" || { echo "error: no Claude config dir found"; exit 1; }
	@for dir in $(CLAUDE_DIRS); do \
	  mkdir -p "$$dir/skills"; \
	  ln -sfn "$(LAB)/skill/apple-index" "$$dir/skills/apple-index"; \
	  echo "  linked $$dir/skills/apple-index"; \
	done

## Point every Claude config dir at the INSTALLED skills
##
## 🛑 `share/apple-tools` is a symlink Homebrew rewrites on every upgrade, so a
## link through it stays valid across versions. Do NOT link into the Cellar
## path directly — that dangles the moment the next version lands, which is
## exactly how 26.824.2 shipped a broken `apple-index` skill.
BREW_SKILLS ?= $(shell brew --prefix 2>/dev/null)/share/apple-tools/skills

link-installed-skills:
	@test -d "$(BREW_SKILLS)" || { echo "error: $(BREW_SKILLS) not found. brew install apple-tools"; exit 1; }
	@test -n "$(CLAUDE_DIRS)" || { echo "error: no Claude config dir found"; exit 1; }
	@for dir in $(CLAUDE_DIRS); do \
	  mkdir -p "$$dir/skills"; \
	  for skill in "$(BREW_SKILLS)"/*; do \
	    ln -sfn "$$skill" "$$dir/skills/$$(basename $$skill)"; \
	  done; \
	  echo "  linked $$dir/skills -> $(BREW_SKILLS)"; \
	done

uninstall-skill:
	@for dir in $(CLAUDE_DIRS); do \
	  rm -f "$$dir/skills/apple-index"; echo "  removed $$dir/skills/apple-index"; \
	done

## A small end-to-end run: notes only
demo: build
	./index.py init
	./index.py ingest --source notes --limit 40
	./index.py embed
	./index.py status

status:
	./bin/apple-index status

test:
	./test-incremental.py --source mail,calendar,notes,messages
	./eval.py

clean:
	rm -rf vec/.build
