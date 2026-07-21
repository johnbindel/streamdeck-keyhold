// keyholder (macOS) — holds a key combo down until told to release.
//
// Protocol, one command per line on stdin:
//   D <mods> <key>   press and HOLD. Either field may be "-".
//   U                release whatever is held
//   T <mods> <key>   TAP a combo (press and release). mods is a comma list.
//
// On macOS a combo is ONE key event carrying modifier FLAGS — the modifier keys are not
// pressed separately. Windows differs; see keyholder.cpp. That asymmetry is why the
// helper owns combo semantics rather than the plugin.
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

    static let mods: [String: CGEventFlags] = [
        "ctrl": .maskControl,
        "alt": .maskAlternate,
        "shift": .maskShift,
        "cmd": .maskCommand,
    ]

    /// What we are currently holding, so we can always release it — even if the plugin
    /// dies mid-hold. A stuck key is the worst failure here: it would make the machine
    /// unusable until logout.
    static let modifierKeys: [(CGKeyCode, CGEventFlags)] = [
        (59, .maskControl), (58, .maskAlternate), (56, .maskShift), (55, .maskCommand),
    ]

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

    static func press(_ key: CGKeyCode?, _ flags: CGEventFlags) {
        releaseHeld()
        if let key {
            post(key, flags, down: true)
            held = key
            return
        }

        var currentFlags: CGEventFlags = []
        for (modifierKey, flag) in modifierKeys where flags.contains(flag) {
            currentFlags.insert(flag)
            postModifier(modifierKey, currentFlags)
            heldModifiers.append((modifierKey, flag))
        }
    }

    static func releaseHeld() {
        if let key = held {
            post(key, [], down: false)
            held = nil
        }

        var currentFlags: CGEventFlags = []
        for (_, flag) in heldModifiers {
            currentFlags.insert(flag)
        }
        for (modifierKey, flag) in heldModifiers.reversed() {
            currentFlags.remove(flag)
            postModifier(modifierKey, currentFlags)
        }
        heldModifiers.removeAll()
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

    case "D", "T":
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
        var flags: CGEventFlags = []
        if parts[1] != "-" {
            for name in parts[1].split(separator: ",") {
                guard let flag = Keyholder.mods[String(name).lowercased()] else { continue }
                flags.insert(flag)
            }
        }
        guard key != nil || !flags.isEmpty else { continue }
        Keyholder.press(key, flags)
        if verb == "T" {
            Keyholder.releaseHeld()
        }

    default:
        continue
    }
}

// stdin closed — Stream Deck killed the plugin. Never leave a key down.
Keyholder.releaseHeld()
