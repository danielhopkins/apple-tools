# The app that owns the grants, the index and the schedule.
#
# 🛑 Not wired into the root Makefile. `make build`, `make test` and `make dist`
# at the repo root do not touch this.

APP        := AppleTools
VERSION    := $(shell cat ../VERSION)
BUILD      := $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
DERIVED    := $(CURDIR)/build
PRODUCT    := $(DERIVED)/Build/Products/Release/$(APP).app
TEAM       := 25RCAA3JLJ
# ⚠️ The notarytool profile is named for the app it was first stored for. It
# holds this developer's App Store Connect API key, not MiniMusic's.
#   xcrun notarytool store-credentials NAME --key AuthKey_*.p8 --key-id ID --issuer UUID
PROFILE    := MiniMusic
IDENTITY   := Developer ID Application
BUNDLE_ID  := com.boulderhopkins.apple-tools

export APP_VERSION := $(VERSION)
export APP_BUILD   := $(BUILD)

.PHONY: generate build release run install uninstall clean stop grant logs notarize

## Regenerate the Xcode project from project.yml
generate:
	xcodegen generate --spec project.yml --quiet
	@echo "generated $(APP).xcodeproj  ($(VERSION) build $(BUILD))"

## Release build, signed with Developer ID
##
## 🛑 Developer ID even for a local build. An ad-hoc signature keys the TCC
## grant to the cdhash, so every rebuild would drop Full Disk Access and the
## user would approve it again by hand. A stable identity survives a rebuild.
build: generate
	xcodebuild -project $(APP).xcodeproj -scheme $(APP) \
	  -configuration Release -derivedDataPath $(DERIVED) \
	  CODE_SIGN_IDENTITY="$(IDENTITY)" DEVELOPMENT_TEAM=$(TEAM) \
	  build | grep -Ev "^\s*$$" | tail -20
	@echo "built $(PRODUCT)"
	@codesign -dv "$(PRODUCT)" 2>&1 | grep -E "Identifier|Authority|flags" || true

## Replace the copy in /Applications and start it
##
## ⚠️ macOS keeps the TCC grant against the bundle id and the signature, not the
## path, so replacing the bundle in place does NOT drop Full Disk Access.
install: build stop
	rm -rf "/Applications/$(APP).app"
	cp -R "$(PRODUCT)" /Applications/
	@echo "installed /Applications/$(APP).app"
	@# 🛑 A REBUILD DESTROYS THE NOTARIZATION TICKET, because it re-signs the
	@# bundle. `make install` therefore installs an UNNOTARIZED app unless it
	@# runs `notarize` first — and an unnotarized app gets no TCC prompt at all
	@# on macOS 27.0, so Calendar and Contacts silently fail. This cost hours:
	@# the app was notarized once, and every `make install` after that quietly
	@# replaced it. Use `make release`.
	@xcrun stapler validate "/Applications/$(APP).app" >/dev/null 2>&1 \
	  || echo "⚠️  NOT NOTARIZED. TCC will not prompt. Run: make release"
	open "/Applications/$(APP).app"

## Build, notarize, staple, then install. The only way to install something
## that macOS will show a permission dialog for.
release: notarize stop
	rm -rf "/Applications/$(APP).app"
	cp -R "$(PRODUCT)" /Applications/
	xcrun stapler validate "/Applications/$(APP).app"
	spctl -a -vv "/Applications/$(APP).app"
	open "/Applications/$(APP).app"

run: build stop
	open "$(PRODUCT)"

## 🛑 Quit it properly. `pkill -9` leaves the search endpoint bound to the
## socket, and two daemons on one socket made a search take 10.7 seconds once.
stop:
	-@osascript -e 'quit app "$(APP)"' 2>/dev/null
	-@pkill -x $(APP) 2>/dev/null; true
	@sleep 1

## ⚠️ Re-enable the launchd agent the app disabled. Without this,
## uninstalling the app leaves the machine with NO search endpoint.
uninstall: stop
	rm -rf "/Applications/$(APP).app"
	-launchctl enable gui/$$(id -u)/com.boulderhopkins.apple-index
	@echo "re-enabled com.boulderhopkins.apple-index"

## Open the pane the user has to toggle by hand. No API can ask for this one.
grant:
	open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"

logs:
	@tail -n 40 "$$HOME/Library/Application Support/apple-tools/logs/search.log" 2>/dev/null \
	  || echo "no search log yet"
	@echo "--- app ---"
	@log show --last 10m --predicate 'process == "$(APP)"' --style compact 2>/dev/null | tail -30

## Notarize the built app and staple the ticket into the bundle
##
## 🛑 NOT OPTIONAL, and not only for distribution. Measured 2026-08-23: an
## UNNOTARIZED app gets NO TCC prompt at all on macOS 27.0 — calendar returned
## false without recording anything, reminders never returned, and contacts was
## recorded as DENIED without the user ever seeing a dialog. See README.md.
##
## ⚠️ notarytool rejects a bundle whose helpers are not hardened-runtime signed,
## and the summary line does not say which file. Read the JSON log.
notarize: build
	rm -f $(DERIVED)/$(APP).zip
	ditto -c -k --keepParent "$(PRODUCT)" "$(DERIVED)/$(APP).zip"
	xcrun notarytool submit "$(DERIVED)/$(APP).zip" \
	  --keychain-profile "$(PROFILE)" --wait
	xcrun stapler staple "$(PRODUCT)"
	spctl -a -vv "$(PRODUCT)"

clean:
	rm -rf $(DERIVED) $(APP).xcodeproj
