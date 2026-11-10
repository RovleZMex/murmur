import AppKit
import AVFoundation
import SwiftUI

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        // CLI: Murmur --transcribe file.m4a [en-US]
        if let i = args.firstIndex(of: "--transcribe"), i + 1 < args.count {
            let url = URL(fileURLWithPath: args[i + 1])
            let lang = i + 2 < args.count ? args[i + 2] : "en-US"
            setvbuf(stdout, nil, _IONBF, 0)
            Task.detached {
                do {
                    print("Preparing \(lang)…")
                    let loc = try await Transcriber.prepare(locale: Locale(identifier: lang)) {
                        print("Downloading model…")
                    }
                    print("Ready: \(loc.identifier). Transcribing…")
                    for s in try await Transcriber.transcribe(url: url, locale: loc) {
                        print("[\(SessionProcessor.timestamp(s.start))] \(s.text)")
                    }
                    exit(0)
                } catch {
                    print("ERROR: \(error)")
                    exit(1)
                }
            }
            dispatchMain()
        }
        // CLI: re-process a session folder (e.g. if the app quit mid-recording): Murmur --process folder [en-US]
        if let i = args.firstIndex(of: "--process"), i + 1 < args.count {
            let folder = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            let lang = i + 2 < args.count ? args[i + 2] : "en-US"
            setvbuf(stdout, nil, _IONBF, 0)
            Task.detached {
                do {
                    let s = Session(folder: folder, startedAt: Date())
                    let dur = [s.micURL, s.systemURL].compactMap { try? AVAudioFile(forReading: $0) }
                        .map { Double($0.length) / $0.fileFormat.sampleRate }.max() ?? 0
                    let url = try await SessionProcessor.process(s, duration: dur, locale: Locale(identifier: lang)) { print($0) }
                    print("Done: \(url.path)")
                    exit(0)
                } catch {
                    print("ERROR: \(error)")
                    exit(1)
                }
            }
            dispatchMain()
        }
        MurmurApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task { @MainActor in
            await model.finishBeforeQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct MurmurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
                .onAppear { delegate.model = model }
        } label: {
            HStack(spacing: 4) {
                if model.phase == .idle {
                    Image(nsImage: MenuBarIcon.image)
                } else {
                    Image(systemName: model.menuIcon)
                }
                if let text = model.menuText {
                    Text(text).monospacedDigit()
                }
            }
            .onAppear { delegate.model = model }
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Text(model.statusLine)
        if let w = model.warning, model.phase != .recording {
            Text(verbatim: "⚠️ \(w)")
        }

        Divider()

        switch model.phase {
        case .idle:
            Button("Start recording") { model.start() }
                .keyboardShortcut("r", modifiers: [.control, .option, .command])
        case .recording:
            Button("Pause") { model.pause() }
                .keyboardShortcut("p", modifiers: [.control, .option, .command])
            Button("Stop and transcribe") { model.stop() }
                .keyboardShortcut("r", modifiers: [.control, .option, .command])
        case .paused:
            Button("Resume") { model.resume() }
                .keyboardShortcut("p", modifiers: [.control, .option, .command])
            Button("Stop and transcribe") { model.stop() }
                .keyboardShortcut("r", modifiers: [.control, .option, .command])
        case .processing:
            Button("Processing…") {}.disabled(true)
        case .error:
            Button("Start recording") { model.start() }
            Button("Open privacy settings") { AppModel.openPrivacySettings() }
            Button("Dismiss") { model.dismissError() }
        }

        Divider()

        if model.lastTranscript != nil {
            Button("Open last transcript") { model.openLastTranscript() }
        }
        Button("Open recordings folder") { model.openSessionsFolder() }

        Picker("Transcription language", selection: $model.languageID) {
            Text("English").tag("en-US")
            Text("Spanish").tag("es-MX")
        }
        .disabled(model.isBusy)

        Toggle("Open at login", isOn: $model.launchAtLogin)

        Divider()

        Button("Quit Murmur") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
