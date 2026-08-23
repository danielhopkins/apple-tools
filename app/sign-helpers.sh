#!/bin/bash
# Copy the staged helpers into the bundle and sign each one.
#
# 🛑 INSIDE-OUT, and never `codesign --deep`. Apple has said so for years:
# --deep re-signs nested code with the OUTER identity and flags, which quietly
# drops each helper's own hardened runtime. Xcode signs the outer bundle after
# this phase runs, so signing each helper here is the correct order.
#
# ⚠️ notarytool REJECTS a bundle whose helpers are not hardened-runtime signed,
# and the summary line does not name the file. Read the JSON log.
set -euo pipefail
STAGE="${SRCROOT}/build/stage"
CONTENTS="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}"

[ -d "$STAGE" ] || { echo "warning: no staged payload; run app/stage.sh"; exit 0; }

rm -rf "${CONTENTS}/Helpers" "${CONTENTS}/Resources/index" "${CONTENTS}/Resources/notes"
mkdir -p "${CONTENTS}/Helpers" "${CONTENTS}/Resources"
cp -R "$STAGE/Helpers/." "${CONTENTS}/Helpers/"
cp -R "$STAGE/index" "${CONTENTS}/Resources/index"
cp -R "$STAGE/notes" "${CONTENTS}/Resources/notes"

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  echo "warning: no signing identity; helpers left unsigned"
  exit 0
fi

# 🛑 SIGN EVERY EXECUTABLE, INCLUDING THE SHELL SCRIPTS. `Contents/Helpers` is
# one of the directories codesign treats as CODE, not as resources, so an
# unsigned `apple` dispatcher there fails the outer verify with "code object is
# not signed at all — In subcomponent: Contents/Helpers/apple". A script signs
# fine; the signature goes in an extended attribute, which `ditto` and a DMG
# both preserve.
#
# ⚠️ `--options runtime` is meaningless on a script and harmless, so this does
# not branch on the file type. Branching on Mach-O is exactly what skipped the
# dispatcher.
while IFS= read -r -d '' file; do
  codesign --force --options runtime --timestamp \
           --sign "$IDENTITY" "$file" >/dev/null
done < <(find "${CONTENTS}/Helpers" "${CONTENTS}/Resources/index" -type f -perm -u+x -print0)

# 🛑 RE-SEAL THE OUTER BUNDLE. Xcode signs the app at the END of the build,
# before this phase adds anything, so the signature it wrote no longer covers
# what is now inside: `codesign --verify` reports "a sealed resource is missing
# or invalid", and notarization refuses it.
#
# ⚠️ NO `--deep`. It would re-sign every helper with the outer flags and drop
# the hardened runtime each one was just given. The helpers are already signed
# above; this seals the wrapper around them.
APP="${BUILT_PRODUCTS_DIR}/${WRAPPER_NAME}"
ENTITLEMENTS="${SRCROOT}/AppleTools.entitlements"
codesign --force --options runtime --timestamp \
         --entitlements "$ENTITLEMENTS" \
         --sign "$IDENTITY" "$APP" >/dev/null
codesign --verify --strict "$APP"
echo "signed the helpers and re-sealed ${WRAPPER_NAME}"
