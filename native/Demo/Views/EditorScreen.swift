import SwiftUI
import UIKit
import PhotosUI

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
    @State private var editorFrame = CGRect.zero
    @State private var topBarBottom: CGFloat = 0
    @State private var rhymeTop: CGFloat = 0

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
                        RhymeBar(bridge: bridge, context: context, results: results,
                                 onOpenDictionary: { showDictionary = true },
                                 voiceTouched: WritingVoice.isTouched(song.voice),
                                 onVoice: openVoice)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 6)
                            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { rhymeTop = $0 }
                            .background(alignment: .bottom) { bottomFade }
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
            DetailsSheet(songID: songID, tab: t, onRestore: { reloadEditor() }, onDelete: { deleteSong() })
        }
        .sheet(isPresented: $showVoice, onDismiss: { refreshResults() }) { VoiceSheet(songID: songID) }
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
        }
        .onDisappear {
            if library.editingID == songID { library.editingID = nil }
            // a new song left untouched isn't kept (spec §1.6)
            if let s = library.song(songID), s.isEmptyDraft, !s.isPlaceholder { library.delete(s.id) }
        }
    }

    // MARK: header

    private func header(_ s: Song) -> some View {
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
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    // MARK: menus

    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                Button { Haptics.tap(); dismiss() } label: {
                    Icon("ic-back", 20).foregroundStyle(Theme.tint).frame(width: 38, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(PressScale()).accessibilityLabel("Songs")
                Button {
                    Haptics.tap()
                    bridge.textView?.resignFirstResponder()
                    withAnimation(.snappy(duration: 0.32)) { showSide = true }
                } label: {
                    Icon("ic-sidebar", 22).foregroundStyle(Theme.tint).frame(width: 38, height: 44).contentShape(Rectangle())
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
                    Icon("ic-share", 20).foregroundStyle(Theme.tint).frame(width: 38, height: 44).contentShape(Rectangle())
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
        .background { EdgeFade(edge: .top) }
    }

    /// The web's .fadeB: the lyrics blur out under the rhyme bar.
    private var bottomFade: some View {
        EdgeFade(edge: .bottom).frame(height: 130).offset(y: 6)
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
            Icon(icon, 20)
                .foregroundStyle(on ? Theme.onTint : Theme.tint)
                .frame(width: 34, height: 34)
                .background(on ? Theme.tint : .clear, in: Circle())
                .frame(width: 38, height: 44)
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
            Icon("ic-more", 22).foregroundStyle(Theme.tint).frame(width: 44, height: 44).contentShape(Rectangle())
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
