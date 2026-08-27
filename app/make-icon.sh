#!/bin/bash
# Build AppleTools.icns from the artwork the website already uses.
#
# 🛑 THE SOURCE IS THE WEBSITE'S ICON, not a second drawing. One picture, in
# one place; a hand-made copy here would drift the first time either changed.
#
# ⚠️ APPLE'S GRID IS 824 IN 1024, and the artwork fills all 1024. Dropped in
# as-is, this icon is 24% larger than every Apple icon beside it in the Dock —
# which reads as a badly made app rather than as a big icon. The padding is not
# decoration.
set -euo pipefail
cd "$(dirname "$0")"

SOURCE="${1:-$HOME/src/websites/boulderhopkins-com/static/images/apple-tools-icon.png}"
[ -f "$SOURCE" ] || { echo "no artwork at $SOURCE"; exit 1; }

python3 - "$SOURCE" <<'PY'
import sys
from PIL import Image

source = Image.open(sys.argv[1]).convert("RGBA")
# 🛑 LANCZOS, not the default. The icon is read at 16 points in the menu bar
# and a nearest-neighbour shrink turns the terminal prompt into gravel.
art = source.resize((824, 824), Image.LANCZOS)
canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
canvas.paste(art, (100, 100), art)
canvas.save("Icon/AppIcon.png")
print("padded 824 in 1024 -> Icon/AppIcon.png")
PY

rm -rf Icon/AppleTools.iconset
mkdir -p Icon/AppleTools.iconset
# Every size macOS asks for. ⚠️ Miss one and the Dock silently falls back to a
# blurry upscale of the nearest.
for size in 16 32 128 256 512; do
  sips -z $size $size Icon/AppIcon.png \
       --out "Icon/AppleTools.iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Icon/AppIcon.png \
       --out "Icon/AppleTools.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns Icon/AppleTools.iconset -o Icon/AppleTools.icns
rm -rf Icon/AppleTools.iconset
echo "built Icon/AppleTools.icns ($(du -h Icon/AppleTools.icns | cut -f1))"
