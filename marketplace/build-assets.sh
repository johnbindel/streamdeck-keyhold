#!/bin/bash
# Regenerates the Marketplace listing assets.
#
# Sizes come from Elgato's product guidelines and are not negotiable at submission time:
#   app-icon.png   288x288    the icon on the Marketplace listing
#   thumbnail.png  1920x960   the card users see before opening the listing
#   gallery-N.png  1920x960   at least three are required, up to ten allowed
#
# gallery-2 is a screenshot of the real property inspector, driven with a sample
# configuration rather than mocked up, so it can never drift from the shipped UI.
#
# Needs rsvg-convert (brew install librsvg) and Google Chrome.
set -e
cd "$(dirname "$0")"

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || { echo "Google Chrome not found at $CHROME" >&2; exit 1; }
command -v rsvg-convert >/dev/null || { echo "rsvg-convert not found — brew install librsvg" >&2; exit 1; }

shoot() {  # shoot <page.html> <out.png> <width> <height> [scale]
	"$CHROME" --headless --disable-gpu --hide-scrollbars \
		--force-device-scale-factor="${5:-1}" \
		--window-size="$3,$4" --screenshot="$2" "file://$PWD/$1" 2>/dev/null
	echo "$2 $(sips -g pixelWidth -g pixelHeight "$2" | tr -d '\n' | sed 's/.*pixelWidth: //;s/ *pixelHeight: /x/')"
}

rsvg-convert -w 288 -h 288 ../imgs/marks/plugin.svg -o app-icon.png
echo "app-icon.png 288x288"

# The inspector screenshot: inject a fake socket so the real page renders real settings.
python3 - <<'PY'
import pathlib
html = pathlib.Path("../ui/hold.html").read_text()
stub = """
<script>
window.addEventListener("load", () => {
  const actionInfo = JSON.stringify({payload:{settings:{
    key:"t", modifiers:["ctrl","alt","cmd"],
    preReleaseKey:"f14", preReleaseModifiers:[],
    releaseKey:"escape", releaseModifiers:[],
    pauseBeforeReleaseMs:120, pauseAfterReleaseMs:0
  }}});
  window.WebSocket = function(){ return {send(){}, set onopen(f){ setTimeout(f,0); }, set onmessage(f){}}; };
  connectElgatoStreamDeckSocket(1, "uuid", "registerPropertyInspector", "{}", actionInfo);
});
</script>
"""
# Open the disclosure: the gallery shot should show every setting, even though
# the panel opens collapsed for real use.
html = html.replace("<details>", "<details open>")
pathlib.Path("inspector-demo.html").write_text(html.replace("</body>", stub + "</body>"))
PY
shoot inspector-demo.html inspector.png 500 380 2

shoot thumbnail.html thumbnail.png 1920 960
shoot gallery-1.html gallery-1.png 1920 960
shoot gallery-2.html gallery-2.png 1920 960
shoot gallery-3.html gallery-3.png 1920 960
shoot gallery-4.html gallery-4.png 1920 960

rm -f inspector-demo.html
