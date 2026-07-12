#!/bin/bash
# Builds the plugin and installs it into Stream Deck, then restarts the app.
set -e
cd "$(dirname "$0")"

OUT="build/com.johnbindel.keyhold.sdPlugin"
DEST="$HOME/Library/Application Support/com.elgato.StreamDeck/Plugins/com.johnbindel.keyhold.sdPlugin"

[ -d node_modules ] || npm install @elgato/streamdeck esbuild

rm -rf "$OUT"
mkdir -p "$OUT/bin" "$OUT/imgs" "$OUT/ui"

# env -u SDKROOT: a nix devshell may export an SDK that the system swiftc cannot build against.
env -u SDKROOT -u DEVELOPER_DIR /usr/bin/xcrun --sdk macosx swiftc -O \
  -o "$OUT/bin/keyholder" native/keyholder.swift

# The createRequire banner is required: `ws`, a CommonJS dep inside @elgato/streamdeck,
# calls require("events"), which an ESM bundle cannot otherwise satisfy. Without this the
# plugin crashes on import and Stream Deck disables it as unstable.
./node_modules/.bin/esbuild src/plugin.js --bundle --platform=node --format=esm \
  --outfile="$OUT/bin/plugin.js" \
  --banner:js="import { createRequire } from 'node:module'; const require = createRequire(import.meta.url);"

cp manifest.json "$OUT/manifest.json"
cp ui/inspector.html "$OUT/ui/inspector.html"
cp imgs/*.png "$OUT/imgs/"

rm -rf "$DEST"
cp -R "$OUT" "$DEST"

osascript -e 'quit app "Elgato Stream Deck"' 2>/dev/null || true
sleep 3
open -a "Elgato Stream Deck"
echo "installed and restarted: $DEST"
