// keyholder (macOS) — holds a key combo down until told to release.
//
// Protocol, one command per line on stdin:
//   D <mods> <key>   press and HOLD. Either field may be "-".
//   U                release whatever is held
//   T <mods> <key>   TAP a combo (press and release). mods is a comma list.
//   B <mods> <key>   TAP a combo on top of whatever is held, leaving the hold down.
//
// Modifier events are posted separately so left/right identity is preserved. The regular
// key event also carries the accumulated modifier flags.
//
// Events are built on a .hidSystemState source and posted to .cghidEventTap, the lowest
// injection point CoreGraphics exposes.
//
// State lives in static storage, not top-level vars: in a single-file Swift program the
// top level is an implicit main(), so a signal handler touching top-level vars would be
// "capturing context" and could not become a C function pointer.

import CoreGraphics
import Foundation

enum Keyholder {
    static let source = CGEventSource(stateID: .hidSystemState)

    /// macOS virtual keycodes. F13-F19 are the useful ones: macOS ignores them, so they
    /// collide with nothing.
    static let keys: [String: CGKeyCode] = [
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34,
        "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12,
        "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
        "space": 49,
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21,
        "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
        "enter": 36, "tab": 48, "escape": 53, "backspace": 51, "delete": 117,
        "insert": 114, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "semicolon": 41, "equal": 24, "comma": 43, "minus": 27, "period": 47,
        "slash": 44, "backquote": 50, "leftbracket": 33, "backslash": 42,
        "rightbracket": 30, "quote": 39,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79, "f19": 80,
        "f20": 90,
    ]

    static let modifierKeys: [String: (CGKeyCode, CGEventFlags)] = [
        "ctrl": (59, .maskControl), "lctrl": (59, .maskControl), "rctrl": (62, .maskControl),
        "alt": (58, .maskAlternate), "lalt": (58, .maskAlternate), "ralt": (61, .maskAlternate),
        "shift": (56, .maskShift), "lshift": (56, .maskShift), "rshift": (60, .maskShift),
        "cmd": (55, .maskCommand), "lcmd": (55, .maskCommand), "rcmd": (54, .maskCommand),
    ]

    /// What we are currently holding, so we can always release it — even if the plugin
    /// dies mid-hold. A stuck key is the worst failure here: it would make the machine
    /// unusable until logout.
    static var held: CGKeyCode?
    static var heldModifiers: [(CGKeyCode, CGEventFlags)] = []

    static func post(_ key: CGKeyCode, _ flags: CGEventFlags, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
        else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    static func postModifier(_ key: CGKeyCode, _ flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        else { return }
        event.type = .flagsChanged
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    static func press(_ key: CGKeyCode?, _ modifiers: [(CGKeyCode, CGEventFlags)]) {
        releaseHeld()
        var currentFlags: CGEventFlags = []
        for (modifierKey, flag) in modifiers {
            currentFlags.insert(flag)
            postModifier(modifierKey, currentFlags)
            heldModifiers.append((modifierKey, flag))
        }
        if let key {
            post(key, currentFlags, down: true)
            held = key
        }
    }

    /// Tap a combo *without* disturbing the hold — this is what makes a "before release"
    /// hotkey different from an "after release" one. Modifiers already held are reused
    /// rather than re-posted, and a tap key identical to the held key is skipped: its
    /// key-up would cancel the very hold we are trying to preserve.
    static func tapOver(_ key: CGKeyCode?, _ modifiers: [(CGKeyCode, CGEventFlags)]) {
        var heldFlags: CGEventFlags = []
        for (_, flag) in heldModifiers {
            heldFlags.insert(flag)
        }
        let heldModifierKeys = Set(heldModifiers.map { $0.0 })
        var extra = modifiers.filter { !heldModifierKeys.contains($0.0) }

        var currentFlags = heldFlags
        for (modifierKey, flag) in extra {
            currentFlags.insert(flag)
            postModifier(modifierKey, currentFlags)
        }

        if let key {
            if key == held {
                FileHandle.standardError.write(
                    Data("keyholder: skipping tap of the key already held\n".utf8))
            } else {
                post(key, currentFlags, down: true)
                post(key, currentFlags, down: false)
            }
        }

        while let (modifierKey, _) = extra.popLast() {
            currentFlags = heldFlags
            for (_, remainingFlag) in extra {
                currentFlags.insert(remainingFlag)
            }
            postModifier(modifierKey, currentFlags)
        }
    }

    static func releaseHeld() {
        var currentFlags: CGEventFlags = []
        for (_, flag) in heldModifiers {
            currentFlags.insert(flag)
        }
        if let key = held {
            post(key, currentFlags, down: false)
            held = nil
        }
        while let (modifierKey, _) = heldModifiers.popLast() {
            currentFlags = []
            for (_, remainingFlag) in heldModifiers {
                currentFlags.insert(remainingFlag)
            }
            postModifier(modifierKey, currentFlags)
        }
    }
}

func onSignal(_ signum: Int32) {
    Keyholder.releaseHeld()
    exit(0)
}

setvbuf(stdout, nil, _IONBF, 0)

guard Keyholder.source != nil else {
    FileHandle.standardError.write(Data("keyholder: could not create event source\n".utf8))
    exit(1)
}

for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, onSignal)
}

while let line = readLine(strippingNewline: true) {
    let parts = line.split(separator: " ")
    guard let verb = parts.first else { continue }

    switch verb {
    case "U":
        Keyholder.releaseHeld()

    case "D", "T", "B":
        guard parts.count == 3 else {
            FileHandle.standardError.write(Data("keyholder: bad command: \(line)\n".utf8))
            continue
        }
        let keyName = String(parts[2]).lowercased()
        let key = keyName == "-" ? nil : Keyholder.keys[keyName]
        if keyName != "-" && key == nil {
            FileHandle.standardError.write(Data("keyholder: bad command: \(line)\n".utf8))
            continue
        }
        var modifiers: [(CGKeyCode, CGEventFlags)] = []
        if parts[1] != "-" {
            for name in parts[1].split(separator: ",") {
                guard let modifier = Keyholder.modifierKeys[String(name).lowercased()] else { continue }
                modifiers.append(modifier)
            }
        }
        guard key != nil || !modifiers.isEmpty else { continue }
        if verb == "B" {
            Keyholder.tapOver(key, modifiers)
            continue
        }
        Keyholder.press(key, modifiers)
        if verb == "T" {
            Keyholder.releaseHeld()
        }

    default:
        continue
    }
}

// stdin closed — Stream Deck killed the plugin. Never leave a key down.
Keyholder.releaseHeld()
