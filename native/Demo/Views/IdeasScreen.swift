import SwiftUI

/// The Ideas row at the top of the song list.
struct IdeasRow: View {
    static let route = "__ideas__"
    @Environment(\.library) private var library
    @State private var newIdea = false

    var body: some View {
        ZStack {
            NavigationLink(value: Self.route) { EmptyView() }.opacity(0)
            HStack(spacing: 14) {
                IdeasTile(size: 52)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Ideas").font(.system(size: 17, weight: .semibold))
                    Text(latest.map { $0.text.isEmpty ? "Voice memo · " + SongFiles.time($0.raw["memo"]?["dur"]?.number ?? 0) : $0.text.components(separatedBy: "\n").first ?? "" } ?? "A quick jot for lines, ideas and concepts")
                        .font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(1)
                    Text(library.ideas.isEmpty ? "Tap + to jot one" : "\(library.ideas.count) \(library.ideas.count == 1 ? "idea" : "ideas") · \(ShortDate.string(latest?.updated ?? 0))")
                        .font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 1)
                }
                Spacer(minLength: 8)
                // a new idea straight from the song list
                Button { Haptics.tap(); newIdea = true } label: {
                    Icon("ic-plus", 18).foregroundStyle(Theme.tint)
                        .frame(width: 38, height: 38)
                        .background(BarFill.color, in: Circle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("New idea")
            }
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .sheet(isPresented: $newIdea) { IdeaSheet(idea: nil) }
    }

    private var latest: Idea? { library.ideas.max { $0.updated < $1.updated } }
}


/// Ideas (spec §5): a jot box with voice memos on top, then every idea, newest first.
struct IdeasScreen: View {
    @Environment(\.appSession) private var session
    @Environment(\.library) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var jot = ""
    @State private var query = ""
    @State private var editing: IdeaTarget?
    @State private var recorder = MemoRecorder()
    @FocusState private var jotFocused: Bool

    /// The Idea sheet's subject: an existing idea or a new blank one.
    struct IdeaTarget: Identifiable { let id: String; let idea: Idea? }

