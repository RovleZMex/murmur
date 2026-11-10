import AVFoundation
import ScreenCaptureKit

/// Records system audio and the microphone with a single SCStream.
/// Each source is written incrementally to its own .caf, aligned to the same
/// session timeline (gaps are padded with silence).
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    enum RecorderError: LocalizedError {
        case noDisplay
        var errorDescription: String? { "No display found to capture audio from." }
    }

    var onStreamError: ((Error) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "murmur.audio")

    // Estado accedido solo desde `queue`.
    private var systemTrack: TrackWriter?
    private var micTrack: TrackWriter?
    private var t0: CMTime?
    private var pausedTotal: CMTime = .zero
    private var pauseStart: CMTime?

    func start(systemURL: URL, micURL: URL, includeMic: Bool) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw RecorderError.noDisplay }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2
        cfg.captureMicrophone = includeMic
        if includeMic, let mic = AVCaptureDevice.default(for: .audio) {
            cfg.microphoneCaptureDeviceID = mic.uniqueID
        }
        // Minimal video: we only care about audio.
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        queue.sync {
            systemTrack = TrackWriter(url: systemURL)
            micTrack = includeMic ? TrackWriter(url: micURL) : nil
            pausedTotal = .zero
            pauseStart = nil
            t0 = CMClockGetTime(CMClockGetHostTimeClock())
        }

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        if includeMic { try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        try await s.startCapture()
        stream = s
    }

    func pause() {
        queue.async { if self.pauseStart == nil { self.pauseStart = CMClockGetTime(CMClockGetHostTimeClock()) } }
    }

    func resume() {
        queue.async {
            guard let p = self.pauseStart else { return }
            self.pausedTotal = self.pausedTotal + (CMClockGetTime(CMClockGetHostTimeClock()) - p)
            self.pauseStart = nil
        }
    }

    struct Stats { var system: AVAudioFramePosition = 0; var mic: AVAudioFramePosition = 0 }

    /// Frames actually captured so far (to detect that no audio is arriving).
    func stats() -> Stats {
        queue.sync { Stats(system: systemTrack?.framesWritten ?? 0, mic: micTrack?.framesWritten ?? 0) }
    }

    @discardableResult
    func stop() async -> Stats {
        if let s = stream { try? await s.stopCapture() }
        stream = nil
        return queue.sync {
            let st = Stats(system: systemTrack?.framesWritten ?? 0, mic: micTrack?.framesWritten ?? 0)
            systemTrack?.close()
            micTrack?.close()
            systemTrack = nil
            micTrack = nil
            t0 = nil
            return st
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type != .screen, sb.isValid, let t0, pauseStart == nil else { return }
        let track = (type == .audio) ? systemTrack : micTrack
        let seconds = (sb.presentationTimeStamp - t0 - pausedTotal).seconds
        track?.append(sb, sessionSeconds: seconds)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStreamError?(error)
    }
}

/// Writes one audio track to disk, padding gaps with silence so the file
/// position matches session time.
final class TrackWriter {
    let url: URL
    private var file: AVAudioFile?
    private var skew: Double?

    init(url: URL) { self.url = url }

    private(set) var framesWritten: AVAudioFramePosition = 0
    private var warned = Set<String>()

    private func warn(_ key: String, _ msg: @autoclosure () -> String) {
        if warned.insert(key).inserted { NSLog("Murmur [\(url.lastPathComponent)]: \(msg())") }
    }

    private static func compatible(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.sampleRate == b.sampleRate && a.channelCount == b.channelCount
            && a.isInterleaved == b.isInterleaved && a.commonFormat == b.commonFormat
    }

    func append(_ sb: CMSampleBuffer, sessionSeconds raw: Double) {
        guard let fd = sb.formatDescription else { return warn("nofd", "buffer without format") }
        let srcFmt = AVAudioFormat(cmAudioFormatDescription: fd)
        let frames = AVAudioFrameCount(sb.numSamples)
        guard frames > 0 else { return }

        // Guard in case the buffer clock is not the host clock.
        if skew == nil { skew = abs(raw) > 10 ? raw : 0 }
        let seconds = max(0, raw - (skew ?? 0))

        do {
            if file == nil {
                file = try AVAudioFile(forWriting: url, settings: srcFmt.settings,
                                       commonFormat: srcFmt.commonFormat, interleaved: srcFmt.isInterleaved)
                NSLog("Murmur [\(url.lastPathComponent)]: format \(srcFmt)")
            }
            guard let file else { return }
            let fmt = file.processingFormat
            guard Self.compatible(fmt, srcFmt) else {
                return warn("fmt", "format changed mid-stream (\(srcFmt)), dropping buffers")
            }
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else {
                return warn("buf", "couldn't create buffer")
            }
            buf.frameLength = frames
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sb, at: 0, frameCount: Int32(frames), into: buf.mutableAudioBufferList)
            guard status == noErr else { return warn("copy", "error copying audio: \(status)") }

            let expected = AVAudioFramePosition(seconds * fmt.sampleRate)
            let gap = expected - file.length
            if gap > AVAudioFramePosition(fmt.sampleRate * 0.2) {
                try writeSilence(frames: gap, to: file)
            }
            try file.write(from: buf)
            framesWritten += AVAudioFramePosition(frames)
        } catch {
            warn("write", "error writing audio: \(error)")
        }
    }

    private func writeSilence(frames total: AVAudioFramePosition, to file: AVAudioFile) throws {
        let chunk: AVAudioFrameCount = 48_000
        guard let silence = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return }
        silence.frameLength = chunk
        let abl = UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList)
        for b in abl { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
        var remaining = total
        while remaining > 0 {
            let n = AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining))
            silence.frameLength = n
            try file.write(from: silence)
            remaining -= AVAudioFramePosition(n)
        }
    }

    func close() { file = nil }
}
