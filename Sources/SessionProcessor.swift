import AVFoundation

/// Each session lives in its own folder, e.g. ~/Documents/Murmur/2026-11-10 14.30/
struct Session {
    let folder: URL
    let startedAt: Date

    var systemURL: URL { folder.appendingPathComponent("system.caf") }
    var micURL: URL { folder.appendingPathComponent("mic.caf") }
    var audioURL: URL { folder.appendingPathComponent("audio.m4a") }
    var transcriptURL: URL { folder.appendingPathComponent("transcript.md") }

    static var root: URL { Prefs.folder }

    static func create() throws -> Session {
        let now = Date()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        var folder = root.appendingPathComponent(f.string(from: now), isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = root.appendingPathComponent("\(f.string(from: now)) (\(n))", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return Session(folder: folder, startedAt: now)
    }
}

enum SessionProcessor {
    enum Step { case downloadingModel, transcribing, mixing }

    /// Turns one audio file into timestamped segments. Swappable in tests.
    typealias TranscribeFn = (_ url: URL, _ locale: Locale) async throws -> [Transcriber.Segment]
    /// Resolves a locale and downloads its model if needed. Swappable in tests.
    typealias PrepareFn = (_ locale: Locale, _ onDownload: @escaping () -> Void) async throws -> Locale

    /// Transcribes the tracks, writes transcript.md, saves audio per `keepAudio` and deletes the .caf files.
    static func process(_ session: Session, duration: TimeInterval, locale: Locale,
                        myName: String = Prefs.myName, othersName: String = Prefs.othersName,
                        keepAudio: Prefs.KeepAudio = Prefs.keepAudio,
                        prepare: PrepareFn = { try await Transcriber.prepare(locale: $0, onDownload: $1) },
                        transcribe: TranscribeFn = { try await Transcriber.transcribe(url: $0, locale: $1) },
                        progress: @escaping (Step) -> Void) async throws -> URL {
        let fm = FileManager.default
        let tracks: [(label: String, url: URL)] = [(myName, session.micURL), (othersName, session.systemURL)]
            .filter { hasAudio($0.url) }

        let loc = try await prepare(locale) { progress(.downloadingModel) }
        progress(.transcribing)
        var lines: [(start: Double, speaker: String, text: String)] = []
        for track in tracks {
            for seg in try await transcribe(track.url, loc) {
                lines.append((seg.start, track.label, seg.text))
            }
        }
        lines.sort { $0.start < $1.start }

        let md = renderMarkdown(lines: lines, session: session, duration: duration, locale: loc)
        try md.write(to: session.transcriptURL, atomically: true, encoding: .utf8)

        progress(.mixing)
        do {
            switch keepAudio {
            case .mixed:
                try await mix(tracks.map(\.url), to: session.audioURL)
            case .separate:
                for t in tracks {
                    try await mix([t.url], to: t.url.deletingPathExtension().appendingPathExtension("m4a"))
                }
            case .none:
                break
            }
            for t in tracks { try? fm.removeItem(at: t.url) }
        } catch {
            NSLog("Murmur: couldn't save audio, keeping the .caf files: \(error)")
        }
        return session.transcriptURL
    }

    static func hasAudio(_ url: URL) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return size > 8_192
    }

    static func mix(_ urls: [URL], to out: URL) async throws {
        let comp = AVMutableComposition()
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let src = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let dur = try await asset.load(.duration)
            let dst = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try dst?.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: src, at: .zero)
        }
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A) else { return }
        try? FileManager.default.removeItem(at: out)
        try await export.export(to: out, as: .m4a)
    }

    static func renderMarkdown(lines: [(start: Double, speaker: String, text: String)],
                               session: Session, duration: TimeInterval, locale: Locale) -> String {
        let en = Locale(identifier: "en_US")
        let date = session.startedAt.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(en))
        let lang = en.localizedString(forIdentifier: locale.identifier) ?? locale.identifier

        var out = "# Session — \(date)\n\n"
        out += "Duration: \(timestamp(duration)) · Language: \(lang)\n\n---\n\n"
        if lines.isEmpty {
            out += "_No speech detected in this recording._\n"
            return out
        }
        // Group consecutive sentences from the same speaker into one paragraph.
        var current: (start: Double, speaker: String, text: String)?
        func flush() {
            if let c = current { out += "**[\(timestamp(c.start))] \(c.speaker):** \(c.text)\n\n" }
        }
        for line in lines {
            if var c = current, c.speaker == line.speaker, c.text.count < 700 {
                c.text += " " + line.text
                current = c
            } else {
                flush()
                current = line
            }
        }
        flush()
        return out
    }

    static func timestamp(_ t: Double) -> String {
        let s = Int(max(0, t))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
