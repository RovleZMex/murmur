import AppKit
import AVFoundation
import SwiftUI
import UserNotifications

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

    private let recorder = Recorder()
    private var session: Session?
    private var timer: Timer?
    private var segmentStart: Date?
    private var accumulated: TimeInterval = 0
    private var processingTask: Task<Void, Never>?
    private var micGranted = true
    private var mode: Prefs.CaptureMode = .both
    private var hotKeySignature = ""
    private var defaultsObserver: NSObjectProtocol?

    private let hotKeys = HotKeys()

    init() {
        registerHotKeys()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.registerHotKeys() }
        }
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

    // MARK: Actions

    func start() {
        guard phase == .idle || isError else { return }
        Task {
            mode = Prefs.captureMode
            micGranted = mode.includesMic ? await AVCaptureDevice.requestAccess(for: .audio) : false
            if mode == .micOnly && !micGranted {
                phase = .error("Microphone permission is missing")
                return
            }
            var created: Session?
            do {
                let s = try Session.create()
                created = s
                try await recorder.start(systemURL: s.systemURL, micURL: s.micURL,
                                         includeMic: micGranted, includeSystem: mode.includesSystem,
                                         micDeviceID: Prefs.micDeviceID)
                session = s
                warning = (mode.includesMic && !micGranted) ? "no microphone (permission denied)" : nil
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
        let locale = Locale(identifier: Prefs.languageID)
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
                switch Prefs.afterProcessing {
                case .openTranscript: NSWorkspace.shared.open(url)
                case .notify: await Self.notifyReady(url, duration: duration)
                case .nothing: break
                }
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

    // MARK: Hotkeys

    private func registerHotKeys() {
        let rec = Shortcut.load(Prefs.Key.recordShortcut, default: .defaultRecord)
        let pause = Shortcut.load(Prefs.Key.pauseShortcut, default: .defaultPause)
        let signature = "\(rec?.stored ?? "-")|\(pause?.stored ?? "-")"
        guard signature != hotKeySignature else { return }
        hotKeySignature = signature
        hotKeys.unregisterAll()
        if let rec { hotKeys.register(rec) { [weak self] in self?.toggleRecording() } }
        if let pause { hotKeys.register(pause) { [weak self] in self?.togglePause() } }
    }

    var recordShortcut: Shortcut? { Shortcut.load(Prefs.Key.recordShortcut, default: .defaultRecord) }
    var pauseShortcut: Shortcut? { Shortcut.load(Prefs.Key.pauseShortcut, default: .defaultPause) }

    // MARK: Notifications

    private static func notifyReady(_ url: URL, duration: TimeInterval) async {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = "Transcript ready"
        content.body = "\(url.deletingLastPathComponent().lastPathComponent) · \(clock(duration))"
        content.userInfo = ["url": url.path]
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
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

    // MARK: Private

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
                    } else if self.micGranted && self.mode.includesMic && st.mic == 0 {
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
