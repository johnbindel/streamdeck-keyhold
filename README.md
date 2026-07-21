# Key Hold — a Stream Deck plugin that actually holds a key

Stream Deck cannot hold a key down. Press a key, and it sends a keystroke and releases it
immediately. That makes push-to-talk impossible: a dictation app waiting for you to *hold*
a hotkey sees a tap and stops listening instantly.

This plugin holds the hotkey for exactly as long as you hold the Stream Deck key or pedal,
and releases it when you let go. You can also configure an optional second hotkey that is
tapped when you let go. It exists mainly for **push-to-talk dictation on macOS**, where
nothing else did the job.

Works with Stream Deck keys, the Stream Deck Pedal, and any other Stream Deck surface.

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

Then drag **Hold Key** onto a key or pedal. Click the **Hold** field and press the desired
combination. Do the same in **Release** if the target app needs a separate shortcut after
push-to-talk ends. Use the × button beside either field to clear it.

On macOS, Stream Deck needs Accessibility permission to send keystrokes at all
(System Settings → Privacy & Security → Accessibility). If your existing Hotkey actions work,
you already have this.

## Build from source

Requires Node 20+, and Xcode command line tools (macOS) or MSVC (Windows).

```bash
./build.sh          # macOS: builds, installs, and restarts Stream Deck
```

Two things in the build are load-bearing and non-obvious:

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
  → plugin.js          onKeyDown → "D ctrl,alt,cmd t"      (Node, via the Elgato SDK)
                       onKeyUp   → "U", then optional "T - f13"
  → keyholder          holds the combo until told to release  (Swift on macOS, C++ on Windows)
```

The helper is a long-lived process reading one command per line on stdin. It owns the combo
semantics because they differ per platform. **macOS** posts modifier `flagsChanged` events
and carries the accumulated flags on the regular key event. **Windows** uses `SendInput` to
press each modifier, then the key, then release them in reverse.

On macOS the events are built on a `hidSystemState` source and posted to the `cghidEventTap`
— the lowest injection point CoreGraphics exposes.

The helper always tracks what it is holding and releases it on `SIGTERM`, `SIGINT`, `SIGHUP`,
and stdin close. A key left stuck down is the worst failure mode here — a stuck modifier makes
the machine unusable until logout — so every exit path releases.

## Status

macOS is tested and in daily use. **The Windows build compiles in CI but is untested on real
hardware** — if you try it, please open an issue either way.

## License

MIT