    var body: some View {
        List {
            jotBox
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 12, trailing: 16))
            if filtered.isEmpty {
                Text(query.isEmpty ? "Nothing here yet. Type a line and press Return, or tap the mic and hum it." : "No ideas match.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).multilineTextAlignment(.center)
                    .padding(.vertical, 30)
                    .listRowSeparator(.hidden)
            }
            ForEach(filtered) { i in
                // a tap opens it; a swipe (all the way, or to the button) deletes it. Not a Button, so the
                // list's own swipe isn't fighting it.
                IdeaCard(idea: i)
                    .contentShape(Rectangle())
                    .onTapGesture { editing = IdeaTarget(id: i.id, idea: i) }
                    .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { delete(i) } label: { Label("Delete", systemImage: "trash") }
                    }
                    .contextMenu {
                        Button { editing = IdeaTarget(id: i.id, idea: i) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
                        Button(role: .destructive) { delete(i) } label: { Label("Delete Idea", systemImage: "trash") }
                    }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SearchDock(text: $query, prompt: "Search ideas", icon: "ic-plus", label: "New idea") {
                editing = IdeaTarget(id: "new-" + UUID().uuidString, idea: nil)
            }
        }
        .sheet(item: $editing) { t in IdeaSheet(idea: t.idea) }
        .task { await IdeaMemos.uploadPending(library: library, session: session) }
        .onDisappear { stopAndSave() }
        .onChange(of: scenePhase) { _, p in if p != .active { stopAndSave() } }
        .onChange(of: recorder.hitLimit) { _, hit in
            guard hit, let (url, d) = recorder.finished else { return }
            recorder.finished = nil
            let text = jot
            jot = ""
            Task {
                if await IdeaMemos.save(url, dur: d, text: text, library: library, session: session) {
                    session.toast = session.plan.isPro ? "Saved at 10 minutes, the longest a voice memo can be."
                                                       : "Saved at a minute, the longest on Free. Pro memos can run 10 minutes."
                }
            }
        }
        .onChange(of: recorder.notice) { _, n in if let n { session.toast = n; recorder.notice = nil } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { Haptics.tap(); dismiss() } label: {
                Icon("ic-back", 22).foregroundStyle(Theme.tint).frame(width: 48, height: 48).contentShape(Circle())
            }
            .buttonStyle(PressScale())
            .glassCircle()
            .accessibilityLabel("Songs")
            Text("Ideas").font(.system(size: 34, weight: .bold)).tracking(-0.6)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }

    // MARK: the jot box

    @ViewBuilder private var jotBox: some View {
        VStack(spacing: 0) {
            if recorder.isRecording {
                HStack(spacing: 10) {
                    Button("Cancel") { recorder.cancel(); Haptics.tap(); session.toast = "Recording discarded" }
                        .font(.system(size: 15, weight: .medium))
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text(SongFiles.time(recorder.elapsed)).font(.system(size: 15).monospacedDigit())
                    LiveLevels(levels: recorder.levels).frame(height: 30)
                    Button { stopAndSave() } label: {
                        RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: 12, height: 12)
                            .frame(width: 34, height: 34).background(.red, in: Circle())
                    }
                    .buttonStyle(PressScale())
                    .accessibilityLabel("Stop and save")
                }
                .padding(.horizontal, 14).frame(minHeight: 54)
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("A line, a title, an idea…", text: $jot, axis: .vertical)
                        .lineLimit(1...7)
                        .focused($jotFocused)
                        .submitLabel(.done)
                        .onChange(of: jot) { _, v in if v.hasSuffix("\n") { jot = String(v.dropLast()); save() } }
                        .padding(.vertical, 8)
                    Button { record() } label: {
                        Image(systemName: "mic.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.tint)
                            .frame(width: 34, height: 34).background(BarFill.color, in: Circle())
                    }
                    .buttonStyle(PressScale())
                    .accessibilityLabel("Record a voice memo")
                    Button(action: save) {
                        Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.onTint)
                            .frame(width: 34, height: 34).background(Theme.tint, in: Circle())
                    }
                    .buttonStyle(PressScale())
                    .disabled(jot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(jot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.35 : 1)
                    .accessibilityLabel("Save idea")
                }
                .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 6)
            }
        }
        .background(BarFill.color, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(.snappy(duration: 0.25), value: recorder.isRecording)
    }

    private var filtered: [Idea] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return library.ideas.filter { i in
            q.isEmpty || i.text.lowercased().contains(q) || (i.raw["tags"]?.array ?? []).contains { ($0.string ?? "").lowercased().contains(q) }
        }
        .sorted { $0.updated > $1.updated }
    }

    private func save() {
        let t = jot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        Haptics.tap()
        withAnimation(.snappy) { library.putIdea(Idea.new(text: t)) }
        jot = ""
        jotFocused = false
    }

    private func record() {
        if !session.plan.isPro && IdeaMemos.memoCount(library) >= IdeaMemos.freeLimit {
            session.upsell("memos")
            return
        }
        jotFocused = false
        Task {
            do { try await recorder.start(maxSeconds: session.plan.isPro ? 600 : 60) }
            catch MemoRecorder.StartError.denied { session.toast = "Allow microphone access for *[demo] in Settings to record." }
            catch { session.toast = "Recording isn’t available here." }
        }
    }

    /// Stop saves (and so does leaving Ideas or the app).
    private func stopAndSave() {
        guard recorder.isRecording, let (url, d) = recorder.finish() else { return }
        let text = jot
        jot = ""
        Task { await IdeaMemos.save(url, dur: d, text: text, library: library, session: session) }
    }

    private func delete(_ i: Idea) {
        Haptics.thud()
        IdeaMemos.deleteFile(i.memo)
        withAnimation { library.deleteIdea(i.id) }
        session.toast = "Idea deleted"
    }
}

