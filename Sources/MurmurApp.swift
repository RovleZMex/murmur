import AppKit
import Carbon.HIToolbox
import AVFoundation
import SwiftUI
import UserNotifications

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

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var model: AppModel?
    var openSettings: (() -> Void)?

    /// Opening Murmur again while it's running (Finder, Spotlight) shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.activate()
        openSettings?()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Clicking "Transcript ready" opens the transcript.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let path = response.notification.request.content.userInfo["url"] as? String {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }

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
    @Environment(\.openSettings) private var openSettings

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
            .onAppear {
                delegate.model = model
                delegate.openSettings = { openSettings() }
            }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(model.statusLine)
        if let w = model.warning, model.phase != .recording {
            Text(verbatim: "⚠️ \(w)")
        }

        Divider()

        switch model.phase {
        case .idle:
            Button("Start recording") { model.start() }
                .globalShortcut(model.recordShortcut)
        case .recording:
            Button("Pause") { model.pause() }
                .globalShortcut(model.pauseShortcut)
            Button("Stop and transcribe") { model.stop() }
                .globalShortcut(model.recordShortcut)
        case .paused:
            Button("Resume") { model.resume() }
                .globalShortcut(model.pauseShortcut)
            Button("Stop and transcribe") { model.stop() }
                .globalShortcut(model.recordShortcut)
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

        Divider()

        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")

        Button("Quit Murmur") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

private extension View {
    /// Shows the (global) shortcut next to a menu item, if it maps to a SwiftUI key equivalent.
    @ViewBuilder func globalShortcut(_ shortcut: Shortcut?) -> some View {
        if let shortcut, shortcut.key.count == 1, let ch = shortcut.key.lowercased().first {
            self.keyboardShortcut(KeyEquivalent(ch), modifiers: shortcut.swiftUIModifiers)
        } else {
            self
        }
    }
}

private extension Shortcut {
    var swiftUIModifiers: SwiftUI.EventModifiers {
        var m: SwiftUI.EventModifiers = []
        if modifiers & UInt32(controlKey) != 0 { m.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { m.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { m.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { m.insert(.command) }
        return m
    }
}
