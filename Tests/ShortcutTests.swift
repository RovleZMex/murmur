import AppKit
import Carbon.HIToolbox
import Testing
@testable import Murmur

@Suite("Keyboard shortcuts")
struct ShortcutTests {
    static let ctrl = UInt32(controlKey), opt = UInt32(optionKey), shift = UInt32(shiftKey), cmd = UInt32(cmdKey)

    /// All 16 combinations of ⌃ ⌥ ⇧ ⌘.
    static let allModifierCombos: [UInt32] = (0..<16).map { bits in
        (bits & 1 != 0 ? ctrl : 0) | (bits & 2 != 0 ? opt : 0) | (bits & 4 != 0 ? shift : 0) | (bits & 8 != 0 ? cmd : 0)
    }

    @Test("Defaults are ⌃⌥⌘R and ⌃⌥⌘P")
    func defaults() {
        #expect(Shortcut.defaultRecord.display == "⌃⌥⌘R")
        #expect(Shortcut.defaultPause.display == "⌃⌥⌘P")
        #expect(Shortcut.defaultRecord != Shortcut.defaultPause)
    }

    @Test("Any modifier combination survives being stored", arguments: allModifierCombos)
    func roundTrip(_ mods: UInt32) {
        for (code, key) in [(kVK_ANSI_R, "R"), (kVK_F5, "F5"), (kVK_ANSI_Comma, ","), (kVK_Space, " ")] {
            let s = Shortcut(keyCode: UInt32(code), modifiers: mods, key: key)
            #expect(Shortcut(stored: s.stored) == s)
        }
    }

    @Test("Display uses macOS symbol order ⌃⌥⇧⌘", arguments: allModifierCombos)
    func displayOrder(_ mods: UInt32) {
        let d = Shortcut(keyCode: 0, modifiers: mods, key: "A").display
        let symbols = d.dropLast()
        let expected = [("⌃", Self.ctrl), ("⌥", Self.opt), ("⇧", Self.shift), ("⌘", Self.cmd)]
            .filter { mods & $0.1 != 0 }.map(\.0).joined()
        #expect(String(symbols) == expected)
        #expect(d.hasSuffix("A"))
    }

    @Test("Malformed stored values are rejected", arguments: ["", "R", "15", "15,", "x,1,R", "15,y,R"])
    func malformed(_ raw: String) {
        #expect(Shortcut(stored: raw) == nil)
    }

    // MARK: Recording a shortcut from a key press

    static func keyEvent(_ chars: String, code: Int, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: UInt16(code))!
    }

    @Test("Key presses with ⌃, ⌥ or ⌘ become shortcuts", arguments: [
        NSEvent.ModifierFlags.command, [.control], [.option], [.command, .shift], [.control, .option, .command],
        [.control, .option, .shift, .command],
    ])
    func validPress(_ flags: NSEvent.ModifierFlags) throws {
        let s = try #require(Shortcut(event: Self.keyEvent("k", code: kVK_ANSI_K, flags)))
        #expect(s.key == "K")
        #expect(s.keyCode == UInt32(kVK_ANSI_K))
        #expect((s.modifiers & Self.cmd != 0) == flags.contains(.command))
        #expect((s.modifiers & Self.ctrl != 0) == flags.contains(.control))
        #expect((s.modifiers & Self.opt != 0) == flags.contains(.option))
        #expect((s.modifiers & Self.shift != 0) == flags.contains(.shift))
    }

    @Test("Plain keys or Shift alone are rejected (they'd hijack typing)",
          arguments: [NSEvent.ModifierFlags(), [.shift], [.capsLock], [.shift, .capsLock]])
    func invalidPress(_ flags: NSEvent.ModifierFlags) {
        #expect(Shortcut(event: Self.keyEvent("k", code: kVK_ANSI_K, flags)) == nil)
    }
}

@Suite("Global hotkey registration", .serialized)
struct HotKeyRegistrationTests {
    // Unusual combos so the tests don't collide with a running copy of Murmur.
    static let combos: [Shortcut] = [
        Shortcut(keyCode: UInt32(kVK_F13), modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey), key: "F13"),
        Shortcut(keyCode: UInt32(kVK_F14), modifiers: UInt32(controlKey | shiftKey), key: "F14"),
        Shortcut(keyCode: UInt32(kVK_F15), modifiers: UInt32(optionKey), key: "F15"),
    ]

    @Test("Any shortcut can be registered, unregistered and re-registered", arguments: combos)
    func registerCycle(_ s: Shortcut) {
        let hk = HotKeys()
        #expect(hk.register(s) {})
        #expect(hk.count == 1)
        hk.unregisterAll()
        #expect(hk.count == 0)
        #expect(hk.register(s) {}, "Re-registering after unregisterAll must work (settings changes)")
        hk.unregisterAll()
    }

    @Test("Record and pause shortcuts register together")
    func both() {
        let hk = HotKeys()
        #expect(hk.register(Self.combos[0]) {})
        #expect(hk.register(Self.combos[1]) {})
        #expect(hk.count == 2)
        hk.unregisterAll()
    }
}
