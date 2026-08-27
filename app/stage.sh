#!/bin/bash
# Assemble everything the app carries, from the repo's own build outputs.
#
# 🛑 THE APP MUST NOT DEPEND ON HOMEBREW. Until this existed, `Paths` fell
# through to /opt/homebrew, so the cask had to `depends_on formula:
# "apple-tools"` and a user with only the app had no dispatcher, no index.py,
# no vec and no Core ML packages.
#
# ⚠️ Everything here is COPIED, never symlinked. A symlink out of the bundle
# breaks the signature and hands TCC a path outside the app.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
STAGE="$REPO/app/build/stage"

rm -rf "$STAGE"
mkdir -p "$STAGE/Helpers" "$STAGE/index" "$STAGE/notes" "$STAGE/skills"

echo "==> swift tools"
[ -x swift/.build/release/apple-mail ] || (cd swift && swift build -c release)
for tool in apple-calendar apple-contacts apple-mail apple-maps \
            apple-messages apple-phone reminders; do
  cp "swift/.build/release/$tool" "$STAGE/Helpers/$tool"
done
cp bin/apple "$STAGE/Helpers/apple"
# 🛑 The signed proxy client. It is built by the app's own Xcode project, not
# by `swift build`, because the app checks its code signature on the socket and
# an ad-hoc or Apple-signed binary would fail that check.
if [ -x app/build/Build/Products/Release/apple-proxy ]; then
  cp app/build/Build/Products/Release/apple-proxy "$STAGE/Helpers/apple-proxy"
else
  echo "note: apple-proxy not built yet; it lands on the next build"
fi

echo "==> notes (python, stdlib only)"
# 🛑 NOT in Helpers. `codesign` treats every file under `Contents/Helpers` as
# CODE, so a data file there fails the outer verify with "code object is not
# signed at all — In subcomponent: .../notestore.proto". Only executables
# belong in Helpers; everything else goes under Resources, which is sealed as
# resources instead.
#
# 🛑 apple-notes imports its modules as SIBLINGS, so the whole set stays in one
# directory. The app puts that directory on PATH, and the `apple` dispatcher
# finds `apple-notes` there.
mkdir -p "$STAGE/notes"
cp notes/apple-notes notes/notestore.proto notes/*.py "$STAGE/notes/"

echo "==> index"
[ -x lab/vec/.build/release/vec ] || (cd lab/vec && swift build -c release)
cp lab/vec/.build/release/vec "$STAGE/index/vec"
# 🛑 photos.py travels with index.py. `import photos` lives inside the
# photos adapter, so a bundle without it cannot ingest the Photos
# library at all -- and the app is what does the ingesting.
cp lab/index.py lab/photos.py lab/bin/apple-index "$STAGE/index/"

echo "==> core ml packages"
# ⚠️ The FIXED-shape packages, and `vocab.txt` beside them. `coreml/build-enum`
# costs 1369 MB resident against 192 MB, and a missing vocab.txt makes every
# embed fail at run time rather than at build time.
if [ -d lab/models ]; then SRC=lab/models; else SRC=lab/coreml/build; fi
mkdir -p "$STAGE/index/models"
# 🛑 NAME THE PACKAGES, never `*.mlpackage`. A checkout's `coreml/build` is a
# dev dump holding every shape and every compiled copy — 1.0 GB against the
# 274 MB that ships. A glob picked all of it up.
#
# ⚠️ `.mlpackage` only, not `.mlmodelc`. Core ML compiles a package on first
# load and caches the result itself; shipping both doubles the size for nothing.
#
# 🛑 The FIXED shapes, never `build-enum`. One enumerated package saves 470 MB
# on disk and costs 1369 MB resident against 192 MB, because Core ML holds an
# execution plan per shape.
for shape in s64-b32 s256-b32 s512-b32 s64-b1; do
  pkg="e5-small-v2-${shape}-fp16.mlpackage"
  [ -d "$SRC/$pkg" ] || { echo "missing model: $SRC/$pkg"; exit 1; }
  cp -R "$SRC/$pkg" "$STAGE/index/models/"
done
cp "$SRC/vocab.txt" "$STAGE/index/models/vocab.txt"

echo "==> claude skills"
# 🛑 ALL FIVE, and the fifth lives somewhere else. Four sit in `skills/`, and
# `apple-index` ships inside the index payload at `lab/skill/apple-index`. The
# formula's caveats used to symlink `skills/*` and silently install four out of
# five — the one for the newest feature was the one missing.
mkdir -p "$STAGE/skills"
cp -R skills/* "$STAGE/skills/"
cp -R lab/skill/apple-index "$STAGE/skills/"

echo "==> shortcuts (the Notes write path)"
mkdir -p "$STAGE/index/shortcuts"
cp notes/shortcuts/*.shortcut "$STAGE/index/shortcuts/" 2>/dev/null || true

# 🛑 Check what we staged, here and not at run time. A missing helper shows up
# as "no `apple` dispatcher found on this machine" hours later.
for required in Helpers/apple Helpers/apple-mail notes/apple-notes \
                notes/notestore.py notes/notestore.proto index/vec \
                index/index.py index/photos.py index/models/vocab.txt \
                skills/apple-tools/SKILL.md skills/apple-index/SKILL.md; do
  [ -e "$STAGE/$required" ] || { echo "missing: $required"; exit 1; }
done
echo "staged $(du -sh "$STAGE" | cut -f1) in $STAGE"
