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


/// Ideas (spec §5): like Notes, one rounded list per day, newest first. Search, record and + float at the
/// bottom. Matches the web's renderIdeas.
struct IdeasScreen: View {
    @Environment(\.appSession) private var session
    @Environment(\.library) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openRoute) private var openRoute
    @State private var query = ""
    @State private var editing: IdeaTarget?
    @State private var recorder = MemoRecorder()

    /// The Idea sheet's subject: an existing idea or a new blank one.
    struct IdeaTarget: Identifiable { let id: String; let idea: Idea? }

    var body: some View {
        List {
            if !subtitle.isEmpty {
                Text(subtitle).font(.system(size: 15)).foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            }
            if filtered.isEmpty {
                Text(query.isEmpty ? "Nothing here yet. Tap + to jot a line, or the mic to hum one." : "No ideas match “\(query)”.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).multilineTextAlignment(.center)
                    .padding(.vertical, 40)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            ForEach(groups) { g in
                Section {
                    ForEach(g.ideas) { i in
                        // a tap opens it; a swipe deletes it. Not a Button, so the list's own swipe isn't fighting it.
                        IdeaCard(idea: i)
                            .contentShape(Rectangle())
                            .onTapGesture { editing = IdeaTarget(id: i.id, idea: i) }
                            .listRowInsets(EdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 14))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { delete(i) } label: { Label("Delete", systemImage: "trash") }.tint(.red)
                            }
                            .contextMenu {
                                Button { Task { await startSong(i) } } label: { Label("Start a Song", systemImage: "music.note") }
                                if !i.text.isEmpty { Button { UIPasteboard.general.string = i.text } label: { Label("Copy", systemImage: "doc.on.doc") } }
                                Button(role: .destructive) { delete(i) } label: { Label("Delete Idea", systemImage: "trash") }
                            }
                    }
                } header: {
                    Text(g.id).font(.system(size: 20, weight: .bold)).foregroundStyle(.primary).textCase(nil)
                        .padding(.leading, -8)
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(6)
        .scrollDismissesKeyboard(.interactively)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) {
                if recorder.isRecording { recordingPanel.transition(.move(edge: .bottom).combined(with: .opacity)) }
                SearchDock(text: $query, prompt: "Search ideas", icon: "ic-plus", label: "New idea",
                           side: .init(symbol: recorder.isRecording ? "stop.fill" : "mic.fill", label: recorder.isRecording ? "Stop and save" : "Record a voice memo") {
                               if recorder.isRecording { stopAndSave() } else { record() }
                           }) {
                    editing = IdeaTarget(id: "new-" + UUID().uuidString, idea: nil)
                }
            }
            .animation(.snappy(duration: 0.25), value: recorder.isRecording)
        }
        .sheet(item: $editing) { t in IdeaSheet(idea: t.idea) }
        .task { await IdeaMemos.uploadPending(library: library, session: session) }
        .onDisappear { stopAndSave() }
        .onChange(of: scenePhase) { _, p in if p != .active { stopAndSave() } }
        .onChange(of: recorder.hitLimit) { _, hit in
            guard hit, let (url, d) = recorder.finished else { return }
            recorder.finished = nil
            Task {
                if await IdeaMemos.save(url, dur: d, text: "", library: library, session: session) {
                    session.toast = session.plan.isPro ? "Saved at 10 minutes, the longest a voice memo can be."
                                                       : "Saved at a minute, the longest on Free. Pro memos can run 10 minutes."
                }
            }
        }
        .onChange(of: recorder.notice) { _, n in if let n { session.toast = n; recorder.notice = nil } }
        // opened from the app icon's menu or a widget: start recording, or open a new idea
        .onChange(of: session.ideasStart, initial: true) { _, a in
            guard let a else { return }
            session.ideasStart = nil
            Task {
                try? await Task.sleep(for: .milliseconds(350))   // let the push animation land first
                if a == "record" { if !recorder.isRecording { record() } } else { editing = IdeaTarget(id: "new-" + UUID().uuidString, idea: nil) }
            }
        }
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
        .padding(.bottom, 10)
    }

    private var subtitle: String {
        let memos = library.ideas.filter { $0.memo != nil }.count, n = library.ideas.count - memos
        return [n > 0 ? "\(n) \(n == 1 ? "idea" : "ideas")" : "", memos > 0 ? "\(memos) \(memos == 1 ? "memo" : "memos")" : ""]
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// Ideas grouped by day like Notes: Today, Yesterday, Previous 7 Days, Previous 30 Days, then months and years.
    struct DayGroup: Identifiable { let id: String; var ideas: [Idea] }
    private var groups: [DayGroup] {
        var out: [DayGroup] = []
        for i in filtered {
            let g = query.isEmpty ? IdeaLook.group(i.updated) : "\(filtered.count) \(filtered.count == 1 ? "Match" : "Matches")"
            if out.last?.id == g { out[out.count - 1].ideas.append(i) } else { out.append(DayGroup(id: g, ideas: [i])) }
        }
        return out
    }

    private var recordingPanel: some View {
        HStack(spacing: 10) {
            Button("Cancel") { recorder.cancel(); Haptics.tap() }
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
        .glass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 14)
    }

    private var filtered: [Idea] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return library.ideas.filter { i in
            q.isEmpty || i.text.lowercased().contains(q) || (i.raw["tags"]?.array ?? []).contains { ($0.string ?? "").lowercased().contains(q) }
        }
        .sorted { $0.updated > $1.updated }
    }

    private func startSong(_ i: Idea) async {
        Haptics.tap()
        let id = await IdeaMemos.startSong(i, library: library, session: session)
        openRoute(id)
    }

    private func record() {
        if !session.plan.isPro && IdeaMemos.memoCount(library) >= IdeaMemos.freeLimit {
            session.upsell("memos")
            return
        }
        Haptics.tap()
        Task {
            do { try await recorder.start(maxSeconds: session.plan.isPro ? 600 : 60) }
            catch MemoRecorder.StartError.denied { session.toast = "Allow microphone access for *[demo] in Settings to record." }
            catch { session.toast = "Recording isn’t available here." }
        }
    }

    /// Stop saves (and so does leaving Ideas or the app).
    private func stopAndSave() {
        guard recorder.isRecording, let (url, d) = recorder.finish() else { return }
        Haptics.success()
        Task { await IdeaMemos.save(url, dur: d, text: "", library: library, session: session) }
    }

    private func delete(_ i: Idea) {
        Haptics.thud()
        IdeaMemos.deleteFile(i.memo)
        withAnimation { library.deleteIdea(i.id) }
    }
}

