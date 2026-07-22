# Changelog

## 1.3.0

**Requires Stream Deck 6.9 or later.** Elgato's Marketplace requires plugins to declare
SDK version 3, which in turn requires app version 6.9, and that combination is what makes a
plugin eligible for Marketplace's DRM — file encryption and tamper checking. Nothing about
how the plugin behaves changes; if you are on an older Stream Deck, 1.2.0 remains available
and works.

**The plugin no longer ships with the Node debugger switched on.** The manifest asked for
`--inspect`, which is a development convenience that had no business in a released build.

## 1.2.0

**Recording a hotkey no longer fires it.** The whole point of this plugin is to send a
combination another app is listening for, and until now recording one triggered it —
`⌃⌥⌘T` would run whatever `⌃⌥⌘T` was bound to instead of being recorded. A property
inspector is a web view, so by the time a keystroke reaches it the system has already
acted; nothing in the page can undo that. The plugin's helper now takes the keyboard while
you are recording, swallows every key, and reports what it saw. Combinations the system
would otherwise eat outright, like `⌘Tab`, are recordable too, and the left or right
modifier you actually pressed is the one that gets stored.

If the keyboard cannot be taken — no Accessibility permission on macOS — recording falls
back to the old behaviour, which still handles combinations that are not already
shortcuts. The keyboard is always given back: when you finish, when the inspector closes,
and after fifteen seconds regardless.

**Three new actions**, each a different interaction rather than the same one behind a
setting:

- **Toggle Hold** — press once to start holding, press again to let go. For long dictation,
  or when holding a pedal down is uncomfortable. It lights up while it is running and lets
  go by itself after five minutes if you forget.
- **Timed Tap** — one press, held for a time you set. For apps that ignore a key sent and
  released in the same instant.
- **Repeat Key** — sends the combination over and over while you hold the button, rather
  than holding it, for apps and games that act on each keypress.

**Hold Key now shows when it is holding**, using the same lit state as Toggle Hold.

**The settings panel opens with one field.** It previously showed five. The before/after
release hotkeys and their pauses moved behind *Release options*, since most setups need
none of them.

**A correctly sized plugin icon.** The manifest pointed at a 28px image for a slot that
wants 256px, so Stream Deck was scaling it up eightfold.

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
