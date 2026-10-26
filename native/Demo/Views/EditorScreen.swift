import SwiftUI
import UIKit
import PhotosUI
import Combine

struct EditorScreen: View {
    let songID: String
    @Environment(\.appSession) private var session
    @Environment(\.library) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var bridge = EditorBridge()
    @State private var detailsTab: DetailsTab?
    @State private var showVoice = false
    @State private var pickArt = false
    @State private var artItem: PhotosPickerItem?
    @State private var confirmDelete = false
    @State private var results = WordResults()
    @State private var context = RhymeContext()
    @State private var showDictionary = false
    @State private var showMap = UserDefaults.standard.bool(forKey: "view.map")
    @State private var showSyl = UserDefaults.standard.bool(forKey: "view.syl")
    @State private var showPlay = false
    @State private var showPerform = false
    @State private var showShare = false
    @State private var live = LiveSession()
    @State private var editorFrame = CGRect.zero
    @State private var topBarBottom: CGFloat = 0
    @State private var rhymeTop: CGFloat = 0
    // Phase C: the AI pieces
    @State private var lines = LinesModel()
    @State private var linesOn = false
    @AppStorage("view.ctx") private var ctxPref = true
    @State private var showMuse = false
    @State private var showRate = false
    @State private var showCleanup = false
    @State private var rateMode = false
    @State private var sprintEnd: Date?
    @State private var sprintWords = 0
    @State private var sprintNow = Date()

    private var song: Song? { library.song(songID) }

