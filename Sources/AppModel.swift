import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        case paused
        case processing(String)
        case error(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastTranscript: URL?
    @Published private(set) var warning: String?
    @Published var languageID: String = UserDefaults.standard.string(forKey: "language") ?? "en-US" {
        didSet { UserDefaults.standard.set(languageID, forKey: "language") }
    }
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet { setLaunchAtLogin(launchAtLogin) }
    }

    private let recorder = Recorder()
    private var session: Session?
    private var timer: Timer?
    private var segmentStart: Date?
    private var accumulated: TimeInterval = 0
    private var processingTask: Task<Void, Never>?
    private var micGranted = true

    private let hotKeys = HotKeys()

    init() {
        hotKeys.register(keyCode: 15 /* R */) { [weak self] in self?.toggleRecording() }
        hotKeys.register(keyCode: 35 /* P */) { [weak self] in self?.togglePause() }
        recorder.onStreamError = { [weak self] error in
            Task { @MainActor in self?.streamFailed(error) }
        }
    }

    // MARK: Menu bar

    var menuIcon: String {
        switch phase {
        case .idle: return "waveform"
        case .recording: return "record.circle.fill"
        case .paused: return "pause.circle"
        case .processing: return "hourglass"
        case .error: return "exclamationmark.triangle"
        }
    }

    var menuText: String? {
        switch phase {
        case .recording, .paused: return Self.clock(elapsed)
        default: return nil
        }
    }

    var statusLine: String {
        switch phase {
        case .idle: return "Ready to record"
        case .recording: return "Recording · \(Self.clock(elapsed))" + (warning.map { " · ⚠️ \($0)" } ?? "")
        case .paused: return "Paused · \(Self.clock(elapsed))"
        case .processing(let what): return what
        case .error(let msg): return msg
        }
    }

    // MARK: Acciones

    func start() {
        guard phase == .idle || isError else { return }
        Task {
            micGranted = await AVCaptureDevice.requestAccess(for: .audio)
            var created: Session?
            do {
                let s = try Session.create()
                created = s
                try await recorder.start(systemURL: s.systemURL, micURL: s.micURL, includeMic: micGranted)
                session = s
                warning = micGranted ? nil : "no microphone (permission denied)"
                accumulated = 0
                elapsed = 0
                segmentStart = Date()
                phase = .recording
                startTimer()
            } catch {
                if let c = created { try? FileManager.default.removeItem(at: c.folder) }
                phase = .error(Self.describe(error))
            }
        }
    }

    func toggleRecording() {
        switch phase {
        case .idle, .error: start()
        case .recording, .paused: stop()
        case .processing: break
        }
    }

    func togglePause() {
        if phase == .recording { pause() } else if phase == .paused { resume() }
    }

    func pause() {
        guard phase == .recording else { return }
        recorder.pause()
        accumulated += Date().timeIntervalSince(segmentStart ?? Date())
        segmentStart = nil
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        recorder.resume()
        segmentStart = Date()
        phase = .recording
    }

    func stop() {
        guard phase == .recording || phase == .paused, let s = session else { return }
        if let start = segmentStart { accumulated += Date().timeIntervalSince(start) }
        segmentStart = nil
        stopTimer()
        let duration = accumulated
        let locale = Locale(identifier: languageID)
        phase = .processing("Saving audio…")
        processingTask = Task {
            defer { session = nil; processingTask = nil }
            let stats = await recorder.stop()
            if stats.system == 0 && stats.mic == 0 {
                try? FileManager.default.removeItem(at: s.folder)
                phase = .error("No audio was captured. Check permissions and reopen Murmur.")
                return
            }
            do {
                let url = try await SessionProcessor.process(s, duration: duration, locale: locale) { step in
                    Task { @MainActor in
                        switch step {
                        case .downloadingModel: self.phase = .processing("Downloading language model…")
                        case .transcribing: self.phase = .processing("Transcribing…")
                        case .mixing: self.phase = .processing("Saving audio…")
                        }
                    }
                }
                lastTranscript = url
                phase = .idle
                warning = nil
                NSWorkspace.shared.open(url)
            } catch {
                phase = .error("Transcription failed: \(error.localizedDescription). The audio was kept in the folder.")
            }
        }
    }

    /// On quit: if recording, stop and process before exiting.
    func finishBeforeQuit() async {
        if phase == .recording || phase == .paused { stop() }
        await processingTask?.value
    }

    func openSessionsFolder() {
        try? FileManager.default.createDirectory(at: Session.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Session.root)
    }

    func openLastTranscript() {
        if let url = lastTranscript { NSWorkspace.shared.open(url) }
    }

    func dismissError() { if isError { phase = .idle } }

    var isError: Bool { if case .error = phase { return true } else { return false } }
    var isBusy: Bool { if case .processing = phase { return true } else { return false } }

    // MARK: Privado

    private func streamFailed(_ error: Error) {
        guard phase == .recording || phase == .paused else { return }
        NSLog("Murmur: capture stopped: \(error)")
        stop() // process whatever was recorded
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let running = self.segmentStart.map { Date().timeIntervalSince($0) } ?? 0
                self.elapsed = self.accumulated + running
                if self.phase == .recording, self.elapsed >= 5, self.elapsed < 7 {
                    let st = self.recorder.stats()
                    if st.system == 0 && st.mic == 0 {
                        self.warning = "no audio coming in, check permissions"
                    } else if self.micGranted && st.mic == 0 {
                        self.warning = "the microphone isn't sending audio"
                    }
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Murmur: couldn't change open-at-login: \(error)")
        }
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" || ns.code == -3801 {
            return "Screen & System Audio Recording permission is missing"
        }
        return error.localizedDescription
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