/// The helpers the web's Ideas uses: kind names, day groups and related ideas.
enum IdeaLook {
    static func kind(_ i: Idea) -> String {
        if i.memo != nil && i.text.isEmpty { return "memo" }
        return ["line", "title", "idea", "concept"].contains(i.kind) ? i.kind : "line"
    }
    static func name(_ k: String) -> String { ["line": "Line", "title": "Title", "idea": "Idea", "concept": "Concept", "memo": "Memo"][k] ?? "Line" }
    static func symbol(_ k: String) -> String { ["line": "text.alignleft", "title": "textformat", "idea": "textformat", "concept": "lightbulb", "memo": "waveform"][k] ?? "text.alignleft" }
    static func created(_ i: Idea) -> Double { i.raw["created"]?.number ?? i.updated }

    /// The web's ideaGroup.
    static func group(_ t: Double) -> String {
        let cal = Calendar.current, d = Date(timeIntervalSince1970: t / 1000)
        let n = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day ?? 0
        if n <= 0 { return "Today" }
        if n == 1 { return "Yesterday" }
        if n < 7 { return "Previous 7 Days" }
        if n < 30 { return "Previous 30 Days" }
        let f = DateFormatter()
        f.dateFormat = cal.component(.year, from: d) == cal.component(.year, from: Date()) ? "LLLL" : "yyyy"
        return f.string(from: d)
    }

    private static let stop: Set<String> = Set("that this with from your have what when they them were there their then than just like into been will would could about over only some more back down here also because before after where while which these those cant dont wont youre ever even still every never always".split(separator: " ").map(String.init))
    static func words(_ t: String) -> [String: String] {
        var o: [String: String] = [:]
        let clean = t.lowercased().replacingOccurrences(of: "’", with: "").replacingOccurrences(of: "'", with: "")
        for w in clean.split(whereSeparator: { !($0 >= "a" && $0 <= "z") }).map(String.init) where w.count >= 4 && !stop.contains(w) {
            var k = w
            if k.hasSuffix("ing") { k.removeLast(3) } else if k.hasSuffix("s") { k.removeLast() }
            o[k] = w
        }
        return o
    }
    /// Shared tags count most, then shared words, then the same day; up to three, each saying why.
    struct Related: Identifiable { let idea: Idea; let why: String; var id: String { idea.id } }
    static func related(_ i: Idea, in ideas: [Idea]) -> [Related] {
        let mw = words(i.text), mt = (i.raw["tags"]?.array ?? []).compactMap(\.string)
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: created(i) / 1000))
        var out: [(Idea, Int, String)] = []
        for x in ideas where x.id != i.id {
            var sc = 0, why = ""
            let t = (x.raw["tags"]?.array ?? []).compactMap(\.string).filter { mt.contains($0) }
            if let f = t.first { sc += 3 * t.count; why = "Shares #\(f)" }
            let xw = words(x.text), sh = xw.keys.filter { mw[$0] != nil }.sorted()
            if let f = sh.first { sc += 2 * sh.count; if why.isEmpty { why = "Both mention “\(xw[f] ?? f)”" } }
            if Calendar.current.startOfDay(for: Date(timeIntervalSince1970: created(x) / 1000)) == day {
                sc += 1; if why.isEmpty { why = x.memo != nil && x.text.isEmpty ? "Recorded the same day" : "Written the same day" }
            }
            if sc > 0 { out.append((x, sc, why)) }
        }
        return out.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.updated > $1.0.updated }.prefix(3).map { Related(idea: $0.0, why: $0.2) }
    }
}