    var body: some View {
        Group {
            if let song {
                // the cover and title sit inside the lyrics' scroll, so they scroll away with the song (like the web)
                // the lyrics run the full height of the screen and scroll under the glass bars,
                // which float over them (the web's #sc under .bar and #rhy)
                ZStack {
                    RichTextEditor(bridge: bridge, rich: song.rich, lyrics: song.lyrics,
                                   header: AnyView(header(song).environment(session).environment(library).tint(Theme.tint)),
                                   insets: textInsets)
                        .ignoresSafeArea(.container, edges: .vertical)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { editorFrame = $0 }

                    VStack(spacing: 0) {
                        topBar
                            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { topBarBottom = $0 }
                        Spacer(minLength: 0)
                        if sprintEnd != nil {
                            sprintPill.padding(.bottom, 10)
                        } else {
                            RhymeBar(bridge: bridge, context: context, results: results,
                                     onOpenDictionary: { showDictionary = true },
                                     voiceTouched: WritingVoice.isTouched(song.voice),
                                     onVoice: openVoice,
                                     isPro: session.plan.isPro,
                                     onMuse: { bridge.textView?.resignFirstResponder(); showMuse = true },
                                     ctxOn: ctxOn,
                                     onToggleCtx: toggleCtx,
                                     linesOn: linesOn,
                                     onToggleLines: toggleLines,
                                     lines: lines,
                                     env: { promptEnv() },
                                     scheme: song.raw["scheme"]?.string ?? "auto",
                                     onScheme: setScheme,
                                     onCleanup: { bridge.textView?.resignFirstResponder(); showCleanup = true })
                                .padding(.horizontal, 10)
                                .padding(.bottom, 6)
                                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { rhymeTop = $0; session.toastAvoidTop = $0 }
                        }
                    }
                }
            } else {
                VStack(spacing: 0) {
                    topBar
                    ContentUnavailableView("Song deleted", systemImage: "music.note", description: Text("That song was deleted on another device."))
                }
            }
        }
        // the web's song bar instead of the system one: back + sidebar on the left,
        // map / syllables / share and ••• on the right, the lyrics fading under it
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $detailsTab) { t in
            DetailsSheet(songID: songID, tab: t, onRestore: { reloadEditor() }, onDelete: { deleteSong() },
                         onPlayWithLyrics: { DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { showPlay = true } },
                         onLeave: { dismiss() },
                         onPerform: {
                             guard session.plan.isPro else { session.upsell("perform"); return }
                             DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { showPerform = true }
                         })
        }
        .sheet(isPresented: $showShare) { ShareSheet(songID: songID) }
        // live co-writing: send what changed here (from typing, Details, anywhere) and file changes
        .onChange(of: liveKey) { _, _ in live.localChanged() }
        // Lines works without the keyboard: it would cover the lines and the rhyme bar. Tapping the words still
        // moves the cursor (Lines writes for the line you're on); turning Lines off brings typing back.
        .onChange(of: linesOn) { _, on in linesKeyboard(on) }
        // dropping to Free turns off what's Pro (applyPlan)
        .onChange(of: session.plan.isPro) { _, pro in if !pro { linesOn = false; if rateMode { setRateMode(false) } } }
        .onChange(of: filesKey) { _, _ in if live.isOn && !live.applying { live.filesChanged() } }
        // sharing (or stopping) moves the song to the other live channel
        .onChange(of: song?.isShared ?? false) { _, on in
            if live.topicShared != on || !live.isOn { live.start(songID: songID, library: library, session: session, bridge: bridge) }
        }
        .sheet(isPresented: $showVoice, onDismiss: { refreshResults(); lines.clear() }) { VoiceSheet(songID: songID) }
        .sheet(isPresented: $showMuse) {
            MuseSheet(songID: songID, bridge: bridge, section: context.stanza, env: { promptEnv() }, rateOn: rateMode,
                      onRate: { DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { openRate() } },
                      onRateOff: { setRateMode(false) },
                      onSprint: { secs, noun in DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { startSprint(secs, scratch: noun) } })
        }
        .sheet(isPresented: $showRate) {
            RateSheet(songID: songID, bridge: bridge, env: { promptEnv() },
                      onRework: { if !linesOn { toggleLines() } },
                      onExit: { setRateMode(false) })
        }
        .sheet(isPresented: $showCleanup) { CleanupSheet(songID: songID, onApplied: { reloadEditor() }) }
        .onChange(of: song?.raw["rating"]) { _, _ in updateMarks() }
        .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { now in
            guard let end = sprintEnd else { return }
            sprintNow = now
            if now >= end { endSprint(stopped: false) }
        }
        .fullScreenCover(isPresented: $showPlay) { PlayWithLyrics(songID: songID) }
        .fullScreenCover(isPresented: $showPerform) { PerformView(songID: songID) }
        .photosPicker(isPresented: $pickArt, selection: $artItem, matching: .images)
        .onChange(of: artItem) { _, item in if let item { loadArt(item) } }
        .sheet(isPresented: $showDictionary) {
            DictionarySheet(bridge: bridge, initialWord: context.word, register: voice("reg") ?? "Conversational", perfectOnly: voiceStrict, belowY: topBarBottom)
        }
        .confirmDestroy("Delete “\(song?.displayTitle ?? "")”?", isPresented: $confirmDelete, message: "This can’t be undone.", action: "Delete Song") {
            deleteSong()
        }
        .onAppear {
            library.editingID = songID
            // an "Auto" version when the last one is over two hours old (spec §4.11)
            if var s = library.song(songID), s.autoSnap() { library.put(s) }
            bridge.onEdit = { attr in save(attr) }
            bridge.onSelection = { text, sel in updateContext(text, sel) }
            // live on every song: co-writers on a shared one, and your own other devices on any
            live.start(songID: songID, library: library, session: session, bridge: bridge)
            markSeenIfNew()
            // a brand-new, empty song: straight to typing (the text view may take a moment to exist)
            if let s = library.song(songID), s.title.isEmpty, s.lyrics.isEmpty, !s.isShared {
                Task {
                    for _ in 0..<20 {
                        if let tv = bridge.textView, tv.window != nil { tv.becomeFirstResponder(); break }
                        try? await Task.sleep(for: .milliseconds(60))
                    }
                }
            }
            results.ai = {
                WordResults.AIContext(pro: session.plan.isPro, ctxOn: ctxOn, env: promptEnv())
            }
        }
        .onDisappear {
            if library.editingID == songID { library.editingID = nil }
            if session.toastAvoidTop == rhymeTop { session.toastAvoidTop = nil }
            // leaving the song pauses its audio (spec §4.10)
            if !showPlay { AudioPlayer.shared.pause(ifSong: songID) }
            MuseMemory.shared.check(force: false)
            live.stop()
            // a new song left untouched isn't kept (spec §1.6)
            if let s = library.song(songID), s.isEmptyDraft, !s.isPlaceholder { library.delete(s.id) }
        }
    }

    // MARK: header

    private func header(_ s: Song) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            titleRow(s)
            SongPlayer(song: s, onPlayWithLyrics: openPlay)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func openPlay() {
        guard session.plan.isPro else { session.upsell("play"); return }
        guard song?.currentAudio != nil else { session.toast = "Add audio in Details › Audio first"; return }
        bridge.textView?.resignFirstResponder()
        showPlay = true
    }

    // MARK: co-writing

    private var liveKey: String {
        guard let s = song else { return "" }
        return LiveSession.fields.map { LiveSession.value(s, $0) }.joined(separator: "\u{1}") + "\u{1}" + s.rich
    }

    private var filesKey: String {
        guard let s = song else { return "" }
        return CanonicalJSON.string(.array([s.raw["rmFiles"] ?? .null, s.raw["audio"] ?? .null, s.raw["files"] ?? .null]))
    }

    private static var seenKey: String { "songpad:seen" }
    private func seenLyrics() -> String? { (UserDefaults.standard.dictionary(forKey: Self.seenKey) as? [String: String])?[songID] }
    private func setSeen(_ v: String) {
        var d = (UserDefaults.standard.dictionary(forKey: Self.seenKey) as? [String: String]) ?? [:]
        d[songID] = v
        UserDefaults.standard.set(d, forKey: Self.seenKey)
    }
    private func markSeenIfNew() { if seenLyrics() == nil, let s = song { setSeen(s.lyrics) } }

    /// "Sam added 3 new lines": lines a co-writer added since I last dismissed it (data spec §3.11).
    private func addedHint(_ s: Song) -> String? {
        guard s.isShared, let seen = seenLyrics(), seen != s.lyrics else { return nil }
        let by = s.raw["lastEditBy"]?.string ?? ""
        guard !by.isEmpty, by != session.email, by != session.myName else { return nil }
        var before: [String: Int] = [:]
        for l in seen.components(separatedBy: "\n") { let t = l.trimmingCharacters(in: .whitespaces); if !t.isEmpty { before[t, default: 0] += 1 } }
        var added = 0
        for l in s.lyrics.components(separatedBy: "\n") {
            let t = l.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if (before[t] ?? 0) > 0 { before[t]! -= 1 } else { added += 1 }
        }
        guard added > 0 else { return nil }
        let name = by.components(separatedBy: "@")[0]
        return (name.prefix(1).uppercased() + name.dropFirst()) + " added \(added) new \(added == 1 ? "line" : "lines") · tap to dismiss"
    }

    private func titleRow(_ s: Song) -> some View {
        HStack(alignment: .center, spacing: 14) {
            // tap the cover to choose a photo (spec §4.1)
            Button { Haptics.tap(); pickArt = true } label: { CoverView(song: s, size: 64) }
                .buttonStyle(PressScale())
                .accessibilityLabel("Cover art")
            VStack(alignment: .leading, spacing: 2) {
                TextField("Untitled", text: Binding(get: { library.song(songID)?.title ?? "" }, set: { setTitle($0) }), axis: .vertical)
                    .font(.system(size: 26, weight: .bold))
                    .lineLimit(1...3)
                    .submitLabel(.next)
                if !s.artist.isEmpty {
                    Text(s.artist).font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                }
                Text([s.status, s.key, s.bpm.isEmpty ? "" : s.bpm + " BPM"].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.tertiary).lineLimit(1)
                if let who = live.writing {
                    Text("\(who) is writing…").font(.footnote.weight(.medium)).foregroundStyle(Theme.proGreen)
                } else if let hint = addedHint(s) {
                    Text(hint).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                        .onTapGesture { setSeen(s.lyrics); Haptics.tap(); library.put(s) }
                }
            }
        }
    }

    // MARK: menus

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { Haptics.tap(); dismiss() } label: {
                Icon("ic-back", 22).foregroundStyle(Theme.tint).frame(width: 48, height: 48).contentShape(Circle())
            }
            .buttonStyle(PressScale())
            .glassCircle()
            .accessibilityLabel("Songs")

            Spacer(minLength: 0)

            HStack(spacing: 0) {
                barToggle("ic-map", "Rhyme map", on: showMap) {
                    showMap.toggle(); bridge.showMap = showMap
                    session.toast = showMap ? "Rhyme map on" : "Rhyme map off"
                }
                barToggle("ic-syl", "Syllable counts", on: showSyl) {
                    showSyl.toggle(); bridge.showSyl = showSyl
                    session.toast = showSyl ? "Syllable counts on" : "Syllable counts off"
                }
                Button { Haptics.tap(); bridge.textView?.resignFirstResponder(); showShare = true } label: {
                    Icon("ic-share", 22).foregroundStyle(Theme.tint).frame(width: 44, height: 48).contentShape(Rectangle())
                }
                .buttonStyle(PressScale())
                .accessibilityLabel("Share")
            }
            .padding(.horizontal, 2)
            .glassCapsule(interactive: true)

            moreMenu
                .buttonStyle(PressScale())
                .glassCircle()
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// Room at the top and bottom of the lyrics for the bars floating over them.
    private var textInsets: UIEdgeInsets {
        guard editorFrame.height > 0 else { return .zero }
        let top = max(0, topBarBottom - editorFrame.minY)
        let bottom = rhymeTop > 0 ? max(0, editorFrame.maxY - rhymeTop) + 12 : 0
        return UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
    }

    private func barToggle(_ icon: String, _ label: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button { Haptics.selection(); withAnimation(.snappy(duration: 0.2)) { action() } } label: {
            Icon(icon, 22)
                .foregroundStyle(on ? Theme.onTint : Theme.tint)
                .frame(width: 38, height: 38)
                .background(on ? Theme.tint : .clear, in: Circle())
                .frame(width: 44, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(label).accessibilityValue(on ? "On" : "Off")
    }

    private var shareText: String {
        guard let s = song else { return "" }
        return (s.title.isEmpty ? "" : s.title + "\n\n") + s.lyrics
    }

    /// The web's ••• menu: the Details tabs, then Copy Lyrics, then Remove Cover Art and Delete Song.
    private var moreMenu: some View {
        Menu {
            Section {
                Button { openDetails(.info) } label: { Label("Details", systemImage: "info.circle") }
                Button { openDetails(.audio) } label: { Label("Audio", systemImage: "waveform") }
                Button { openDetails(.chords) } label: { Label("Chords", systemImage: "music.note.list") }
                Button { openDetails(.credits) } label: { Label("Credits", systemImage: "person.2") }
            }
            Section {
                Button {
                    guard session.plan.isPro else { session.upsell("perform"); return }
                    bridge.textView?.resignFirstResponder()
                    showPerform = true
                } label: { Label("Perform", systemImage: "music.mic") }
                Button {
                    guard let s = song else { return }
                    UIPasteboard.general.string = (s.title.isEmpty ? "" : s.title + "\n\n") + s.lyrics
                    Haptics.success(); session.toast = "Copied"
                } label: { Label("Copy Lyrics", systemImage: "doc.on.doc") }
            }
            Section {
                if song?.artDataURL != nil {
                    Button(role: .destructive) {
                        guard var s = song else { return }
                        s.raw["art"] = ""; s.touch(); library.put(s); Haptics.tap()
                    } label: { Label("Remove Cover Art", systemImage: "photo") }
                }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete Song", systemImage: "trash") }
            }
        } label: {
            Icon("ic-more", 24).foregroundStyle(Theme.tint).frame(width: 48, height: 48).contentShape(Rectangle())
        }
        .accessibilityLabel("Details")
    }

    private func openDetails(_ t: DetailsTab) {
        if t == .credits && !session.plan.isPro {
            session.upsell("release"); return
        }
        bridge.textView?.resignFirstResponder()
        detailsTab = t
    }

    // MARK: AI

    /// "Listen to the whole song": on by default for Pro, always off on Free (spec §4.15).
    private var ctxOn: Bool { session.plan.isPro && ctxPref }

    private func toggleCtx() {
        guard session.plan.isPro else { session.upsell("listen"); return }
        ctxPref.toggle()
        session.toast = ctxPref ? "Listening to the whole song" : "Only listening to nearby lines"
        results.refresh()
    }

    private func linesKeyboard(_ on: Bool) {
        guard let tv = bridge.textView else { return }
        tv.inputView = on ? UIView(frame: .zero) : nil
        if tv.isFirstResponder { tv.reloadInputViews() }
    }

    private func toggleLines() {
        guard session.plan.isPro else { session.upsell("lines"); return }
        withAnimation(.snappy(duration: 0.25)) { linesOn.toggle() }
    }

    private func setScheme(_ s: String) {
        guard var song = library.song(songID) else { return }
        song.raw["scheme"] = .string(s)
        library.put(song)
        if let tv = bridge.textView { updateContext(tv.text, tv.selectedRange) }
    }

    /// What the prompts need: this song, the library, the editor's text and the context toggle.
    private func promptEnv() -> PromptEnv? {
        guard let s = library.song(songID) else { return nil }
        return PromptEnv(song: s, songs: library.songs, text: bridge.textView?.text ?? s.lyrics, ctxOn: ctxOn)
    }

    private func openRate() {
        guard session.plan.isPro else { session.upsell("rate"); return }
        bridge.textView?.resignFirstResponder()
        setRateMode(true)
        showRate = true
    }

    private func setRateMode(_ on: Bool) {
        rateMode = on
        updateMarks()
    }

    /// Rate mode marks what's working (green) and the issues (red) in the lyrics.
    private func updateMarks() {
        guard rateMode, let r = song?.raw["rating"]?.object else { bridge.rateMarks = []; return }
        let good = (r["strengths"]?.array ?? []).compactMap { $0["quote"]?.string }.map { (quote: $0, good: true) }
        let bad = (r["issues"]?.array ?? []).compactMap { $0["quote"]?.string }.map { (quote: $0, good: false) }
        bridge.rateMarks = good + bad
    }

    // MARK: sprint (spec §2.12)

    private var sprintPill: some View {
        let left = max(0, (sprintEnd ?? sprintNow).timeIntervalSince(sprintNow))
        return HStack(spacing: 14) {
            Text(SongFiles.time(left.rounded(.up))).font(.system(size: 20, weight: .semibold).monospacedDigit())
            Button("Stop") { endSprint(stopped: true) }
                .font(.system(size: 16, weight: .semibold))
        }
        .padding(.horizontal, 20).frame(height: 50)
        .glassCapsule(interactive: true)
    }

    private func startSprint(_ seconds: Int, scratch: String?) {
        if let noun = scratch { bridge.appendAtEnd("\n\n[Scratch: \(noun)]\n") }
        else {
            bridge.textView?.becomeFirstResponder()
            let end = (bridge.textView?.text as NSString?)?.length ?? 0
            bridge.textView?.selectedRange = NSRange(location: end, length: 0)
        }
        sprintWords = bridge.wordCount
        sprintNow = Date()
        withAnimation(.snappy) { sprintEnd = Date().addingTimeInterval(TimeInterval(seconds)) }
        Haptics.thud()
    }

    private func endSprint(stopped: Bool) {
        let n = max(0, bridge.wordCount - sprintWords)
        withAnimation(.snappy) { sprintEnd = nil }
        Haptics.success()
        session.toast = (stopped ? "Stopped. " : "Time. ") + "\(n) new \(n == 1 ? "word" : "words")."
    }

    private func openVoice() {
        guard session.plan.isPro else {
            session.upsell("voice"); return
        }
        bridge.textView?.resignFirstResponder()
        showVoice = true
    }

    private func deleteSong() {
        if let s = song { dismiss(); Task { await session.removeSong(s) } }
    }

    /// Lets the editor take text that changed under it (a restored version), even mid-typing.
    private func reloadEditor() {
        bridge.textView?.resignFirstResponder()
        bridge.lastEdit = .distantPast
    }

    private func refreshResults() {
        results.register = voice("reg") ?? "Conversational"
        results.perfectOnly = voiceStrict
        results.refresh()
    }

    /// The chosen photo, centre-cropped to a 480 × 480 JPEG at 0.8 (spec §4.1).
    private func loadArt(_ item: PhotosPickerItem) {
        Task {
            defer { artItem = nil }
            guard let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) else {
                session.toast = "Could not read that image"; return
            }
            let side: CGFloat = 480
            let w = img.size.width, h = img.size.height, m = min(w, h)
            let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = 1
            let out = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt).image { _ in
                let scale = side / m
                img.draw(in: CGRect(x: -(w - m) / 2 * scale, y: -(h - m) / 2 * scale, width: w * scale, height: h * scale))
            }
            guard let jpg = out.jpegData(compressionQuality: 0.8), var s = library.song(songID) else {
                session.toast = "Could not read that image"; return
            }
            s.raw["art"] = .string("data:image/jpeg;base64," + jpg.base64EncodedString())
            s.touch()
            library.put(s)
            Haptics.success()
        }
    }

    // MARK: the rhyme bar

    private func voice(_ k: String) -> String? { song?.raw["pf"]?[k]?.string }
    private var voiceStrict: Bool { song?.raw["pf"]?["strict"]?.bool ?? true }

    /// Follows the caret: which word, which line it should rhyme with, how many syllables it needs.
    private func updateContext(_ text: String, _ sel: NSRange) {
        let scheme = song?.raw["scheme"]?.string ?? "auto"
        let c = RhymeContext.make(text: text, selection: sel, scheme: scheme)
        let eng = RhymeEngine.shared
        let need = c.ref.isEmpty ? 0 : eng.lineSyllables(c.ref) - eng.lineSyllables(c.line)
        results.register = voice("reg") ?? "Conversational"
        results.perfectOnly = voiceStrict
        let leftChanged = results.left != max(0, need)
        results.left = max(0, need)
        if c != context { context = c }
        results.line = c.line
        let sel = c.selection.trimmingCharacters(in: .whitespacesAndNewlines)
        results.phrase = sel.split(whereSeparator: { $0 == " " }).count > 1 && !sel.contains("\n") ? sel : ""
        if RhymeEngine.normalise(c.word) != RhymeEngine.normalise(results.word) || leftChanged { results.show(c.word) }
    }

    // MARK: saving

    private func setTitle(_ t: String) {
        guard var s = library.song(songID) else { return }
        let clean = t.replacingOccurrences(of: "\n", with: " ")
        guard clean != s.title else { return }
        s.title = clean
        if s.isPlaceholder { s.raw.removeValue(forKey: "ph") }
        s.touch()
        library.put(s, typing: true)
    }

    /// Stores the editor's text: plain lyrics plus the matching formatted HTML (spec §1.2).
    private func save(_ attr: NSAttributedString) -> (String, String) {
        guard var s = library.song(songID) else { return ("", "") }
        // the editor's text is the lyrics exactly (a new line at the end is real: co-writers see it too)
        let plain = attr.string
        let rich = RichText.html(from: attr, baseColor: .label)
        if plain != s.lyrics || rich != s.rich {
            s.setText(lyrics: plain, rich: rich)
            library.put(s, typing: true)
        }
        return (rich, plain)
    }
}
