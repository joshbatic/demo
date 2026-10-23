import SwiftUI

/// The in-song player under the title (spec §4.10): compact row with a thin progress line; tap to open the
/// waveform scrubber with −15 s / +15 s.
struct SongPlayer: View {
    let song: Song
    var onPlayWithLyrics: () -> Void
    @Environment(AppSession.self) private var session
    @AppStorage("np.open") private var open = false
    private var player: AudioPlayer { AudioPlayer.shared }

    var body: some View {
        if let item = song.currentAudio {
            let k = AudioPlayer.key(song: song.id, item: item.id)
            let active = player.isActive(k)
            let dur = active && player.duration > 0 ? player.duration : item.dur
            let t = active ? player.time : 0
            let canPlay = session.plan.isPro || item.isMine(session.userID)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button { play(item, k, canPlay) } label: {
                        ZStack {
                            Circle().fill(Theme.tint)
                            if active && player.isLoading {
                                ProgressView().tint(Theme.onTint)
                            } else {
                                Image(systemName: !canPlay ? "lock.fill" : (active && player.isPlaying ? "pause.fill" : "play.fill"))
                                    .font(.system(size: canPlay ? 15 : 13, weight: .bold))
                                    .foregroundStyle(Theme.onTint)
                                    .offset(x: canPlay && !(active && player.isPlaying) ? 1.5 : 0)
                            }
                        }
                        .frame(width: 38, height: 38)
                    }
                    .buttonStyle(PressScale())
                    .accessibilityLabel(active && player.isPlaying ? "Pause" : "Play")

                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name.isEmpty ? "Recording" : item.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text(subtitle(item, canPlay)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(active && player.isPlaying ? "-" + SongFiles.time(max(0, dur - t)) : SongFiles.time(dur))
                        .font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)

                    Button { Haptics.tap(); onPlayWithLyrics() } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.tint).frame(width: 32, height: 32)
                    }
                    .buttonStyle(PressScale())
                    .accessibilityLabel("Play with Lyrics")
                }
                .padding(10)
                .contentShape(Rectangle())
                .onTapGesture { Haptics.selection(); withAnimation(.snappy(duration: 0.33)) { open.toggle() } }

                if open {
                    VStack(spacing: 6) {
                        Waveform(peaks: item.peaks, progress: dur > 0 ? t / dur : 0, duration: dur, tickEvery: 5, height: 48) { f in
                            guard canPlay else { locked(); return }
                            if active { player.seek(f * dur) } else {
                                player.load(k, item: item, fallbackDuration: item.dur, autoplay: false, at: f * dur)
                            }
                        }
                        HStack {
                            Text(SongFiles.time(t)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                            Spacer()
                            Button { Haptics.tap(); player.skip(-15) } label: { Image(systemName: "gobackward.15").font(.system(size: 20)) }
                                .buttonStyle(PressScale()).accessibilityLabel("Back 15 seconds").disabled(!active)
                            Spacer().frame(width: 28)
                            Button { Haptics.tap(); player.skip(15) } label: { Image(systemName: "goforward.15").font(.system(size: 20)) }
                                .buttonStyle(PressScale()).accessibilityLabel("Forward 15 seconds").disabled(!active)
                            Spacer()
                            Text("-" + SongFiles.time(max(0, dur - t))).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .foregroundStyle(Theme.tint)
                    }
                    .padding(.horizontal, 12).padding(.bottom, 10)
                    .transition(.opacity)
                }

                // the thin progress line
                GeometryReader { g in
                    Capsule().fill(Theme.tint.opacity(0.85))
                        .frame(width: g.size.width * (dur > 0 ? min(1, t / dur) : 0), height: 2)
                }
                .frame(height: 2)
                .opacity(open ? 0 : 1)
            }
            .background(BarFill.color, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .onChange(of: player.error) { _, e in if let e { session.toast = e; player.error = nil } }
        }
    }

    private func subtitle(_ item: FileItem, _ canPlay: Bool) -> String {
        var parts = [item.kind]
        if !canPlay { return "Added by a co-writer · \(item.kind) · Pro" }
        if song.syncAudioID == item.id && !song.syncLines.isEmpty { parts.append("Lyrics synced") }
        return parts.joined(separator: " · ")
    }

    private func play(_ item: FileItem, _ k: String, _ canPlay: Bool) {
        guard canPlay else { locked(); return }
        Haptics.tap()
        player.toggle(k, item: item, fallbackDuration: item.dur)
    }

    private func locked() {
        Haptics.warning()
        session.toast = "A co-writer added this recording. Go Pro to listen and add your own."
    }
}
