import SwiftUI
import UIKit
import PhotosUI
import Combine

struct EditorScreen: View {
    let songID: String
    @Environment(AppSession.self) private var session
    @Environment(LibraryStore.self) private var library
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
    @State private var showSide = false
    @State private var showPlay = false
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
                                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { rhymeTop = $0 }
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
        .overlay { SongSidebar(isOpen: $showSide, currentID: songID) }
        .sheet(item: $detailsTab) { t in
            DetailsSheet(songID: songID, tab: t, onRestore: { reloadEditor() }, onDelete: { deleteSong() },
                         onPlayWithLyrics: { DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { showPlay = true } })
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
        .photosPicker(isPresented: $pickArt, selection: $artItem, matching: .images)
        .onChange(of: artItem) { _, item in if let item { loadArt(item) } }
        .sheet(isPresented: $showDictionary) {
            DictionarySheet(bridge: bridge, initialWord: context.word, register: voice("reg") ?? "Conversational", perfectOnly: voiceStrict)
        }
        .confirmationDialog("Delete “\(song?.displayTitle ?? "")”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Song", role: .destructive) { deleteSong() }
        } message: { Text("This can’t be undone.") }
        .onAppear {
            library.editingID = songID
            // an "Auto" version when the last one is over two hours old (spec §4.11)
            if var s = library.song(songID), s.autoSnap() { library.put(s) }
            bridge.onEdit = { attr in save(attr) }
            bridge.onSelection = { text, sel in updateContext(text, sel) }
            results.ai = {
                WordResults.AIContext(pro: session.plan.isPro, ctxOn: ctxOn, env: promptEnv())
            }
        }
        .onDisappear {
            if library.editingID == songID { library.editingID = nil }
            // leaving the song pauses its audio (spec §4.10)
            if !showPlay { AudioPlayer.shared.pause(ifSong: songID) }
            MuseMemory.shared.check(force: false)
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
        guard session.plan.isPro else { Haptics.warning(); session.toast = "Play with Lyrics is part of *[demo] Pro"; return }
        guard song?.currentAudio != nil else { session.toast = "Add audio in Details › Audio first"; return }
        bridge.textView?.resignFirstResponder()
        showPlay = true
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
            }
        }
    }

    // MARK: menus

    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                Button { Haptics.tap(); dismiss() } label: {
                    Icon("ic-back", 22).foregroundStyle(Theme.tint).frame(width: 44, height: 48).contentShape(Rectangle())
                }
                .buttonStyle(PressScale()).accessibilityLabel("Songs")
                Button {
                    Haptics.tap()
                    bridge.textView?.resignFirstResponder()
                    withAnimation(.snappy(duration: 0.32)) { showSide = true }
                } label: {
                    Icon("ic-sidebar", 24).foregroundStyle(Theme.tint).frame(width: 44, height: 48).contentShape(Rectangle())
                }
                .buttonStyle(PressScale()).accessibilityLabel("Show sidebar")
            }
            .padding(.horizontal, 2)
            .glassCapsule(interactive: true)

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
                ShareLink(item: shareText) {
                    Icon("ic-share", 22).foregroundStyle(Theme.tint).frame(width: 44, height: 48).contentShape(Rectangle())
                }
                .buttonStyle(PressScale())
                .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
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
            Haptics.warning(); session.toast = "Credits and release details are part of *[demo] Pro"; return
        }
        bridge.textView?.resignFirstResponder()
        detailsTab = t
    }

    // MARK: AI

    /// "Listen to the whole song": on by default for Pro, always off on Free (spec §4.15).
    private var ctxOn: Bool { session.plan.isPro && ctxPref }

    private func toggleCtx() {
        guard session.plan.isPro else { Haptics.warning(); session.toast = "Listening to the whole song is part of *[demo] Pro"; return }
        ctxPref.toggle()
        session.toast = ctxPref ? "Listening to the whole song" : "Only listening to nearby lines"
        results.refresh()
    }

    private func toggleLines() {
        guard session.plan.isPro else { Haptics.warning(); session.toast = "Lines is part of *[demo] Pro"; return }
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
        guard session.plan.isPro else { Haptics.warning(); session.toast = "Rate is part of *[demo] Pro"; return }
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
            Haptics.warning(); session.toast = "Writing voice is part of *[demo] Pro"; return
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
        var plain = attr.string
        if plain.hasSuffix("\n") { plain.removeLast() }
        let rich = RichText.html(from: attr, baseColor: .label)
        if plain != s.lyrics || rich != s.rich {
            s.setText(lyrics: plain, rich: rich)
            library.put(s, typing: true)
        }
        return (rich, plain)
    }
}
