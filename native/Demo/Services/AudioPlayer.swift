import Foundation
import AVFoundation
import Observation

/// The one audio player (spec §4.10): the song's current version, previews in Details › Audio,
/// Play with Lyrics and idea memos all go through it, so only one thing plays at a time.
@MainActor @Observable
final class AudioPlayer {
    static let shared = AudioPlayer()

    /// What's loaded: "<songID>/<itemID>" for song audio, "idea/<ideaID>" for a memo.
    private(set) var key: String?
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var time: Double = 0
    private(set) var duration: Double = 0
    var error: String?

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var loadToken = 0

    static func key(song: String, item: String) -> String { song + "/" + item }
    static func key(idea: String) -> String { "idea/" + idea }

    func isActive(_ k: String) -> Bool { key == k }

    /// Plays or pauses `item`; a different item replaces what's loaded.
    func toggle(_ k: String, item: FileItem, fallbackDuration: Double = 0) {
        if key == k, let p = player {
            if isPlaying { p.pause(); isPlaying = false } else { activate(); p.play(); isPlaying = true }
            return
        }
        load(k, item: item, fallbackDuration: fallbackDuration, autoplay: true, at: 0)
    }

    /// Loads without playing (so a seek on an idle waveform works), or plays from `at`.
    func load(_ k: String, item: FileItem, fallbackDuration: Double = 0, autoplay: Bool, at: Double) {
        stop()
        key = k
        duration = item.dur > 0 ? item.dur : fallbackDuration
        time = at
        isLoading = true
        loadToken += 1
        let token = loadToken
        Task {
            do {
                let url = try await SongFiles.playableURL(item)
                guard token == loadToken else { return }
                let p = AVPlayer(url: url)
                p.automaticallyWaitsToMinimizeStalling = !url.isFileURL
                player = p
                observe(p)
                if at > 0 { await p.seek(to: CMTime(seconds: at, preferredTimescale: 600)) }
                isLoading = false
                if autoplay { activate(); p.play(); isPlaying = true }
                if let d = try? await p.currentItem?.asset.load(.duration), CMTimeGetSeconds(d).isFinite, CMTimeGetSeconds(d) > 0 {
                    duration = CMTimeGetSeconds(d)
                }
            } catch {
                guard token == loadToken else { return }
                isLoading = false
                key = nil
                self.error = "Couldn’t play it: " + SongFiles.message(error)
            }
        }
    }

    func play() { guard let p = player else { return }; activate(); p.play(); isPlaying = true }
    func pause() { player?.pause(); isPlaying = false }

    func seek(_ t: Double) {
        let c = max(0, min(duration > 0 ? duration : t, t))
        time = c
        player?.seek(to: CMTime(seconds: c, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(_ dt: Double) { seek(time + dt) }

    /// Stops and unloads.
    func stop() {
        if let o = timeObserver { player?.removeTimeObserver(o) }
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        timeObserver = nil; endObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
        isLoading = false
        key = nil
        time = 0
    }

    /// Pauses only if what's playing belongs to that song (leaving or switching songs).
    func pause(ifSong songID: String) {
        if let k = key, k.hasPrefix(songID + "/") { pause() }
    }

    private func observe(_ p: AVPlayer) {
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                let s = CMTimeGetSeconds(t)
                if s.isFinite { self.time = s }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = false
                self.time = 0
                self.player?.seek(to: .zero)
            }
        }
    }

    private func activate() {
        let s = AVAudioSession.sharedInstance()
        if s.category != .playback && s.category != .playAndRecord {
            try? s.setCategory(.playback, mode: .default)
        }
        try? s.setActive(true)
    }
}
