// keyholder (macOS) — holds key combos down until told to release.
//
// Protocol, one command per line on stdin:
//   D <id> <mods> <key>   press and HOLD under <id>. Either combo field may be "-".
//   U <id>                release the hold owned by <id>
//   T <mods> <key>        TAP a combo without disturbing anything held
//
// Holds are keyed by id because several Stream Deck buttons or pedals can be down at
// once, and each must release only its own keys. A shared key or modifier stays down
// until the last hold that wants it lets go.
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
        "enter": 36, "numpadenter": 76, "tab": 48, "escape": 53, "backspace": 51,
        "delete": 117,
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

    struct Hold {
        let id: String
        let key: CGKeyCode?
        let modifiers: [(CGKeyCode, CGEventFlags)]
    }

    /// Everything currently held, in press order, so we can always release it — even if
    /// the plugin dies mid-hold. A stuck key is the worst failure here: it would make the
    /// machine unusable until logout.
    static var holds: [Hold] = []

    static func currentFlags() -> CGEventFlags {
        var flags: CGEventFlags = []
        for hold in holds {
            for (_, flag) in hold.modifiers {
                flags.insert(flag)
            }
        }
        return flags
    }

    static func isKeyDown(_ key: CGKeyCode) -> Bool {
        holds.contains { $0.key == key }
    }

    static func isModifierDown(_ modifierKey: CGKeyCode) -> Bool {
        holds.contains { hold in hold.modifiers.contains { $0.0 == modifierKey } }
    }

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

    /// Keys another hold already has down are not pressed again — a second press would be
    /// harmless, but the matching release would not: it would cancel the other hold.
    static func press(id: String, key: CGKeyCode?, modifiers: [(CGKeyCode, CGEventFlags)]) {
        release(id: id)
        var flags = currentFlags()
        for (modifierKey, flag) in modifiers {
            let alreadyDown = isModifierDown(modifierKey)
            flags.insert(flag)
            if !alreadyDown {
                postModifier(modifierKey, flags)
            }
        }
        if let key, !isKeyDown(key) {
            post(key, flags, down: true)
        }
        holds.append(Hold(id: id, key: key, modifiers: modifiers))
    }

    static func release(id: String) {
        guard let index = holds.firstIndex(where: { $0.id == id }) else { return }
        let hold = holds.remove(at: index)

        // The key-up carries the flags that were in effect while it was down, including
        // this hold's own modifiers — those come off afterwards.
        var flags = currentFlags()
        for (_, flag) in hold.modifiers {
            flags.insert(flag)
        }
        if let key = hold.key, !isKeyDown(key) {
            post(key, flags, down: false)
        }

        var remaining = hold.modifiers
        while let (modifierKey, _) = remaining.popLast() {
            if isModifierDown(modifierKey) { continue }
            flags = currentFlags()
            for (_, remainingFlag) in remaining {
                flags.insert(remainingFlag)
            }
            postModifier(modifierKey, flags)
        }
    }

    static func releaseAll() {
        for id in holds.map(\.id).reversed() {
            release(id: id)
        }
    }

    /// Tap a combo *without* disturbing any hold — this is what makes a "before release"
    /// hotkey different from an "after release" one. Modifiers already held are reused
    /// rather than re-posted, and a tap of a key that is currently held is skipped: its
    /// key-up would cancel the hold that owns it.
    static func tapOver(_ key: CGKeyCode?, _ modifiers: [(CGKeyCode, CGEventFlags)]) {
        let heldFlags = currentFlags()
        var extra = modifiers.filter { !isModifierDown($0.0) }

        var flags = heldFlags
        for (modifierKey, flag) in extra {
            flags.insert(flag)
            postModifier(modifierKey, flags)
        }

        if let key {
            if isKeyDown(key) {
                FileHandle.standardError.write(
                    Data("keyholder: skipping tap of the key already held\n".utf8))
            } else {
                post(key, flags, down: true)
                post(key, flags, down: false)
            }
        }

        while let (modifierKey, _) = extra.popLast() {
            flags = heldFlags
            for (_, remainingFlag) in extra {
                flags.insert(remainingFlag)
            }
            postModifier(modifierKey, flags)
        }
    }
}

func onSignal(_ signum: Int32) {
    Keyholder.releaseAll()
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

func badCommand(_ line: String) {
    FileHandle.standardError.write(Data("keyholder: bad command: \(line)\n".utf8))
}

while let line = readLine(strippingNewline: true) {
    let parts = line.split(separator: " ")
    guard let verb = parts.first else { continue }

    switch verb {
    case "U":
        guard parts.count == 2 else {
            badCommand(line)
            continue
        }
        Keyholder.release(id: String(parts[1]))

    case "D", "T":
        let isHold = verb == "D"
        guard parts.count == (isHold ? 4 : 3) else {
            badCommand(line)
            continue
        }
        let id = isHold ? String(parts[1]) : ""
        let modField = parts[isHold ? 2 : 1]
        let keyName = String(parts[isHold ? 3 : 2]).lowercased()

        let key = keyName == "-" ? nil : Keyholder.keys[keyName]
        if keyName != "-" && key == nil {
            badCommand(line)
            continue
        }
        var modifiers: [(CGKeyCode, CGEventFlags)] = []
        if modField != "-" {
            for name in modField.split(separator: ",") {
                guard let modifier = Keyholder.modifierKeys[String(name).lowercased()] else { continue }
                modifiers.append(modifier)
            }
        }
        guard key != nil || !modifiers.isEmpty else { continue }

        if isHold {
            Keyholder.press(id: id, key: key, modifiers: modifiers)
        } else {
            Keyholder.tapOver(key, modifiers)
        }

    default:
        continue
    }
}

// stdin closed — Stream Deck killed the plugin. Never leave a key down.
Keyholder.releaseAll()
