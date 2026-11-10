import Foundation
import Testing
@testable import Murmur

/// Everything that reads `Prefs.store` lives in this one serialized suite, so tests never race on it.
@Suite("Preferences", .serialized)
struct PrefsTests {

    // MARK: Defaults

    @Test("Every setting has a sensible default when nothing is stored")
    func defaults() {
        withIsolatedPrefs { _ in
            #expect(Prefs.micDeviceID == "")
            #expect(Prefs.captureMode == .both)
            #expect(Prefs.languageID == "en-US")
            #expect(Prefs.myName == "Me")
            #expect(Prefs.othersName == "Others")
            #expect(Prefs.keepAudio == .mixed)
            #expect(Prefs.afterProcessing == .openTranscript)
            #expect(Prefs.folder == Prefs.defaultFolder)
            #expect(Prefs.folder.path.hasSuffix("Documents/Murmur"))
            #expect(Shortcut.load(Prefs.Key.recordShortcut, default: .defaultRecord) == .defaultRecord)
            #expect(Shortcut.load(Prefs.Key.pauseShortcut, default: .defaultPause) == .defaultPause)
        }
    }

    // MARK: Each value of each option round-trips

    @Test("Capture mode round-trips", arguments: Prefs.CaptureMode.allCases)
    func captureMode(_ mode: Prefs.CaptureMode) {
        withIsolatedPrefs { d in
            d.set(mode.rawValue, forKey: Prefs.Key.captureMode)
            #expect(Prefs.captureMode == mode)
        }
    }

    @Test("Keep-audio option round-trips", arguments: Prefs.KeepAudio.allCases)
    func keepAudio(_ value: Prefs.KeepAudio) {
        withIsolatedPrefs { d in
            d.set(value.rawValue, forKey: Prefs.Key.keepAudio)
            #expect(Prefs.keepAudio == value)
        }
    }

    @Test("After-processing option round-trips", arguments: Prefs.AfterProcessing.allCases)
    func afterProcessing(_ value: Prefs.AfterProcessing) {
        withIsolatedPrefs { d in
            d.set(value.rawValue, forKey: Prefs.Key.afterProcessing)
            #expect(Prefs.afterProcessing == value)
        }
    }

    @Test("Unknown stored values fall back to defaults",
          arguments: ["", "garbage", "BOTH", "Mixed", "0"])
    func corruptValues(_ raw: String) {
        withIsolatedPrefs { d in
            d.set(raw, forKey: Prefs.Key.captureMode)
            d.set(raw, forKey: Prefs.Key.keepAudio)
            d.set(raw, forKey: Prefs.Key.afterProcessing)
            #expect(Prefs.captureMode == .both)
            #expect(Prefs.keepAudio == .mixed)
            #expect(Prefs.afterProcessing == .openTranscript)
        }
    }

    @Test("Every option has a user-facing title", arguments: [
        Prefs.CaptureMode.allCases.map(\.title),
        Prefs.KeepAudio.allCases.map(\.title),
        Prefs.AfterProcessing.allCases.map(\.title),
    ])
    func titles(_ titles: [String]) {
        #expect(titles.allSatisfy { !$0.isEmpty })
        #expect(Set(titles).count == titles.count)
    }

    // MARK: Speaker names

    @Test("Blank speaker names fall back to Me / Others", arguments: ["", " ", "   \t"])
    func blankNames(_ name: String) {
        withIsolatedPrefs { d in
            d.set(name, forKey: Prefs.Key.myName)
            d.set(name, forKey: Prefs.Key.othersName)
            #expect(Prefs.myName == "Me")
            #expect(Prefs.othersName == "Others")
        }
    }

    @Test("Custom speaker names are trimmed and kept",
          arguments: [("Santiago", "Santiago"), ("  Ana  ", "Ana"), ("José Ñúñez", "José Ñúñez"), ("Team 🚀", "Team 🚀")])
    func customNames(_ input: String, _ expected: String) {
        withIsolatedPrefs { d in
            d.set(input, forKey: Prefs.Key.myName)
            d.set(input, forKey: Prefs.Key.othersName)
            #expect(Prefs.myName == expected)
            #expect(Prefs.othersName == expected)
        }
    }

    // MARK: Language and microphone

    @Test("Any language ID is stored as-is", arguments: ["en-US", "es-MX", "fr-FR", "ja-JP", "pt-BR"])
    func language(_ id: String) {
        withIsolatedPrefs { d in
            d.set(id, forKey: Prefs.Key.language)
            #expect(Prefs.languageID == id)
        }
    }

    @Test("Microphone ID is stored as-is", arguments: ["", "BuiltInMicrophoneDevice", "AppleUSBAudioEngine:XYZ"])
    func microphone(_ id: String) {
        withIsolatedPrefs { d in
            d.set(id, forKey: Prefs.Key.micDeviceID)
            #expect(Prefs.micDeviceID == id)
        }
    }

    // MARK: Recordings folder

    @Test("Custom folder is used; empty means the default")
    func folder() {
        withIsolatedPrefs { d in
            d.set("/tmp/Some Folder/Murmur", forKey: Prefs.Key.folderPath)
            #expect(Prefs.folder.path == "/tmp/Some Folder/Murmur")
            #expect(Session.root == Prefs.folder)
            d.set("", forKey: Prefs.Key.folderPath)
            #expect(Prefs.folder == Prefs.defaultFolder)
        }
    }

    @Test("Sessions are created inside the chosen folder, even if it doesn't exist yet",
          arguments: ["Recordings", "Mis grabaciones/Reuniones", "iCloud Drive ☁️/Notas de reunión"])
    func sessionInCustomFolder(_ sub: String) throws {
        let tmp = TempDir()
        let root = tmp.url.appendingPathComponent(sub, isDirectory: true)
        try withIsolatedPrefs { d in
            d.set(root.path, forKey: Prefs.Key.folderPath)
            let s = try Session.create()
            #expect(s.folder.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
            #expect(FileManager.default.fileExists(atPath: s.folder.path))
            #expect(!s.folder.lastPathComponent.contains(":"))
        }
    }

    @Test("Two sessions in the same minute get distinct folders")
    func sessionCollision() throws {
        let tmp = TempDir()
        try withIsolatedPrefs { d in
            d.set(tmp.url.path, forKey: Prefs.Key.folderPath)
            let a = try Session.create()
            let b = try Session.create()
            let c = try Session.create()
            #expect(Set([a.folder, b.folder, c.folder]).count == 3)
        }
    }

    @Test("An unwritable folder fails with an error instead of crashing")
    func unwritableFolder() {
        withIsolatedPrefs { d in
            d.set("/System/Murmur-should-not-exist", forKey: Prefs.Key.folderPath)
            #expect(throws: (any Error).self) { try Session.create() }
        }
    }

    // MARK: Stored shortcuts

    @Test("Stored shortcut: missing = default, empty = disabled, valid = custom, garbage = disabled")
    func storedShortcuts() {
        withIsolatedPrefs { d in
            let key = Prefs.Key.recordShortcut
            #expect(Shortcut.load(key, default: .defaultRecord) == .defaultRecord)
            d.set("", forKey: key)
            #expect(Shortcut.load(key, default: .defaultRecord) == nil)
            let custom = Shortcut(keyCode: 1, modifiers: 256, key: "S")
            d.set(custom.stored, forKey: key)
            #expect(Shortcut.load(key, default: .defaultRecord) == custom)
            d.set("not,a-shortcut", forKey: key)
            #expect(Shortcut.load(key, default: .defaultRecord) == nil)
        }
    }
}