/// An idea in the list, like a note in Notes: one bold line (cut short if long), then when it was and a grey
/// preview (the rest of its words, the song it went into, its kind, a memo's length or its tags). A memo has a
/// play button. Matches the web's ideaRow.
struct IdeaCard: View {
    let idea: Idea
    @Environment(\.library) private var library
    private var player: AudioPlayer { AudioPlayer.shared }

    var body: some View {
        let t = idea.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = t.components(separatedBy: "\n")
        let first = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(first.isEmpty ? "Voice memo" : first)
                    .font(.system(size: 17, weight: .semibold)).lineLimit(1)
                (Text(when).foregroundColor(.primary.opacity(0.85)) + Text("  " + preview(lines)).foregroundColor(.secondary))
                    .font(.system(size: 15)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let m = idea.memo {
                let k = AudioPlayer.key(idea: idea.id), on = player.isActive(k) && player.isPlaying
                Button { Haptics.tap(); player.toggle(k, item: m, fallbackDuration: m.dur) } label: {
                    Image(systemName: on ? "pause.fill" : "play.fill").font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .frame(width: 32, height: 32).background(Color.primary, in: Circle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(on ? "Pause voice memo" : "Play voice memo")
            }
        }
    }

    /// The time today and yesterday, the weekday this week, else the date (the web's ideaWhen).
    private var when: String {
        let g = IdeaLook.group(idea.updated), d = Date(timeIntervalSince1970: idea.updated / 1000)
        if g == "Today" || g == "Yesterday" { return d.formatted(date: .omitted, time: .shortened) }
        if g == "Previous 7 Days" { return d.formatted(.dateTime.weekday(.wide)) }
        return ShortDate.string(idea.updated)
    }

    private func preview(_ lines: [String]) -> String {
        let rest = lines.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        if !rest.isEmpty { return rest }
        if let sid = idea.usedSongID, let s = library.song(sid) { return "In " + (s.title.isEmpty ? "Untitled" : s.title) }
        let k = IdeaLook.kind(idea)
        if k != "line" && k != "memo" { return IdeaLook.name(k) }
        if let m = idea.memo { return SongFiles.time(m.dur) }
        let tags = (idea.raw["tags"]?.array ?? []).compactMap(\.string)
        return tags.isEmpty ? "" : "#" + tags.joined(separator: " #")
    }
}

/// A memo's play button, waveform (a tick a second while scrubbing) and time.
struct MemoPlayer: View {
    let ideaID: String
    let memo: FileItem
    var large = false
    /// on a card: no time (the card's footer shows it)
    var compact = false
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
            if !compact || (active && t > 0) {
                Text(active && t > 0 ? "\(SongFiles.time(t)) / \(SongFiles.time(dur))" : SongFiles.time(dur))
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .onChange(of: player.error) { _, e in if let e, active { session.toast = e; player.error = nil } }
    }
}

/// The Idea sheet (spec §2.6): a switch for Line, Title or Concept, the words, and "Goes with": related ideas. Saves when it closes. Matches the web's editIdea.
struct IdeaSheet: View {
    let idea: Idea?
    @Environment(\.appSession) private var session
    @Environment(\.library) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openRoute) private var openRoute
    @State private var text = ""
    @State private var kind = "line"
    @State private var draftID = UUID().uuidString.lowercased()
    @State private var shown: Idea?
    @State private var confirmDelete = false
    @State private var gone = false
    @State private var loaded = false
    @FocusState private var focused: Bool

    private var current: Idea? { (shown ?? idea).flatMap { i in library.ideas.first { $0.id == i.id } } }
    private var memoOnly: Bool { current?.memo != nil && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                if !memoOnly {
                    Section {
                        Picker("Kind", selection: $kind) {
                            Text("Line").tag("line")
                            Text("Title").tag("title")
                            Text("Concept").tag("concept")
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                    }
                }
                if let c = current, let m = c.memo {
                    Section {
                        MemoPlayer(ideaID: c.id, memo: m, large: true)
                        Button("Remove", role: .destructive) { removeMemo(c) }
                    }
                }
                Section {
                    TextField(current?.memo != nil ? "Add words to go with it…" : "A line, a title, an idea…", text: $text, axis: .vertical)
                        .font(textFont)
                        .lineLimit(2...20)
                        .focused($focused)
                }
                if let c = current {
                    let rel = IdeaLook.related(c, in: library.ideas)
                    if !rel.isEmpty {
                        Section {
                            ForEach(rel) { r in
                                Button { commit(); Haptics.tap(); show(r.idea) } label: {
                                    VStack(alignment: .leading, spacing: 1) {
                                            Text(r.idea.text.isEmpty ? "Voice memo · " + SongFiles.time(r.idea.memo?.dur ?? 0) : r.idea.text.components(separatedBy: "\n").first ?? "")
                                                .foregroundStyle(.primary).lineLimit(1)
                                            Text(r.why).font(.system(size: 13)).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } header: {
                            Text("Goes with")
                        }
                    }
                    Section {
                        Button { Task { await startSong(c) } } label: {
                            Label { Text("Start a Song").foregroundStyle(.primary) } icon: { TileIcon("music.note", Theme.Tile.orange) }
                        }
                        Button("Delete Idea", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(current == nil ? "New Idea" : "Idea")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { DoneButton { dismiss() } } }
            .confirmDestroy("Delete this idea?", isPresented: $confirmDelete, message: "This can’t be undone.", action: "Delete Idea") {
                guard let c = current else { return }
                gone = true
                IdeaMemos.deleteFile(c.memo)
                library.deleteIdea(c.id)
                Haptics.thud()
                // after the action sheet has gone, or the sheet won't close
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { dismiss() }
            }
            .onChange(of: kind) { _, k in
                guard loaded else { return }
                Haptics.tap()
                guard var i = current, i.kind != k, !(i.memo != nil && i.text.isEmpty) else { return }
                i.raw["kind"] = .string(k)
                i.updated = Clock.nowMs
                library.putIdea(i)
            }
        }
        .belowIslandSheet()
        .onAppear {
            load(idea)
            if idea == nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focused = true } }
        }
        .onDisappear { commit(); library.ideaEditingID = nil }
    }

    private var textFont: Font { kind == "title" ? .system(size: 19, weight: .semibold) : .system(size: 19) }

    private func load(_ i: Idea?) {
        loaded = false
        DispatchQueue.main.async { loaded = true }
        text = i?.text ?? ""
        let k = i?.kind ?? "line"
        kind = k == "memo" ? "line" : (k == "idea" ? "title" : k)
        library.ideaEditingID = i?.id
    }

    /// Opens a related idea in this same sheet.
    private func show(_ i: Idea) {
        withAnimation(.snappy) { shown = i; load(i) }
    }

    /// Empty new ideas are dropped; a memo idea is `memo` without words and takes the chosen kind with them.
    private func commit() {
        guard !gone else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var i = current else {
            if idea == nil && shown == nil && !t.isEmpty {
                var n = Idea.new(text: t)
                n.raw["id"] = .string(draftID)
                n.raw["kind"] = .string(kind)
                library.putIdea(n)
            }
            return
        }
        guard i.text != text else { return }
        i.text = text
        if i.memo != nil { i.raw["kind"] = .string(t.isEmpty ? "memo" : kind) }
        i.updated = Clock.nowMs
        library.putIdea(i)
    }

    private func removeMemo(_ c: Idea) {
        Haptics.thud()
        IdeaMemos.deleteFile(c.memo)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            gone = true
            library.deleteIdea(c.id)
            dismiss()
        } else {
            var i = c
            i.raw.removeValue(forKey: "memo")
            i.text = text
            i.raw["kind"] = .string(kind)
            i.updated = Clock.nowMs
            library.putIdea(i)
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

/// Ideas' icon: the *[demo] asterisk in white on the Pro screen's soft multicolour wash
/// (peach, pink, violet and sky blue).
struct IdeasTile: View {
    var size: CGFloat = 52
    @Environment(\.colorScheme) private var scheme
    /// A flat black square with the white asterisk (a touch lighter in dark mode, so it doesn't vanish into the page).
    var body: some View {
        Image(systemName: "asterisk").font(.system(size: size * 0.44, weight: .bold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(hex: scheme == .dark ? 0x2C2C2E : 0x1C1C1E), in: RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            .accessibilityHidden(true)
    }
}
