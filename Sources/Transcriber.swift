import AVFoundation
import Speech

/// On-device transcription with macOS SpeechAnalyzer/SpeechTranscriber.
enum Transcriber {
    struct Segment {
        let start: Double
        let text: String
    }

    enum TranscriberError: LocalizedError {
        case unsupportedLocale(String)
        var errorDescription: String? {
            switch self {
            case .unsupportedLocale(let id): return "\(id) isn't available for transcription on this Mac."
            }
        }
    }

    /// Resolves the locale and downloads the model if needed (first run only).
    static func prepare(locale: Locale, onDownload: (() -> Void)? = nil) async throws -> Locale {
        guard let loc = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriberError.unsupportedLocale(locale.identifier)
        }
        let probe = SpeechTranscriber(locale: loc, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            onDownload?()
            try await request.downloadAndInstall()
        }
        return loc
    }

    static func transcribe(url: URL, locale: Locale) async throws -> [Segment] {
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        let collector = Task { () throws -> [Segment] in
            var segments: [Segment] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                segments.append(Segment(start: result.range.start.seconds, text: text))
            }
            return segments
        }

        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }
}
