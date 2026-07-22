#!/bin/bash
# Regenerates every PNG in imgs/ from the two SVG sources.
#
# Each raster is rendered from the vector at its final size rather than resampled from a
# larger one, so the small ones stay crisp. The sizes are not interchangeable — Stream Deck
# gives each image a different job, and Marketplace rejects the wrong dimensions:
#
#   action   20  Actions[].Icon      — beside the action in the action list
#   category 28  CategoryIcon        — beside the plugin's group in that list
#   key      72  States[].Image      — drawn on the key or pedal itself
#   plugin  256  Icon                — Stream Deck preferences and the Marketplace listing
#
# The first three must be a white stroke on transparent, so they come from icon.svg. The
# plugin icon may carry a background, so it has its own source.
#
# Needs rsvg-convert (brew install librsvg). Only run when the artwork changes; the PNGs
# are committed, so a normal build does not need this.
set -e
cd "$(dirname "$0")/.."

command -v rsvg-convert >/dev/null || {
	echo "rsvg-convert not found — brew install librsvg" >&2
	exit 1
}

render() {  # render <name> <size> <source.svg>
	rsvg-convert -w "$2" -h "$2" "$3" -o "imgs/$1.png"
	rsvg-convert -w "$((2 * $2))" -h "$((2 * $2))" "$3" -o "imgs/$1@2x.png"
	echo "imgs/$1.png ${2}x${2}, imgs/$1@2x.png $((2 * $2))x$((2 * $2))"
}

render action 20 imgs/icon.svg
render category 28 imgs/icon.svg
render key 72 imgs/icon.svg
render plugin 256 imgs/plugin-icon.svg
