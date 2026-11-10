import AVFoundation
import Foundation
@testable import Murmur

/// A fresh temporary directory, removed when the value is deinitialized.
final class TempDir {
    let url: URL
    init(_ name: String = "murmur-tests") {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

/// An isolated UserDefaults suite installed as `Prefs.store` for the duration of `body`.
func withIsolatedPrefs<T>(_ body: (UserDefaults) throws -> T) rethrows -> T {
    let name = "murmur-tests-\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: name)!
    let previous = Prefs.store
    Prefs.store = suite
    defer {
        Prefs.store = previous
        suite.removePersistentDomain(forName: name)
    }
    return try body(suite)
}

func withIsolatedPrefs<T>(_ body: (UserDefaults) async throws -> T) async rethrows -> T {
    let name = "murmur-tests-\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: name)!
    let previous = Prefs.store
    Prefs.store = suite
    defer {
        Prefs.store = previous
        suite.removePersistentDomain(forName: name)
    }
    return try await body(suite)
}

/// A PCM buffer with a sine tone.
func toneBuffer(seconds: Double, sampleRate: Double = 48_000, channels: AVAudioChannelCount = 2,
                frequency: Double = 440) -> AVAudioPCMBuffer {
    let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
    let frames = AVAudioFrameCount(seconds * sampleRate)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
    buf.frameLength = frames
    for ch in 0..<Int(channels) {
        let p = buf.floatChannelData![ch]
        for i in 0..<Int(frames) { p[i] = Float(0.3 * sin(2 * .pi * frequency * Double(i) / sampleRate)) }
    }
    return buf
}

/// Writes a tone to a .caf, like the recorder does.
@discardableResult
func writeTone(to url: URL, seconds: Double = 1, sampleRate: Double = 48_000, channels: AVAudioChannelCount = 2) -> URL {
    let buf = toneBuffer(seconds: seconds, sampleRate: sampleRate, channels: channels)
    let file = try! AVAudioFile(forWriting: url, settings: buf.format.settings,
                                commonFormat: .pcmFormatFloat32, interleaved: false)
    try! file.write(from: buf)
    return url
}

/// Wraps a PCM buffer in a CMSampleBuffer, the type ScreenCaptureKit delivers.
func sampleBuffer(_ buf: AVAudioPCMBuffer) -> CMSampleBuffer {
    var fd: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: buf.format.streamDescription, layoutSize: 0, layout: nil,
                                   magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(buf.format.sampleRate)),
                                    presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sb: CMSampleBuffer?
    CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                         formatDescription: fd, sampleCount: CMItemCount(buf.frameLength),
                         sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                         sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)
    CMSampleBufferSetDataBufferFromAudioBufferList(sb!, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                   flags: 0, bufferList: buf.audioBufferList)
    return sb!
}

func duration(of url: URL) -> Double {
    guard let f = try? AVAudioFile(forReading: url) else { return 0 }
    return Double(f.length) / f.fileFormat.sampleRate
}

func files(in dir: URL) -> Set<String> {
    Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
}
