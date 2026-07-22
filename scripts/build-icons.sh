#!/bin/bash
# Regenerates every PNG in imgs/ from the SVG sources in imgs/marks/.
#
# Each raster is rendered from the vector at its final size rather than resampled from a
# larger one, so the small ones stay crisp. The sizes are not interchangeable — Stream Deck
# gives each image a different job, and Marketplace rejects the wrong dimensions:
#
#   <action>-action  20  Actions[].Icon   — beside the action in the action list
#   <action>-key     72  States[].Image   — drawn on the key or pedal itself
#   category         28  CategoryIcon     — beside the plugin's group in that list
#   plugin          256  Icon             — preferences and the Marketplace listing
#
# Everything except the plugin icon must be a white stroke on transparent, so it comes from
# a mark in imgs/marks/. The plugin icon may carry a background, so it has its own source.
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

for action in hold toggle timed repeat; do
	render "$action-action" 20 "imgs/marks/$action.svg"
	render "$action-key" 72 "imgs/marks/$action.svg"
done

# Hold and Toggle carry a second state, lit while the key is actually down.
for action in hold toggle; do
	render "$action-key-on" 72 "imgs/marks/$action-on.svg"
done

render category 28 imgs/marks/hold.svg
render plugin 256 imgs/marks/plugin.svg
