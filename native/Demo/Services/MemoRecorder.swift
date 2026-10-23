import Foundation
import AVFoundation
import Observation

/// Records an idea voice memo (spec §5): AAC .m4a at 128 kbps, with the voice processing off so singing
/// comes through as it is. Publishes a scrolling level meter: a new bar every 70 ms.
@MainActor @Observable
final class MemoRecorder {
    private(set) var isRecording = false
    private(set) var elapsed: Double = 0
    /// Levels 0…1, oldest first; the newest is at the right edge.
    private(set) var levels: [Double] = []
    /// Set when recording stops on its own (the time limit), so the screen can save and explain.
    private(set) var hitLimit = false
    var notice: String?

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var smooth: Double = 0
    @ObservationIgnored private var loudest: Double = 0
    @ObservationIgnored private var warnedSilent = false
    @ObservationIgnored private(set) var maxSeconds: Double = 60
    @ObservationIgnored private(set) var fileURL: URL?
    /// The recording that stopped at the time limit, waiting to be saved.
    @ObservationIgnored var finished: (URL, Double)?

    enum StartError: Error { case denied, unavailable }

    func start(maxSeconds: Double) async throws {
        guard !isRecording else { return }
        let ok = await AVAudioApplication.requestRecordPermission()
        guard ok else { throw StartError.denied }
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try s.setActive(true)
        } catch { throw StartError.unavailable }
        AudioPlayer.shared.pause()
        let url = FileManager.default.temporaryDirectory.appending(path: "memo-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100,
                                       AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000]
        guard let r = try? AVAudioRecorder(url: url, settings: settings) else { throw StartError.unavailable }
        r.isMeteringEnabled = true
        guard r.record() else { throw StartError.unavailable }
        recorder = r
        fileURL = url
        self.maxSeconds = maxSeconds
        isRecording = true
        hitLimit = false
        elapsed = 0
        levels = []
        smooth = 0; loudest = 0; warnedSilent = false
        Haptics.thud()
        timer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let r = recorder, isRecording else { return }
        r.updateMeters()
        let db = Double(r.peakPower(forChannel: 0))
        let target = min(1, max(0, (db + 50) / 44))   // the web's dB scale
        smooth += (target - smooth) * (target > smooth ? 0.6 : 0.25)
        loudest = max(loudest, smooth)
        levels.append(smooth)
        if levels.count > 160 { levels.removeFirst(levels.count - 160) }
        elapsed = r.currentTime
        if !warnedSilent && elapsed > 3.5 && loudest < 0.04 {
            warnedSilent = true
            notice = "No sound is coming in. Check your microphone."
        }
        if elapsed >= maxSeconds {
            finished = finish()
            hitLimit = true
        }
    }

    /// Stops and returns the recording (and its length), or nil if nothing was recorded.
    func finish() -> (URL, Double)? {
        guard let r = recorder else { return nil }
        let d = r.currentTime
        r.stop()
        cleanup()
        guard let u = fileURL else { return nil }
        return (u, d)
    }

    func cancel() {
        recorder?.stop()
        recorder?.deleteRecording()
        cleanup()
        fileURL = nil
    }

    private func cleanup() {
        timer?.invalidate(); timer = nil
        recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    }
}
