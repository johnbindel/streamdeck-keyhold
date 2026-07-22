#!/bin/bash
# Regenerates every PNG in imgs/ from imgs/icon.svg.
#
# Each raster is rendered from the vector at its final size rather than resampled from a
# larger one, so the small ones stay crisp. The three sizes are the three jobs Stream Deck
# gives an image: the action list icon (20), the plugin and category icon (28), and the
# image drawn on the key itself (72). Each also needs a @2x.
#
# Needs rsvg-convert (brew install librsvg). Only run when the artwork changes; the PNGs
# are committed, so a normal build does not need this.
set -e
cd "$(dirname "$0")/.."

command -v rsvg-convert >/dev/null || {
	echo "rsvg-convert not found — brew install librsvg" >&2
	exit 1
}

render() {  # render <name> <size>
	rsvg-convert -w "$2" -h "$2" imgs/icon.svg -o "imgs/$1.png"
	rsvg-convert -w "$((2 * $2))" -h "$((2 * $2))" imgs/icon.svg -o "imgs/$1@2x.png"
	echo "imgs/$1.png ${2}x${2}, imgs/$1@2x.png $((2 * $2))x$((2 * $2))"
}

render action 20   # icon beside the action in the Stream Deck action list
render plugin 28   # plugin icon and category icon
render key 72      # what is actually drawn on the key or pedal
