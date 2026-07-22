# Changelog

## 1.1.0

**A hotkey can now be tapped before *or* after the hold is released.** The old single
Release slot could only fire once the hold was already gone, which is the wrong moment for
apps whose stop shortcut has to arrive while the talk key is still down. There are now two
optional slots, **Before release** and **After release** — use either, both, or neither.
Buttons configured before this release keep their behaviour: the old setting means
*after*.

**Two optional pauses** sit either side of letting go, 0 by default. Raise them if the
target app misses a hotkey landing in the same instant as the release. **Pause before** on
its own also keeps the hold down for a moment after you let go, which can stop a dictation
app clipping your last word.

**Fixed: two buttons held at once fought over the keyboard.** The helper had a single hold
slot, so pressing a second button released the first one's keys, and the first button's
key-up then released the second one's. Holds are now tracked per action, and a key or
modifier both of them want stays down until the last one lets go.

**Fixed: a lost key-up could leave a key down indefinitely.** Stream Deck can swallow the
key-up when the profile changes or the device is unplugged mid-hold. The plugin now
releases when the button goes away, and every hold has a five-minute deadline as a
backstop.

**A new icon**, drawn as a vector and rendered to each size it is used at. The image on the
key was previously a 20x20 file that the device scaled to 144px, which is why it looked
rough on hardware; it now has its own asset.

**Key names read the way macOS writes them** — `↩ ⌤ ␣ ⇥ ⎋ ⌫ ⌦ ↖ ↘ ⇞ ⇟` — and numpad Enter
is recorded as its own key rather than being folded into Return.

## 1.0.2

Version is derived from `package.json` at build time.

## 1.0.1

First published build: holds a hotkey for as long as the Stream Deck key or pedal is held.
