# Key Hold — a Stream Deck plugin that actually holds a key

Stream Deck cannot hold a key down. Press a key, and it sends a keystroke and releases it
immediately. That makes push-to-talk impossible: a dictation app waiting for you to *hold*
a hotkey sees a tap and stops listening instantly.

This plugin holds the hotkey for exactly as long as you hold the Stream Deck key or pedal,
and releases it when you let go. You can also configure up to two optional extra hotkeys:
one tapped **before** the hold is released (while it is still down) and one tapped
**after**. Use either, both, or neither. It exists mainly for **push-to-talk dictation on
macOS**, where nothing else did the job.

Works with Stream Deck keys, the Stream Deck Pedal, and any other Stream Deck surface.

## Actions

| Action | What it does |
|---|---|
| **Hold Key** | Holds the combination for exactly as long as you hold the button or pedal. The key lights up while it is down. |
| **Toggle Hold** | Press once to start holding, press again to let go — for long dictation, or when holding a pedal down is uncomfortable. Lights up while it runs, and lets go by itself after five minutes if you forget. |
| **Timed Tap** | One press, held for a time you set. For apps that ignore a tap sent and released in the same instant. |
| **Repeat Key** | Sends the combination over and over while you hold the button, rather than holding it. For apps and games that act on each keypress and ignore a held key. |

Hold Key and Toggle Hold share the optional **Before release** and **After release**
hotkeys and their pauses, tucked behind *Release options* since most setups need neither.

## Why the built-in actions don't work

Stream Deck ships three actions that look like they should do this. None do:

| Action | What it actually does |
|---|---|
| **Hotkey** | Presses and releases immediately. A tap. |
| **Hotkey Switch** | *Toggles* between two hotkeys. Not a hold. |
| **Key Logic** — "press and hold" | Hold is the **activation condition**, not the output. Holding the key for N ms fires a *different action* — which is still a tap. |

The Stream Deck SDK does expose `onKeyDown` and `onKeyUp` as separate events. That seam is
the only way to get a real hold, and it's what this plugin is built on.

