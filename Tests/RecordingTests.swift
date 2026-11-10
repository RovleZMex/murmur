import AVFoundation
import Testing
@testable import Murmur

@Suite("Capture configuration")
struct CaptureConfigurationTests {
    static var micIDs: [String] {
        ["", "definitely-not-a-real-device"] + [AVCaptureDevice.default(for: .audio)?.uniqueID].compactMap { $0 }
    }

    @Test("Capture mode decides which sources are recorded", arguments: Prefs.CaptureMode.allCases, micIDs)
    func modeAndMic(_ mode: Prefs.CaptureMode, _ micID: String) {
        let cfg = Recorder.configuration(includeMic: mode.includesMic, includeSystem: mode.includesSystem, micDeviceID: micID)
        #expect(cfg.capturesAudio == mode.includesSystem)
        #expect(cfg.captureMicrophone == mode.includesMic)
        #expect(cfg.excludesCurrentProcessAudio)
        #expect(cfg.sampleRate == 48_000)
        if mode.includesMic, let fallback = AVCaptureDevice.default(for: .audio) {
            // A real ID is used as-is; empty or unknown IDs fall back to the system default.
            let expected = AVCaptureDevice(uniqueID: micID)?.uniqueID ?? fallback.uniqueID
            #expect(cfg.microphoneCaptureDeviceID == expected)
        }
        if !mode.includesMic {
            #expect(cfg.microphoneCaptureDeviceID == nil)
        }
    }

    @Test("Every mode records at least one source", arguments: Prefs.CaptureMode.allCases)
    func neverEmpty(_ mode: Prefs.CaptureMode) {
        #expect(mode.includesMic || mode.includesSystem)
    }

    @Test("A disconnected microphone falls back to the default instead of failing")
    func disconnectedMic() {
        #expect(Recorder.resolveMicrophone("unplugged-usb-mic")?.uniqueID == AVCaptureDevice.default(for: .audio)?.uniqueID)
        #expect(Recorder.resolveMicrophone("")?.uniqueID == AVCaptureDevice.default(for: .audio)?.uniqueID)
    }
}

@Suite("Track writer")
struct TrackWriterTests {
    /// Microphones deliver all sorts of formats; every one must be written correctly.
    @Test("Writes any microphone format", arguments: [(48_000.0, 2), (48_000, 1), (44_100, 1), (44_100, 2), (16_000, 1), (96_000, 2)])
    func formats(_ rate: Double, _ channels: Int) {
        let tmp = TempDir()
        let w = TrackWriter(url: tmp.url.appendingPathComponent("t.caf"))
        let buf = toneBuffer(seconds: 0.5, sampleRate: rate, channels: AVAudioChannelCount(channels))
        w.append(sampleBuffer(buf), sessionSeconds: 0)
        w.append(sampleBuffer(buf), sessionSeconds: 0.5)
        #expect(w.framesWritten == AVAudioFramePosition(buf.frameLength) * 2)
        w.close()
        #expect(abs(duration(of: w.url) - 1.0) < 0.01)
    }

    @Test("Gaps (late start, pause, dropped buffers) are padded with silence to stay aligned",
          arguments: [0.5, 2.0, 10.0])
    func padding(_ gap: Double) {
        let tmp = TempDir()
        let w = TrackWriter(url: tmp.url.appendingPathComponent("t.caf"))
        let buf = toneBuffer(seconds: 0.25)
        w.append(sampleBuffer(buf), sessionSeconds: gap)
        w.close()
        #expect(abs(duration(of: w.url) - (gap + 0.25)) < 0.02)
    }

    @Test("Small timing jitter is not padded")
    func jitter() {
        let tmp = TempDir()
        let w = TrackWriter(url: tmp.url.appendingPathComponent("t.caf"))
        let buf = toneBuffer(seconds: 0.5)
        w.append(sampleBuffer(buf), sessionSeconds: 0)
        w.append(sampleBuffer(buf), sessionSeconds: 0.6)   // 0.1 s late: within tolerance
        w.close()
        #expect(abs(duration(of: w.url) - 1.0) < 0.01)
    }

    @Test("Switching microphones mid-recording doesn't corrupt the file")
    func formatChange() {
        let tmp = TempDir()
        let w = TrackWriter(url: tmp.url.appendingPathComponent("t.caf"))
        w.append(sampleBuffer(toneBuffer(seconds: 0.5, sampleRate: 48_000, channels: 2)), sessionSeconds: 0)
        w.append(sampleBuffer(toneBuffer(seconds: 0.5, sampleRate: 16_000, channels: 1)), sessionSeconds: 0.5)
        w.close()
        #expect(abs(duration(of: w.url) - 0.5) < 0.01)
        #expect((try? AVAudioFile(forReading: w.url)) != nil)
    }

    @Test("A track that never received audio writes no file")
    func emptyTrack() {
        let tmp = TempDir()
        let w = TrackWriter(url: tmp.url.appendingPathComponent("t.caf"))
        w.close()
        #expect(w.framesWritten == 0)
        #expect(!FileManager.default.fileExists(atPath: w.url.path))
    }
}
