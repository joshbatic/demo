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

    private var song: Song? { library.song(songID) }

    var body: some View {
        Group {
            if let song {
                VStack(spacing: 0) {
                    header(song)
                    RichTextEditor(bridge: bridge, rich: song.rich, lyrics: song.lyrics)
                }
            } else {
                ContentUnavailableView("Song deleted", systemImage: "music.note", description: Text("That song was deleted on another device."))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                formatMenu
                moreMenu
            }
        }
        .sheet(isPresented: $showDetails) { if song != nil { DetailsSheet(songID: songID) } }
        .confirmationDialog("Delete “\(song?.displayTitle ?? "")”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Song", role: .destructive) {
                if let s = song { dismiss(); Task { await session.removeSong(s) } }
            }
        } message: { Text("This can’t be undone.") }
        .onAppear {
            library.editingID = songID
            bridge.onEdit = { attr in save(attr) }
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

    private var formatMenu: some View {
        Menu {
            ControlGroup {
                Button { bridge.toggle(.bold) } label: { Label("Bold", systemImage: "bold") }
                Button { bridge.toggle(.italic) } label: { Label("Italic", systemImage: "italic") }
                Button { bridge.toggle(.underline) } label: { Label("Underline", systemImage: "underline") }
                Button { bridge.toggle(.strike) } label: { Label("Strikethrough", systemImage: "strikethrough") }
            }
            Menu {
                ForEach(RichText.textColors, id: \.0) { name, c in
                    Button { bridge.setColor(c) } label: { Label { Text(name) } icon: { Image(systemName: "circle.fill").foregroundStyle(Color(uiColor: c)) } }
                }
                Button { bridge.setColor(nil) } label: { Label("Default", systemImage: "circle") }
            } label: { Label("Text Colour", systemImage: "paintpalette") }
            Menu {
                ForEach(RichText.highlights, id: \.0) { name, c in
                    Button { bridge.setHighlight(c) } label: { Label { Text(name) } icon: { Image(systemName: "highlighter").foregroundStyle(Color(uiColor: c.withAlphaComponent(1))) } }
                }
                Button { bridge.setHighlight(nil) } label: { Label("No Highlight", systemImage: "eraser") }
            } label: { Label("Highlight", systemImage: "highlighter") }
            Button { bridge.clearFormatting() } label: { Label("Clear Formatting", systemImage: "textformat") }
        } label: {
            Image(systemName: "textformat")
        }
        .accessibilityLabel("Text formatting")
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
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More")
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
                ToolbarItem(placement: .confirmationAction) {
                    Button { Haptics.tap(); dismiss() } label: { Image(systemName: "checkmark") }
                        .accessibilityLabel("Done")
                }
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
