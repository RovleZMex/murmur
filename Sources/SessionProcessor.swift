import AVFoundation

/// Each session lives in its own folder: ~/Documents/Murmur/2026-11-10 14.30/
struct Session {
    let folder: URL
    let startedAt: Date

    var systemURL: URL { folder.appendingPathComponent("system.caf") }
    var micURL: URL { folder.appendingPathComponent("mic.caf") }
    var audioURL: URL { folder.appendingPathComponent("audio.m4a") }
    var transcriptURL: URL { folder.appendingPathComponent("transcript.md") }

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur", isDirectory: true)
    }

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

    /// Transcribes both tracks, writes transcript.md, mixes audio.m4a and deletes the .caf files.
    static func process(_ session: Session, duration: TimeInterval, locale: Locale,
                        progress: @escaping (Step) -> Void) async throws -> URL {
        let fm = FileManager.default
        let tracks: [(label: String, url: URL)] = [("Me", session.micURL), ("Others", session.systemURL)]
            .filter { hasAudio($0.url) }

        let loc = try await Transcriber.prepare(locale: locale) { progress(.downloadingModel) }
        progress(.transcribing)
        var lines: [(start: Double, speaker: String, text: String)] = []
        for track in tracks {
            for seg in try await Transcriber.transcribe(url: track.url, locale: loc) {
                lines.append((seg.start, track.label, seg.text))
            }
        }
        lines.sort { $0.start < $1.start }

        let md = renderMarkdown(lines: lines, session: session, duration: duration, locale: loc)
        try md.write(to: session.transcriptURL, atomically: true, encoding: .utf8)

        progress(.mixing)
        do {
            try await mix(tracks.map(\.url), to: session.audioURL)
            for t in tracks { try? fm.removeItem(at: t.url) }
        } catch {
            NSLog("Murmur: couldn't mix audio, keeping the .caf files: \(error)")
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
