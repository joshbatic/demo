import SwiftUI
import UIKit

struct EditorScreen: View {
    let songID: String
    @Environment(AppSession.self) private var session
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var bridge = EditorBridge()
    @State private var showDetails = false
    @State private var confirmDelete = false
    @State private var results = WordResults()
    @State private var context = RhymeContext()
    @State private var showDictionary = false
    @State private var showMap = UserDefaults.standard.bool(forKey: "view.map")
    @State private var showSyl = UserDefaults.standard.bool(forKey: "view.syl")

    private var song: Song? { library.song(songID) }

    var body: some View {
        Group {
            if let song {
                VStack(spacing: 0) {
                    header(song)
                    RichTextEditor(bridge: bridge, rich: song.rich, lyrics: song.lyrics)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    RhymeBar(bridge: bridge, context: context, results: results) { showDictionary = true }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                }
            } else {
                ContentUnavailableView("Song deleted", systemImage: "music.note", description: Text("That song was deleted on another device."))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // one pill like the web's: 38-wide buttons, no gaps, a dark circle behind a toggle that's on
            ToolbarItem(placement: .topBarTrailing) {
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
            }
            ToolbarItemGroup(placement: .topBarTrailing) { moreMenu }
        }
        .sheet(isPresented: $showDetails) { if song != nil { DetailsSheet(songID: songID) } }
        .sheet(isPresented: $showDictionary) {
            DictionarySheet(bridge: bridge, initialWord: context.word, register: voice("reg") ?? "Conversational", perfectOnly: voiceStrict)
        }
        .confirmationDialog("Delete “\(song?.displayTitle ?? "")”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Song", role: .destructive) {
                if let s = song { dismiss(); Task { await session.removeSong(s) } }
            }
        } message: { Text("This can’t be undone.") }
        .onAppear {
            library.editingID = songID
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
            CoverView(song: s, size: 64)
            VStack(alignment: .leading, spacing: 3) {
                TextField("Untitled", text: Binding(get: { library.song(songID)?.title ?? "" }, set: { setTitle($0) }), axis: .vertical)
                    .font(.system(size: 26, weight: .bold))
                    .lineLimit(1...3)
                    .submitLabel(.next)
                Text([s.artist, s.status].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    // MARK: menus

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

    private var moreMenu: some View {
        Menu {
            Button { showDetails = true } label: { Label("Details", systemImage: "info.circle") }
            Button {
                guard let s = song else { return }
                UIPasteboard.general.string = (s.title.isEmpty ? "" : s.title + "\n\n") + s.lyrics
                Haptics.success(); session.toast = "Lyrics copied"
            } label: { Label("Copy Lyrics", systemImage: "doc.on.doc") }
            Button {
                guard let s = song else { return }
                let on = !library.isPinned(s.id)
                library.setPin(s.id, on); Haptics.selection()
                session.toast = on ? "Pinned" : "Unpinned"
            } label: {
                Label(library.isPinned(songID) ? "Unpin" : "Pin", systemImage: library.isPinned(songID) ? "pin.slash" : "pin")
            }
            Section {
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete Song", systemImage: "trash") }
            }
        } label: {
            Icon("ic-more", 22).foregroundStyle(Theme.tint).frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel("More")
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

/// Song details: the facts about a song, its notes and chord chart.
struct DetailsSheet: View {
    let songID: String
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss

    static let statuses = ["Idea", "Draft", "Demo", "Finished"]
    static let keys = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    field("Artists", \.artist, prompt: "Add artists")
                    Picker("Status", selection: binding(\.status)) { ForEach(Self.statuses, id: \.self) { Text($0) } }
                    Picker("Key", selection: binding(\.key)) {
                        Text("None").tag("")
                        ForEach(Self.keys, id: \.self) { k in Text(k).tag(k); Text(k + "m").tag(k + "m") }
                    }
                    HStack {
                        Text("Tempo")
                        Spacer()
                        TextField("BPM", text: binding(\.bpm)).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(maxWidth: 120)
                    }
                    field("Tuning", \.tuning, prompt: "Standard")
                    field("Folder", \.folder, prompt: "None")
                }
                Section("Notes") {
                    TextField("Melody ideas, references, co-writers", text: binding(\.notes), axis: .vertical).lineLimit(3...12)
                }
                Section("Chords") {
                    TextField("Chord chart", text: binding(\.chords), axis: .vertical).lineLimit(3...20)
                        .font(.system(.body, design: .monospaced))
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { DoneButton { dismiss() } }
            }
        }
        .presentationDetents([.large])
    }

    private func field(_ label: String, _ kp: WritableKeyPath<Song, String>, prompt: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(prompt, text: binding(kp)).multilineTextAlignment(.trailing)
        }
    }

    private func binding(_ kp: WritableKeyPath<Song, String>) -> Binding<String> {
        Binding(get: { library.song(songID)?[keyPath: kp] ?? "" }, set: { v in
            guard var s = library.song(songID), s[keyPath: kp] != v else { return }
            s[keyPath: kp] = v
            s.touch()
            library.put(s)
        })
    }
}
