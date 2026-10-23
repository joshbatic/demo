import SwiftUI

/// Play with Lyrics (spec §2.11): the lyrics full screen, following the song. Closing keeps the audio playing
/// in the in-song player, like Apple Music's lyrics view.
struct PlayWithLyrics: View {
    let songID: String
    @Environment(LibraryStore.self) private var library
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var userScrolledAt = Date.distantPast
    @State private var scrub: Double?
    private var player: AudioPlayer { AudioPlayer.shared }

    private struct Line: Identifiable { let id: Int; let text: String; let t: Double? }

    var body: some View {
        let song = library.song(songID)
        let item = song?.currentAudio
        let k = item.map { AudioPlayer.key(song: songID, item: $0.id) } ?? ""
        let active = player.isActive(k)
        let dur = active && player.duration > 0 ? player.duration : (item?.dur ?? 0)
        let now = active ? player.time : 0
        let rows = lineRows(song)
        let synced = rows.contains { $0.t != nil }
        let current = synced ? rows.lastIndex { ($0.t ?? .infinity) <= now + 0.25 } : nil

        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(song?.displayTitle ?? "").font(.system(size: 20, weight: .bold)).lineLimit(1)
                    Text([song?.artist ?? "", item.map { "\($0.name) (\($0.kind))" } ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { Haptics.tap(); dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.tint)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(PressScale())
                .glassCircle()
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let note = note(song, synced) {
                            Text(note).font(.footnote).foregroundStyle(.secondary).padding(.bottom, 4)
                        }
                        ForEach(rows) { l in
                            let on = l.id == current
                            let past = current.map { l.id < $0 } ?? false
                            Text(l.text)
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(on ? Color.primary : Color.primary.opacity(past ? 0.35 : (synced ? 0.5 : 0.9)))
                                .scaleEffect(on ? 1.0 : 0.97, anchor: .leading)
                                .animation(.smooth(duration: 0.35), value: on)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    guard let t = l.t, let item else { return }
                                    Haptics.tap()
                                    if active { player.seek(t); player.play() } else { player.load(k, item: item, fallbackDuration: item.dur, autoplay: true, at: t) }
                                }
                                .id(l.id)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 40)
                }
                .scrollIndicators(.hidden)
                .simultaneousGesture(DragGesture().onChanged { _ in userScrolledAt = Date() })
                .onChange(of: current) { _, c in
                    guard let c, Date().timeIntervalSince(userScrolledAt) > 3 else { return }
                    withAnimation(.smooth(duration: 0.5)) { proxy.scrollTo(c, anchor: UnitPoint(x: 0, y: 0.32)) }
                }
            }

            VStack(spacing: 10) {
                Slider(value: Binding(get: { scrub ?? now }, set: { scrub = $0 }), in: 0...max(1, dur)) { editing in
                    if !editing, let s = scrub {
                        if active { player.seek(s) } else if let item { player.load(k, item: item, fallbackDuration: item.dur, autoplay: false, at: s) }
                        scrub = nil
                    }
                }
                .tint(Theme.tint)
                HStack {
                    Text(SongFiles.time(scrub ?? now)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Text(SongFiles.time(dur)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack(spacing: 44) {
                    Button { Haptics.tap(); player.skip(-10) } label: { Image(systemName: "gobackward.10").font(.system(size: 26)) }
                        .accessibilityLabel("Back 10 seconds")
                    Button {
                        guard let item else { return }
                        Haptics.tap(); player.toggle(k, item: item, fallbackDuration: item.dur)
                    } label: {
                        Image(systemName: active && player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 40))
                            .frame(width: 64, height: 64)
                    }
                    .accessibilityLabel(active && player.isPlaying ? "Pause" : "Play")
                    Button { Haptics.tap(); player.skip(10) } label: { Image(systemName: "goforward.10").font(.system(size: 26)) }
                        .accessibilityLabel("Forward 10 seconds")
                }
                .buttonStyle(PressScale())
                .foregroundStyle(Theme.tint)
            }
            .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 10)
            .background { EdgeFade(edge: .bottom, solidTo: 0.6) }
        }
        .background(Color(uiColor: .systemBackground))
    }

    private func lineRows(_ s: Song?) -> [Line] {
        guard let s else { return [] }
        let sync = s.syncAudioID == s.currentAudio?.id ? s.syncLines : []
        if !sync.isEmpty { return sync.enumerated().map { Line(id: $0.offset, text: $0.element.text, t: $0.element.t) } }
        return s.syncableLines.enumerated().map { Line(id: $0.offset, text: $0.element, t: nil) }
    }

    private func note(_ s: Song?, _ synced: Bool) -> String? {
        guard let s else { return nil }
        if !synced { return "Not synced yet. Tap Sync Lyrics in Details › Audio." }
        if s.syncIsStale { return "Lyrics changed since syncing. Showing the synced version." }
        return nil
    }
}
