# The lab is deliberately NOT wired into the root Makefile. Nothing here is
# part of `make build`, `make test` or `make dist`.
LAB     := $(shell pwd)
PREFIX  ?= $(HOME)/bin
LOGDIR  := $(HOME)/Library/Application Support/apple-tools
AGENT   := com.boulderhopkins.apple-index
PLIST   := $(HOME)/Library/LaunchAgents/$(AGENT).plist
UV      := $(shell command -v uv)

.PHONY: build install uninstall install-agent uninstall-agent agent-status \
        install-skill link-installed-skills uninstall-skill demo status test \
        test-people test-files test-photos bench bench-compare bench-clean clean

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
	@# 🛑 FIRST, AND ONLY MEANINGFUL HERE. `selfcheck`'s second direction —
	@# a sibling imported but never declared — can only fire in a CHECKOUT: in
	@# a shipped payload that module was never copied, so there is no file to
	@# find. The build and the formula run it for the other direction. Without
	@# this line the direction the comment calls "the one that bit" was
	@# unreachable from every automated path.
	./index.py selfcheck
	./test-people.py
	./test-files.py
	./test-photos.py
	./test-incremental.py --source mail,calendar,notes,messages
	./eval.py

## Retrieval quality against a PUBLIC corpus: EnronQA, 1,254 cases
##
## 🛑 The 29 cases in eval.py cannot decide a model swap. See bench/README.md.
## The first run downloads one Enron inbox; after that it is offline.
INBOX ?= germany-c

bench:
	@test -d bench/enron/corpus || ./bench/enronqa.py fetch --user $(INBOX)
	@test -f bench/enron/enron.db || ./bench/enronqa.py build
	./bench/enronqa.py score --limit 0

## Every fusion strategy against the same cases (~16 min)
bench-compare:
	./bench/enronqa.py score --limit 0 --compare

## Throw the downloaded corpus away
bench-clean:
	rm -rf bench/enron

## The `people` identity rules alone. Offline: no index, no Contacts, no
## network, so this one is safe to run anywhere and takes under a second.
test-people:
	./test-people.py

## Where the `files` source keeps its configuration. Offline, and it pins the
## bug that put it inside the encrypted vault, where an unmount took it away.
test-files:
	./test-files.py

## Offline checks for the Photos reader and the Contacts-id handle
test-photos:
	./test-photos.py

clean:
	rm -rf vec/.build