There is one other open-source plugin using this seam,
[voji/hotkeyhold_sd](https://github.com/voji/sendkey_sd) — but it's Windows-only and has no
modifier support. As far as I can tell, this is the first macOS implementation.

## Recording a shortcut that is already taken

The whole point of this plugin is to send a hotkey another app is listening for — so
recording it must not trigger it. A property inspector is a web view, and by the time a
keystroke reaches one the system has already acted on it: `preventDefault` stops the page
from responding, but cannot stop macOS or Windows from having already fired whatever the
combination is bound to. Elgato's own Hotkey field avoids this by capturing below the
browser, which no part of the plugin SDK exposes.

So the helper does it. While a recorder field has focus, the plugin asks the helper to tap
the keyboard, swallow every key, and report what it saw; the property inspector builds the
combination from those reports instead of from browser events. Recording `⌃⌥⌘T` records it
rather than firing it, and keys the system would otherwise eat entirely — `⌘Tab`, `⌃↑` —
are recordable too.

Two things make a swallowed keyboard safe: the helper releases it after fifteen seconds no
matter what, and the plugin releases it as soon as the inspector closes. If the tap cannot
be created at all — no Accessibility permission on macOS — recording falls back to browser
events, which still works for combinations that are not already shortcuts.

## Modifier-only shortcuts

The recorder accepts regular keys, key combinations, and modifier-only shortcuts made from
Ctrl, Alt/Option, Shift, and Cmd/Win. It preserves the left or right modifier you record.
Fn/Globe is not exposed to the property inspector as a recordable key. There is also an
important limitation outside the plugin: some apps reject synthetic modifier-only events
even though they accept synthetic regular keys.

Many dictation apps default their push-to-talk to a bare modifier. Apps that watch bare
modifiers may read them below the CGEvent layer, where they can tell injected events from
real hardware and deliberately reject the injected ones.

No Stream Deck plugin can defeat that filtering. Neither can BetterTouchTool, Keyboard Maestro,
Hammerspoon, or anything else that injects at that layer. (Karabiner-Elements *can*, because
it installs a virtual HID device at the driver level — but Karabiner can only remap real HID
devices, and the Stream Deck Pedal isn't one.)

The same apps accept a synthetic **regular key held down** without complaint, because
ordinary hotkeys go through a different code path that doesn't do hardware-vs-synthetic
filtering.

If a modifier-only shortcut is ignored, set the target app's shortcut to a regular key plus
modifiers — `Ctrl+Alt+Cmd+T`, or an F13–F19 key — and record the same combination here.

## Install

Download the `.streamDeckPlugin` file from
[Releases](https://github.com/johnbindel/streamdeck-keyhold/releases) and double-click it.

Then drag one of the four actions onto a key or pedal — **Hold Key** is the one you want
for push-to-talk. Click the **Hold** field and press the desired combination. If the target app needs a separate shortcut to end push-to-talk, record it in
**Before release** or **After release** depending on which the app expects — some want the
stop hotkey while the talk key is still down, others want it once the talk key is gone. Use
the × button beside any field to clear it.

**Pause before** and **Pause after** sit either side of letting go of the hold, and are 0 by
default. Raise them if the target app misses a hotkey that lands in the same instant as the
release; a few tens of milliseconds is usually enough. **Pause before** on its own is also a
way to keep holding for a moment after you let go, which can stop a dictation app clipping
your last word.

On macOS, Stream Deck needs Accessibility permission to send keystrokes at all
(System Settings → Privacy & Security → Accessibility). If your existing Hotkey actions work,
you already have this.

## Build from source

Requires Node 20+, and Xcode command line tools (macOS) or MSVC (Windows).

```bash
./build.sh          # macOS: builds, installs, and restarts Stream Deck
```

Two things in the build are load-bearing and non-obvious:

- **`package.json` is the version source of truth.** Packaging generates the plugin manifest
  version from it and appends the fourth component required by Stream Deck (`1.0.2` becomes
  `1.0.2.0`).

- **The `createRequire` banner in the esbuild step is required.** `ws`, a CommonJS dependency
  inside `@elgato/streamdeck` itself, calls `require("events")`, which an ESM bundle cannot
  otherwise satisfy. Without the banner the plugin throws on import, before any of its own
  code runs, and Stream Deck disables it as "unstable" with only a yellow warning triangle to
  show for it.
- **`env -u SDKROOT` before `swiftc`.** If you use Nix, a devshell may export an `SDKROOT`
  that the system Swift compiler refuses to build against.

## How it works

```
Stream Deck key/pedal
  → plugin.js          onKeyDown → "D <id> ctrl,alt,cmd t"  (Node, via the Elgato SDK)
                       onKeyUp   → optional "T - f14", then "U <id>",
                                   then optional "T - f13"
  → keyholder          holds the combo until told to release  (Swift on macOS, C++ on Windows)
```

`T` taps *on top of* whatever is held rather than replacing it, which is what makes the two
optional slots different features: the before-release hotkey reaches the app while the held
key is still down. Modifiers already held are reused instead of re-pressed, and a tap of a
key that is currently held is skipped — its key-up would cancel the hold that owns it.

Holds are keyed by action id, so two pedals can be down at once and each releases only its
own keys. A key or modifier shared by both stays down until the last hold wants it gone.

Two backstops guard against the plugin's worst failure, a key left down forever. The helper
releases everything on `SIGTERM`, `SIGINT`, `SIGHUP`, and stdin close. The plugin also
releases on `onWillDisappear` — a profile switch or an unplugged device can swallow the
key-up — and gives every hold a five-minute deadline in case one is lost anyway.

The helper is a long-lived process reading one command per line on stdin. It owns the combo
semantics because they differ per platform. **macOS** posts modifier `flagsChanged` events
and carries the accumulated flags on the regular key event. **Windows** uses `SendInput` to
press each modifier, then the key, then release them in reverse.

On macOS the events are built on a `hidSystemState` source and posted to the `cghidEventTap`
— the lowest injection point CoreGraphics exposes.

A key left stuck down is the worst failure mode here — a stuck modifier makes the machine
unusable until logout — so every exit path releases.

## Status

macOS is tested and in daily use. **The Windows build compiles in CI but is untested on real
hardware** — if you try it, please open an issue either way.

## License

MIT
