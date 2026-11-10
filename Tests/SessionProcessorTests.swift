import AVFoundation
import Speech
import Testing
@testable import Murmur

/// A fake transcriber: deterministic segments per track, no speech model needed.
private let fakeTranscribe: SessionProcessor.TranscribeFn = { url, _ in
    url.lastPathComponent.hasPrefix("mic")
        ? [.init(start: 0, text: "Mic first."), .init(start: 4, text: "Mic later.")]
        : [.init(start: 2, text: "System middle.")]
}
private let fakePrepare: SessionProcessor.PrepareFn = { locale, _ in locale }

/// Builds a session folder with the tracks a given capture mode would produce.
private func makeSession(_ mode: Prefs.CaptureMode, in dir: URL) -> Session {
    let s = Session(folder: dir, startedAt: Date(timeIntervalSince1970: 1_800_000_000))
    if mode.includesMic { writeTone(to: s.micURL, seconds: 1, sampleRate: 48_000, channels: 1) }
    if mode.includesSystem { writeTone(to: s.systemURL, seconds: 1) }
    return s
}

@Suite("Session processing — every combination of settings")
struct SessionProcessorTests {
    struct Names: CustomTestStringConvertible, Sendable {
        let me: String, others: String
        var testDescription: String { "\(me)/\(others)" }
    }
    static let names = [Names(me: "Me", others: "Others"), Names(me: "Santiago", others: "Equipo de diseño")]

    @Test("Output files and transcript are right for every capture mode × keep-audio option × speaker names",
          arguments: Prefs.CaptureMode.allCases, Prefs.KeepAudio.allCases)
    func matrix(_ mode: Prefs.CaptureMode, _ keep: Prefs.KeepAudio) async throws {
        for n in Self.names {
            let tmp = TempDir()
            let s = makeSession(mode, in: tmp.url)
            let url = try await SessionProcessor.process(
                s, duration: 61, locale: Locale(identifier: "en-US"),
                myName: n.me, othersName: n.others, keepAudio: keep,
                prepare: fakePrepare, transcribe: fakeTranscribe) { _ in }

            // Transcript
            #expect(url == s.transcriptURL)
            let md = try String(contentsOf: url, encoding: .utf8)
            #expect(md.contains("Duration: 00:01:01"))
            #expect(md.contains("Language: English (United States)"))
            #expect(md.contains("**[00:00:00] \(n.me):**") == mode.includesMic)
            #expect(md.contains("**[00:00:02] \(n.others):**") == mode.includesSystem)
            if mode == .both {
                // Interleaved by time: mic 0s, system 2s, mic 4s
                let order = ["Mic first.", "System middle.", "Mic later."].compactMap { md.range(of: $0)?.lowerBound }
                #expect(order.count == 3 && order == order.sorted())
            }

            // Audio files
            var expected: Set<String> = ["transcript.md"]
            switch keep {
            case .mixed: expected.insert("audio.m4a")
            case .separate:
                if mode.includesMic { expected.insert("mic.m4a") }
                if mode.includesSystem { expected.insert("system.m4a") }
            case .none: break
            }
            #expect(files(in: tmp.url) == expected, "mode=\(mode) keep=\(keep)")
            for f in expected where f.hasSuffix(".m4a") {
                let d = duration(of: tmp.url.appendingPathComponent(f))
                #expect(abs(d - 1.0) < 0.1, "\(f) should be ~1 s, got \(d)")
            }
        }
    }

    @Test("Consecutive sentences from the same speaker are merged into one paragraph")
    func grouping() async throws {
        let tmp = TempDir()
        let s = makeSession(.micOnly, in: tmp.url)
        _ = try await SessionProcessor.process(s, duration: 5, locale: Locale(identifier: "en-US"),
                                               myName: "Me", othersName: "Others", keepAudio: .none,
                                               prepare: fakePrepare, transcribe: fakeTranscribe) { _ in }
        let md = try String(contentsOf: s.transcriptURL, encoding: .utf8)
        #expect(md.contains("**[00:00:00] Me:** Mic first. Mic later."))
    }

