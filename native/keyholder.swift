// keyholder (macOS) — holds a key combo down until told to release.
//
// Protocol, one command per line on stdin:
//   D <mods> <key>   press and HOLD. mods is "-" or a comma list: ctrl,alt,shift,cmd
//   U                release whatever is held
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
        "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79, "f19": 80,
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
    static var held: CGKeyCode?

    static func post(_ key: CGKeyCode, _ flags: CGEventFlags, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
        else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    static func press(_ key: CGKeyCode, _ flags: CGEventFlags) {
        releaseHeld()
        post(key, flags, down: true)
        held = key
    }

    static func releaseHeld() {
        guard let key = held else { return }
        post(key, [], down: false)
        held = nil
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

    case "D":
        guard parts.count == 3, let key = Keyholder.keys[String(parts[2]).lowercased()] else {
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
        Keyholder.press(key, flags)

    default:
        continue
    }
}

// stdin closed — Stream Deck killed the plugin. Never leave a key down.
Keyholder.releaseHeld()
