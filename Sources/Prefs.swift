import AppKit
import Carbon.HIToolbox

/// User preferences, stored in UserDefaults. Views bind to the same keys with @AppStorage;
/// the rest of the app reads them through these accessors.
enum Prefs {
    enum Key {
        static let micDeviceID = "micDeviceID"
        static let captureMode = "captureMode"
        static let language = "language"
        static let myName = "myName"
        static let othersName = "othersName"
        static let folderPath = "recordingsFolder"
        static let keepAudio = "keepAudio"
        static let afterProcessing = "afterProcessing"
        static let recordShortcut = "shortcut.record"
        static let pauseShortcut = "shortcut.pause"
    }

    enum CaptureMode: String, CaseIterable, Identifiable {
        case both, micOnly, systemOnly
        var id: String { rawValue }
        var title: String {
            switch self {
            case .both: return "Mac audio and microphone"
            case .micOnly: return "Microphone only"
            case .systemOnly: return "Mac audio only"
            }
        }
        var includesMic: Bool { self != .systemOnly }
        var includesSystem: Bool { self != .micOnly }
    }

    enum KeepAudio: String, CaseIterable, Identifiable {
        case mixed, separate, none
        var id: String { rawValue }
        var title: String {
            switch self {
            case .mixed: return "One mixed file (audio.m4a)"
            case .separate: return "Separate tracks (mic.m4a, system.m4a)"
            case .none: return "Don't keep audio, transcript only"
            }
        }
    }

    enum AfterProcessing: String, CaseIterable, Identifiable {
        case openTranscript, notify, nothing
        var id: String { rawValue }
        var title: String {
            switch self {
            case .openTranscript: return "Open the transcript"
            case .notify: return "Show a notification"
            case .nothing: return "Do nothing"
            }
        }
    }

    static let defaultFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Murmur", isDirectory: true)

    /// Backing store; tests swap in an isolated suite.
    nonisolated(unsafe) static var store: UserDefaults = .standard
    private static var d: UserDefaults { store }

    static var micDeviceID: String { d.string(forKey: Key.micDeviceID) ?? "" }
    static var captureMode: CaptureMode { CaptureMode(rawValue: d.string(forKey: Key.captureMode) ?? "") ?? .both }
    static var languageID: String { d.string(forKey: Key.language) ?? "en-US" }
    static var myName: String { nonEmpty(d.string(forKey: Key.myName)) ?? "Me" }
    static var othersName: String { nonEmpty(d.string(forKey: Key.othersName)) ?? "Others" }
    static var keepAudio: KeepAudio { KeepAudio(rawValue: d.string(forKey: Key.keepAudio) ?? "") ?? .mixed }
    static var afterProcessing: AfterProcessing {
        AfterProcessing(rawValue: d.string(forKey: Key.afterProcessing) ?? "") ?? .openTranscript
    }
    static var folder: URL {
        nonEmpty(d.string(forKey: Key.folderPath)).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultFolder
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        return t
    }
}

/// A global keyboard shortcut, stored as "keyCode,carbonModifiers,label". Empty string = disabled.
struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon modifier flags
    var key: String         // printable key, e.g. "R"

    static let defaultRecord = Shortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey | cmdKey), key: "R")
    static let defaultPause = Shortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey | cmdKey), key: "P")

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }

    var stored: String { "\(keyCode),\(modifiers),\(key)" }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.key = key
    }

    init?(stored: String) {
        let parts = stored.split(separator: ",", maxSplits: 2).map(String.init)
        guard parts.count == 3, let k = UInt32(parts[0]), let m = UInt32(parts[1]) else { return nil }
        self.init(keyCode: k, modifiers: m, key: parts[2])
    }

    /// Builds a shortcut from a key event; requires at least one of ⌃ ⌥ ⌘.
    init?(event: NSEvent) {
        let f = event.modifierFlags
        var m: UInt32 = 0
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.command) { m |= UInt32(cmdKey) }
        guard m & UInt32(controlKey | optionKey | cmdKey) != 0,
              let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: m, key: chars.uppercased())
    }

    /// Reads a stored shortcut; a missing key means "use the default", an empty string means "disabled".
    static func load(_ key: String, default def: Shortcut) -> Shortcut? {
        guard let raw = Prefs.store.string(forKey: key) else { return def }
        return raw.isEmpty ? nil : Shortcut(stored: raw)
    }
}