    @Test("Silence produces a transcript that says so")
    func noSpeech() async throws {
        let tmp = TempDir()
        let s = makeSession(.both, in: tmp.url)
        _ = try await SessionProcessor.process(s, duration: 1, locale: Locale(identifier: "es-MX"),
                                               keepAudio: .mixed, prepare: fakePrepare,
                                               transcribe: { _, _ in [] }) { _ in }
        let md = try String(contentsOf: s.transcriptURL, encoding: .utf8)
        #expect(md.contains("No speech detected"))
        #expect(md.contains("Language: Spanish (Mexico)"))
    }

    @Test("Progress reports downloading, transcribing and saving in order")
    func progress() async throws {
        let tmp = TempDir()
        let s = makeSession(.both, in: tmp.url)
        let steps = Steps()
        _ = try await SessionProcessor.process(s, duration: 1, locale: Locale(identifier: "en-US"), keepAudio: .mixed,
                                               prepare: { loc, onDownload in onDownload(); return loc },
                                               transcribe: fakeTranscribe) { steps.append($0) }
        #expect(steps.all == [.downloadingModel, .transcribing, .mixing])
    }

    @Test("If transcription fails, the raw audio is kept so nothing is lost", arguments: Prefs.KeepAudio.allCases)
    func failureKeepsAudio(_ keep: Prefs.KeepAudio) async {
        struct Boom: Error {}
        let tmp = TempDir()
        let s = makeSession(.both, in: tmp.url)
        await #expect(throws: Boom.self) {
            try await SessionProcessor.process(s, duration: 1, locale: Locale(identifier: "en-US"), keepAudio: keep,
                                               prepare: fakePrepare, transcribe: { _, _ in throw Boom() }) { _ in }
        }
        #expect(files(in: tmp.url) == ["mic.caf", "system.caf"])
    }

    @Test("Unsupported language fails clearly and keeps the audio")
    func unsupportedLanguage() async {
        let tmp = TempDir()
        let s = makeSession(.both, in: tmp.url)
        await #expect(throws: (any Error).self) {
            try await SessionProcessor.process(s, duration: 1, locale: Locale(identifier: "tlh-Klingon"),
                                               keepAudio: .mixed, transcribe: fakeTranscribe) { _ in }
        }
        #expect(files(in: tmp.url).contains("mic.caf"))
    }
}

private final class Steps: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [SessionProcessor.Step] = []
    func append(_ s: SessionProcessor.Step) { lock.withLock { steps.append(s) } }
    var all: [SessionProcessor.Step] { lock.withLock { steps } }
}

@Suite("Languages")
struct LanguageTests {
    @Test("Every language offered in Settings resolves back to a transcriber locale")
    func everyOfferedLanguageWorks() async throws {
        let offered = await SpeechTranscriber.supportedLocales
        try #require(!offered.isEmpty)
        for loc in offered {
            let id = loc.identifier(.bcp47)   // what the Settings picker stores
            let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id))
            #expect(resolved != nil, "\(id) can't be resolved")
            let name = Locale(identifier: "en_US").localizedString(forIdentifier: id)
            #expect(name?.isEmpty == false, "\(id) has no display name")
        }
    }

    @Test("English and Spanish (the previous menu options) are still supported", arguments: ["en-US", "es-MX"])
    func legacyLanguages(_ id: String) async {
        #expect(await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) != nil)
    }

    @Test("End-to-end: real speech is transcribed with the real engine",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/say")))
    func endToEnd() async throws {
        let installed = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
        try #require(installed.contains("en-US"), "Run the app once with English to download the model")
        let tmp = TempDir()
        let s = Session(folder: tmp.url, startedAt: Date())
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-o", s.micURL.path, "--data-format=LEF32@48000",
                         "Please send me the quarterly report by Friday."]
        try say.run(); say.waitUntilExit()
        _ = try await SessionProcessor.process(s, duration: 3, locale: Locale(identifier: "en-US"),
                                               myName: "Me", othersName: "Others", keepAudio: .mixed) { _ in }
        let md = try String(contentsOf: s.transcriptURL, encoding: .utf8).lowercased()
        #expect(md.contains("quarterly report"))
        #expect(md.contains("**[00:00:00] me:**"))
    }
}