/// The live meter while recording: a bar per 70 ms scrolling left, fading toward the left.
struct LiveLevels: View {
    let levels: [Double]
    var body: some View {
        Canvas { ctx, size in
            let bw: CGFloat = 3, gap: CGFloat = 2.5
            let count = Int(size.width / (bw + gap))
            let shown = levels.suffix(count)
            var x = size.width - bw
            for v in shown.reversed() {
                let h = max(3, size.height * v)
                let a = 0.35 + 0.65 * Double(x / max(1, size.width))
                ctx.fill(Path(roundedRect: CGRect(x: x, y: (size.height - h) / 2, width: bw, height: h), cornerRadius: 1.5),
                         with: .color(.primary.opacity(a)))
                x -= bw + gap
                if x < 0 { break }
            }
        }
    }
}

/// An idea in the list: its text, the memo player, and the date (" · In a song" once a song was started from it).
struct IdeaCard: View {
    let idea: Idea
    @Environment(\.library) private var library
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !idea.text.isEmpty {
                Text(idea.text).font(.system(size: 17)).foregroundStyle(.primary).lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let m = idea.memo { MemoPlayer(ideaID: idea.id, memo: m) }
            Text(ShortDate.string(idea.updated) + (idea.usedSongID.map { library.song($0) != nil } == true ? " · In a song" : ""))
                .font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

/// A memo's play button, waveform (a tick a second while scrubbing) and time.
struct MemoPlayer: View {
    let ideaID: String
    let memo: FileItem
    var large = false
    @Environment(\.appSession) private var session
    private var player: AudioPlayer { AudioPlayer.shared }

    var body: some View {
        let k = AudioPlayer.key(idea: ideaID)
        let active = player.isActive(k)
        let dur = active && player.duration > 0 ? player.duration : memo.dur
        let t = active ? player.time : 0
        HStack(spacing: 10) {
            Button { Haptics.tap(); player.toggle(k, item: memo, fallbackDuration: memo.dur) } label: {
                Image(systemName: active && player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: large ? 16 : 13, weight: .bold)).foregroundStyle(Theme.onTint)
                    .frame(width: large ? 40 : 32, height: large ? 40 : 32).background(Theme.tint, in: Circle())
            }
            .buttonStyle(PressScale())
            .accessibilityLabel(active && player.isPlaying ? "Pause" : "Play")
            Waveform(peaks: memo.peaks, progress: dur > 0 ? t / dur : 0, duration: dur, tickEvery: 1, height: large ? 40 : 30) { f in
                if active { player.seek(f * dur) } else { player.load(k, item: memo, fallbackDuration: memo.dur, autoplay: false, at: f * dur) }
            }
            // in the list a sideways drag is the row's swipe-to-delete, not a scrub (scrub in the idea itself)
            .allowsHitTesting(large)
            Text(active && t > 0 ? "\(SongFiles.time(t)) / \(SongFiles.time(dur))" : SongFiles.time(dur))
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                .fixedSize()
        }
        .onChange(of: player.error) { _, e in if let e, active { session.toast = e; player.error = nil } }
    }
}

/// The Idea sheet (spec §2.6). Saves when it closes.
struct IdeaSheet: View {
    let idea: Idea?
    @Environment(\.appSession) private var session
    @Environment(\.library) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openRoute) private var openRoute
    @State private var text = ""
    @State private var confirmDelete = false
    @State private var gone = false
    @FocusState private var focused: Bool

    private var current: Idea? { idea.flatMap { i in library.ideas.first { $0.id == i.id } } }

