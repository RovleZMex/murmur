import AppKit
import AVFoundation
import ServiceManagement
import Speech
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            RecordingSettings().tabItem { Label("Recording", systemImage: "mic") }
            TranscriptionSettings().tabItem { Label("Transcription", systemImage: "text.quote") }
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: General

private struct GeneralSettings: View {
    @AppStorage(Prefs.Key.folderPath) private var folderPath = ""
    @AppStorage(Prefs.Key.keepAudio) private var keepAudio = Prefs.KeepAudio.mixed.rawValue
    @AppStorage(Prefs.Key.afterProcessing) private var afterProcessing = Prefs.AfterProcessing.openTranscript.rawValue
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var folder: URL { folderPath.isEmpty ? Prefs.defaultFolder : URL(fileURLWithPath: folderPath) }

    var body: some View {
        Form {
            Section {
                LabeledContent("Save recordings in") {
                    HStack {
                        Label(folder.lastPathComponent, systemImage: "folder")
                            .help(folder.path)
                            .lineLimit(1)
                        Spacer()
                        Button("Choose…", action: chooseFolder)
                    }
                }
                if !folderPath.isEmpty {
                    LabeledContent("") {
                        Button("Reset to Documents/Murmur") { folderPath = "" }
                            .buttonStyle(.link)
                    }
                }
                Picker("Keep audio", selection: $keepAudio) {
                    ForEach(Prefs.KeepAudio.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }
            Section {
                Picker("When a transcript is ready", selection: $afterProcessing) {
                    ForEach(Prefs.AfterProcessing.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Open Murmur at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            NSLog("Murmur: couldn't change open-at-login: \(error)")
                        }
                    }
            }
            Section("Keyboard shortcuts") {
                LabeledContent("Start / stop recording") {
                    ShortcutRecorder(storageKey: Prefs.Key.recordShortcut, defaultValue: .defaultRecord)
                }
                LabeledContent("Pause / resume") {
                    ShortcutRecorder(storageKey: Prefs.Key.pauseShortcut, defaultValue: .defaultPause)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Choose"
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { folderPath = url.path }
    }
}

// MARK: Recording

private struct RecordingSettings: View {
    @AppStorage(Prefs.Key.captureMode) private var captureMode = Prefs.CaptureMode.both.rawValue
    @AppStorage(Prefs.Key.micDeviceID) private var micDeviceID = ""
    @State private var mics: [AVCaptureDevice] = []

    var body: some View {
        Form {
            Section {
                Picker("Record", selection: $captureMode) {
                    ForEach(Prefs.CaptureMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.radioGroup)
                Picker("Microphone", selection: $micDeviceID) {
                    Text("System default").tag("")
                    if !mics.isEmpty { Divider() }
                    ForEach(mics, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                    if !micDeviceID.isEmpty && !mics.contains(where: { $0.uniqueID == micDeviceID }) {
                        Text("Disconnected device").tag(micDeviceID)
                    }
                }
                .disabled(captureMode == Prefs.CaptureMode.systemOnly.rawValue)
            } footer: {
                Text("Changes apply to the next recording. Use headphones to avoid the microphone picking up your Mac's audio.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadMics)
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in loadMics() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in loadMics() }
    }

    private func loadMics() {
        mics = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                                mediaType: .audio, position: .unspecified).devices
    }
}

// MARK: Transcription

private struct TranscriptionSettings: View {
    @AppStorage(Prefs.Key.language) private var language = "en-US"
    @AppStorage(Prefs.Key.myName) private var myName = ""
    @AppStorage(Prefs.Key.othersName) private var othersName = ""
    @State private var locales: [(id: String, name: String)] = []

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $language) {
                    if locales.isEmpty { Text(name(for: language)).tag(language) }
                    ForEach(locales, id: \.id) { Text($0.name).tag($0.id) }
                }
            } footer: {
                Text("Transcription runs on your Mac. The first time you use a language, macOS downloads its speech model.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            Section("Speaker labels") {
                TextField("Your microphone", text: $myName, prompt: Text("Me"))
                TextField("Mac audio", text: $othersName, prompt: Text("Others"))
            }
        }
        .formStyle(.grouped)
        .task {
            let all = await SpeechTranscriber.supportedLocales
            locales = all.map { ($0.identifier(.bcp47), name(for: $0.identifier(.bcp47))) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            if !locales.contains(where: { $0.id == language }),
               let match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) {
                language = match.identifier(.bcp47)
            }
        }
    }

    private func name(for id: String) -> String {
        Locale(identifier: "en_US").localizedString(forIdentifier: id) ?? id
    }
}

// MARK: Shortcut recorder

/// Click to record a new shortcut. Esc cancels, Delete disables it.
struct ShortcutRecorder: View {
    let storageKey: String
    let defaultValue: Shortcut
    @AppStorage private var stored: String
    @State private var recording = false
    @State private var monitor: Any?

    init(storageKey: String, defaultValue: Shortcut) {
        self.storageKey = storageKey
        self.defaultValue = defaultValue
        _stored = AppStorage(wrappedValue: defaultValue.stored, storageKey)
    }

    private var current: Shortcut? { stored.isEmpty ? nil : Shortcut(stored: stored) }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                Text(recording ? "Press keys…" : (current?.display ?? "None"))
                    .monospaced()
                    .frame(minWidth: 90)
            }
            .help("Click, then press a key combination with ⌃, ⌥ or ⌘. Esc cancels, Delete clears.")
            if current != defaultValue {
                Button {
                    stored = defaultValue.stored
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("Reset to \(defaultValue.display)")
            }
        }
        .onDisappear(perform: stop)
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case 53: stop()                                      // Esc
            case 51, 117: stored = ""; stop()                    // Delete / Forward delete
            default:
                if let s = Shortcut(event: event) { stored = s.stored; stop() } else { NSSound.beep() }
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