    var body: some View {
        NavigationStack {
            Form {
                if let c = current, let m = c.memo {
                    Section {
                        MemoPlayer(ideaID: c.id, memo: m, large: true)
                        Button("Remove", role: .destructive) { removeMemo(c) }
                    }
                }
                Section {
                    TextField(current?.memo != nil ? "Add words to go with it…" : "A line, a title, an idea…", text: $text, axis: .vertical)
                        .lineLimit(4...20)
                        .focused($focused)
                }
                if let c = current {
                    Section {
                        Button { Task { await startSong(c) } } label: {
                            Label { Text("Start a Song").foregroundStyle(.primary) } icon: { TileIcon("sparkles", Theme.Tile.orange) }
                        }
                        Button("Delete Idea", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(idea == nil ? "New Idea" : "Idea")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { DoneButton { dismiss() } } }
            .confirmDestroy("Delete this idea?", isPresented: $confirmDelete, message: "This can’t be undone.", action: "Delete Idea") {
                guard let c = current else { return }
                gone = true
                IdeaMemos.deleteFile(c.memo)
                library.deleteIdea(c.id)
                Haptics.thud(); session.toast = "Idea deleted"
                // after the action sheet has gone, or the sheet won't close
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { dismiss() }
            }
        }
        .belowIslandSheet()
        .onAppear {
            text = idea?.text ?? ""
            library.ideaEditingID = idea?.id
            if idea == nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focused = true } }
        }
        .onDisappear { commit(); library.ideaEditingID = nil }
    }

    /// Empty new ideas are dropped; a memo idea is `line` with words and `memo` without.
    private func commit() {
        guard !gone else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var i = current else {
            if idea == nil && !t.isEmpty { library.putIdea(Idea.new(text: t)) }
            return
        }
        guard i.text != text else { return }
        i.text = text
        if i.memo != nil { i.raw["kind"] = .string(t.isEmpty ? "memo" : "line") }
        i.updated = Clock.nowMs
        library.putIdea(i)
    }

    private func removeMemo(_ c: Idea) {
        Haptics.thud()
        IdeaMemos.deleteFile(c.memo)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            gone = true
            library.deleteIdea(c.id)
            session.toast = "Voice memo deleted"
            dismiss()
        } else {
            var i = c
            i.raw.removeValue(forKey: "memo")
            i.text = text
            i.raw["kind"] = "line"
            i.updated = Clock.nowMs
            library.putIdea(i)
            session.toast = "Recording removed"
        }
    }

    private func startSong(_ c: Idea) async {
        commit()
        guard let latest = library.ideas.first(where: { $0.id == c.id }) else { return }
        let id = await IdeaMemos.startSong(latest, library: library, session: session)
        gone = true
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { openRoute(id) }
    }
}

/// Ideas' icon: a page from Notes (the yellow band, two ruled lines) with a Voice Memos waveform on it.
struct IdeasTile: View {
    var size: CGFloat = 52
    @Environment(\.colorScheme) private var scheme
    private let bars: [CGFloat] = [0.35, 0.7, 1, 0.55, 0.85, 0.45, 0.75, 0.4]
    var body: some View {
        let s = size / 52, shape = RoundedRectangle(cornerRadius: 12 * s, style: .continuous)
        let line = scheme == .dark ? Color(hex: 0x5A5A5E) : Color(hex: 0xD1D1D6)
        ZStack(alignment: .topLeading) {
            shape.fill(scheme == .dark ? Color(hex: 0x2C2C2E) : .white)
            LinearGradient(colors: [Color(hex: 0xFFDA4A), Color(hex: 0xFFC400)], startPoint: .top, endPoint: .bottom)
                .frame(height: 14 * s)
            VStack(alignment: .leading, spacing: 4.5 * s) {
                Capsule().fill(line).frame(width: 34 * s, height: 2.6 * s)
                Capsule().fill(line).frame(width: 22 * s, height: 2.6 * s)
                HStack(alignment: .center, spacing: 2.2 * s) {
                    ForEach(bars.indices, id: \.self) { i in
                        Capsule().fill(Color(hex: 0xFF3B30)).frame(width: 2.4 * s, height: 11 * s * bars[i])
                    }
                }
                .frame(height: 11 * s)
            }
            .padding(.leading, 9 * s).padding(.top, 20 * s)
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(scheme == .dark ? 0.12 : 0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}
