import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The song list: Pinned first, then folders and Songs, each group ordered by its newest song
/// (spec §1.6), with search, swipe actions and press-and-hold menus.
struct SongListScreen: View {
    @Environment(AppSession.self) private var session
    @Environment(LibraryStore.self) private var library
    @State private var path: [String] = []
    @State private var query = ""
    @State private var showAccount = false
    @State private var confirmDelete: Song?
    // folders and backups (spec §3.6–3.7)
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var importing = false
    @State private var exportURL: URL?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if query.isEmpty {
                    IdeasRow()
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 20))
                }
                ForEach(groups, id: \.key) { g in
                    Section {
                        groupHeader(g)
                        ForEach(Array(g.songs.enumerated()), id: \.element.id) { i, s in
                            // no chevron, and a hairline only between songs, from the text to the edge (.song+.song)
                            ZStack {
                                NavigationLink(value: s.id) { EmptyView() }.opacity(0)
                                SongRow(song: s, showFolder: g.pinned)
                            }
                            // press and drag a song onto a folder's title to move it there
                            .draggable(SongDrag.prefix + s.id) { SongRow(song: s).frame(width: 300).padding(.horizontal, 12).background(.background, in: RoundedRectangle(cornerRadius: 16)) }
                            .overlay(alignment: .top) {
                                if i > 0 { Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5).padding(.leading, 66).padding(.trailing, -24) }
                            }
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24))
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) { confirmDelete = s } label: {
                                        Label(isMine(s) ? "Delete" : "Leave", systemImage: isMine(s) ? "trash" : "rectangle.portrait.and.arrow.right")
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    Button { togglePin(s) } label: {
                                        Label(library.isPinned(s.id) ? "Unpin" : "Pin", systemImage: library.isPinned(s.id) ? "pin.slash.fill" : "pin.fill")
                                    }
                                    .tint(.orange)
                                }
                                .contextMenu {
                                    Button { path.append(s.id) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
                                    Section {
                                        Button { togglePin(s) } label: {
                                            Label(library.isPinned(s.id) ? "Unpin" : "Pin", systemImage: library.isPinned(s.id) ? "pin.slash" : "pin")
                                        }
                                        Button { copyLyrics(s) } label: { Label("Copy Lyrics", systemImage: "doc.on.doc") }
                                        moveMenu(s)
                                    }
                                    Section {
                                        Button(role: .destructive) { confirmDelete = s } label: {
                                            Label(isMine(s) ? "Delete Song" : "Leave Song", systemImage: isMine(s) ? "trash" : "rectangle.portrait.and.arrow.right")
                                        }
                                    }
                                } preview: {
                                    SongPreview(song: s)
                                }
                        }
                    }
                }
                if groups.isEmpty {
                    // the web's .empty
                    VStack(spacing: 6) {
                        if !query.isEmpty || !library.songs.isEmpty {
                            Text("No Results").font(.system(size: 17)).foregroundStyle(.secondary)
                        } else {
                            Text("No songs yet").font(.system(size: 17, weight: .semibold))
                            Text("Tap the pencil to write your first line.").font(.system(size: 15)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 60)
                    .listRowSeparator(.hidden)
                }
                if query.isEmpty { footer }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.interactively)
            .refreshable { library.sync() }
            // like the web app: a big title that stays put with the songs scrolling under it,
            // and the search bar with the New Song button floating at the bottom
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                ListHeader(title: "*[demo]") { AccountButton { showAccount = true } }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SearchDock(text: $query, prompt: "Search", icon: "ic-new", label: "New song") { newSong() }
            }
            .navigationDestination(for: String.self) { id in
                if id == IdeasRow.route { IdeasScreen() } else { EditorScreen(songID: id) }
            }
            .sheet(isPresented: $showAccount) { AccountScreen() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText, .text], allowsMultipleSelection: true) { r in
                if case .success(let urls) = r, !urls.isEmpty { Haptics.success(); session.toast = library.importFiles(urls) }
            }
            .sheet(item: Binding(get: { exportURL.map(ShareSheet.IdentURL.init) }, set: { exportURL = $0?.url })) { u in
                ActivityView(items: [u.url])
            }
            .alert("Rename Folder", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Folder name", text: $renameText)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Rename") { commitRename() }
            }
            .confirmationDialog(deleteTitle, isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
                if let s = confirmDelete {
                    Button(isMine(s) ? "Delete Song" : "Leave Song", role: .destructive) { Task { await session.removeSong(s) } }
                }
            } message: {
                Text(confirmDelete.map { isMine($0) ? "This can’t be undone." : "It stays with its owner." } ?? "")
            }
        }
        // the editor's sidebar swaps the open song for another (or for Ideas)
        .environment(\.openRoute) { id in
            if path.isEmpty { path.append(id) } else { path[path.count - 1] = id }
        }
    }

    private var deleteTitle: String {
        guard let s = confirmDelete else { return "" }
        return (isMine(s) ? "Delete “" : "Leave “") + s.displayTitle + "”?"
    }

    private func isMine(_ s: Song) -> Bool { !s.isShared || s.owner.isEmpty || s.owner == session.userID }

    struct SongGroup {
        let name: String; let songs: [Song]; var pinned = false
        var key: String { pinned ? "\u{0}pin" : name }
        /// a real folder (not "Songs" or "Pinned"): it can be renamed
        var isFolder: Bool { !pinned && name != "Songs" }
        /// what dropping a song here sets its folder to
        var dropFolder: String? { pinned ? nil : name == "Songs" ? "" : name }
    }

    /// The web's .gh: a big bold group title that scrolls away with its songs, with a rename pencil
    /// on folders. Drop a song on it to move it into that group.
    private func groupHeader(_ g: SongGroup) -> some View {
        HStack(spacing: 8) {
            Text(g.name).font(.system(size: 20, weight: .bold)).lineLimit(1)
            if g.isFolder {
                Button { startRename(g.name) } label: {
                    Image(systemName: "pencil").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Rename folder " + g.name)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 22).padding(.bottom, 6)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            guard let f = g.dropFolder, let id = SongDrag.id(items.first) else { return false }
            moveSong(id, to: f); return true
        }
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24))
        .accessibilityAddTraits(.isHeader)
    }

    /// The footer links (#newfolderb, #impb, #expb).
    private var footer: some View {
        HStack(spacing: 6) {
            Button("New Folder") { newFolder() }
            Text("·").foregroundStyle(.tertiary)
            Button("Import Songs") { Haptics.tap(); importing = true }
            Text("·").foregroundStyle(.tertiary)
            Button("Export All Songs") { exportAll() }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 14))
        .foregroundStyle(.secondary)
        .tint(Color.secondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 26).padding(.bottom, 20)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        // a drop zone like the web's "Drop here for a new folder"
        .dropDestination(for: String.self) { items, _ in
            guard let id = SongDrag.id(items.first) else { return false }
            let f = library.freeFolderName()
            moveSong(id, to: f)
            startRename(f)
            return true
        }
    }

    /// Long-press › Move to Folder: every folder, a new one, or out of folders.
    @ViewBuilder private func moveMenu(_ s: Song) -> some View {
        Menu {
            ForEach(library.folderNames.filter { $0 != s.folder }, id: \.self) { f in
                Button(f) { moveSong(s.id, to: f) }
            }
            Button { let f = library.freeFolderName(); moveSong(s.id, to: f); startRename(f) } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            if !s.folder.isEmpty {
                Button { moveSong(s.id, to: "") } label: { Label("Remove from Folder", systemImage: "folder.badge.minus") }
            }
        } label: { Label("Move to Folder", systemImage: "folder") }
    }

    private func moveSong(_ id: String, to f: String) {
        guard let s = library.song(id), s.folder != f else { return }
        Haptics.tap()
        withAnimation(.snappy) { library.move(id, to: f) }
        session.toast = f.isEmpty ? "Moved out of folders" : "Moved to “\(f)”"
    }

    private func newFolder() {
        Haptics.tap()
        let f = withAnimation(.snappy) { library.createFolder() }
        startRename(f)
    }

    private func startRename(_ f: String) { renameText = f; renaming = f }

    private func commitRename() {
        guard let old = renaming else { return }
        renaming = nil
        let nv = renameText
        guard let n = withAnimation(.snappy, { library.renameFolder(old, to: nv) }) else { return }
        let name = nv.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        session.toast = "Renamed to “\(name)”" + (n > 1 ? " (\(n) songs)" : "")
    }

    private func exportAll() {
        Haptics.tap()
        guard let u = library.exportFile() else { session.toast = "No songs to export yet"; return }
        exportURL = u
    }

    /// Pinned (newest pin first), then folders and "Songs", each ordered by its newest song.
    private var groups: [SongGroup] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var list = library.songs
        if !q.isEmpty {
            list = list.filter { s in
                (s.title + " " + s.lyrics).lowercased().contains(q)
            }
        }
        list.sort { $0.updated > $1.updated }
        let pinned = list.filter { library.isPinned($0.id) }.sorted { (library.pins[$0.id] ?? 0) > (library.pins[$1.id] ?? 0) }
        var byFolder: [String: [Song]] = [:]
        for s in list where !library.isPinned(s.id) { byFolder[s.folder.isEmpty ? "Songs" : s.folder, default: []].append(s) }
        let folders = byFolder.keys.sorted { (byFolder[$0]?.first?.updated ?? 0) > (byFolder[$1]?.first?.updated ?? 0) }
        var out: [SongGroup] = []
        if !pinned.isEmpty { out.append(SongGroup(name: "Pinned", songs: pinned, pinned: true)) }
        out += folders.map { SongGroup(name: $0, songs: byFolder[$0]!) }
        return out
    }

    private func newSong() {
        Haptics.tap()
        let s = Song.new(artist: session.myName)
        library.add(s)
        path.append(s.id)
    }

    private func togglePin(_ s: Song) {
        Haptics.selection()
        withAnimation(.snappy) { library.setPin(s.id, !library.isPinned(s.id)) }
        session.toast = library.isPinned(s.id) ? "Pinned “\(s.displayTitle)”" : "Unpinned"
    }

    private func copyLyrics(_ s: Song) {
        UIPasteboard.general.string = (s.title.isEmpty ? "" : s.title + "\n\n") + s.lyrics
        Haptics.success()
        session.toast = "Lyrics copied"
    }
}

/// What a song carries while it's dragged onto a folder: its id, marked so other text isn't taken for a song.
enum SongDrag {
    static let prefix = "demo-song:"
    static func id(_ s: String?) -> String? {
        guard let s, s.hasPrefix(prefix) else { return nil }
        return String(s.dropFirst(prefix.count))
    }
}

struct SongRow: View {
    let song: Song
    /// the Pinned group shows each song's folder first
    var showFolder = false
    var body: some View {
        // the web's .song: 52pt cover, 17 semibold title, 15 line, 13 details
        HStack(spacing: 14) {
            CoverView(song: song, size: 52)
            VStack(alignment: .leading, spacing: 1) {
                Text(song.displayTitle).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                Text(song.previewLine).font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(1)
                if !meta.isEmpty { Text(meta).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1).padding(.top, 1) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    private var meta: String {
        [showFolder ? song.folder : "", song.isShared ? "Shared" : "", song.artist, song.status, song.key, song.bpm.isEmpty ? "" : song.bpm + " BPM", ShortDate.string(song.updated)]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The preview in a song's press-and-hold menu: its cover, title and opening lines.
struct SongPreview: View {
    let song: Song
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                CoverView(song: song, size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.displayTitle).font(.title3.bold()).lineLimit(2)
                    Text([song.isShared ? "Shared" : "", song.artist, song.status, ShortDate.string(song.updated)].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            let lines = song.lyrics.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            Text(lines.isEmpty ? "No lyrics yet" : lines.prefix(9).joined(separator: "\n"))
                .font(.body).foregroundStyle(lines.isEmpty ? .tertiary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(width: 340, alignment: .leading)
    }
}

/// The web's `fd`: a time for today, otherwise a short date.
enum ShortDate {
    static func string(_ ms: Double) -> String {
        guard ms > 0 else { return "" }
        let d = Date(timeIntervalSince1970: ms / 1000)
        if Calendar.current.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// The Account button: plan tag plus photo or person icon, in a glass capsule (top right).
struct AccountButton: View {
    @Environment(AppSession.self) private var session
    let action: () -> Void
    var body: some View {
        Button {
            Haptics.tap(); action()
        } label: {
            HStack(spacing: 6) {
                if session.plan.isPro {
                    Text(session.plan.tier == "pro" ? "Pro" : "Beta")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(session.plan.tier == "pro" ? Theme.proGreen : Color.primary.opacity(0.08), in: Capsule())
                        .foregroundStyle(session.plan.tier == "pro" ? Color.white : Color.primary)
                }
                Avatar(url: session.profile.avatar_url, name: session.myName, size: 28)
            }
            .padding(.leading, session.plan.isPro ? 8 : 6).padding(.trailing, 6)
            .frame(minWidth: 40, minHeight: 40)
            .contentShape(Capsule())
            .glassCapsule(interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Account")
    }
}

/// A profile photo (only a safe data URL or a known host, spec §5.4), or the person icon.
struct Avatar: View {
    let url: String?
    let name: String
    var size: CGFloat
    var body: some View {
        Group {
            if let u = url, u.hasPrefix("data:image/"), let img = CoverView.image(u) {
                Image(uiImage: img).resizable().scaledToFill()
            } else if let u = url, let url = URL(string: u), Avatar.trusted(url) {
                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { placeholder }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
    private var placeholder: some View {
        Icon("ic-person", size * 0.82).foregroundStyle(.primary).frame(width: size, height: size)
    }
    static func trusted(_ u: URL) -> Bool {
        guard u.scheme == "https", let h = u.host else { return false }
        return h.hasSuffix("googleusercontent.com") || h.hasSuffix("cygfgurzvmbtcegkpnss.supabase.co") || h.hasSuffix("apple.com")
    }
}


/// A screen title that stays put at the top while the list scrolls under it, fading the content
/// beneath it like the web app's header.
struct ListHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .center) {
            Text(title).font(.system(size: 34, weight: .bold)).tracking(-0.6).lineLimit(1)
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 20)
        // the web's .lhead: 28pt below the status bar
        .padding(.top, 28)
        .padding(.bottom, 14)
    }
}

/// The floating search bar with its round action button beside it (the web's bottom dock).
struct SearchDock: View {
    @Binding var text: String
    let prompt: String
    let icon: String
    let label: String
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Icon("ic-search", 18).foregroundStyle(.secondary)
                    TextField(prompt, text: $text)
                        .focused($focused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .onSubmit { focused = false }
                    if !text.isEmpty {
                        Button { text = ""; Haptics.tap() } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .font(.system(size: 17))
                .padding(.horizontal, 18)
                .frame(height: 52)
                .contentShape(Capsule())
                .onTapGesture { focused = true }
                .glassCapsule(interactive: true)

                Button {
                    Haptics.tap()
                    action()
                } label: {
                    Icon(icon, 24).foregroundStyle(.primary)
                        .frame(width: 52, height: 52)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassCircle()
                .accessibilityLabel(label)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }
}

/// The web's .fadeT / .fadeB: content blurs out as it passes under a floating bar, rather than
/// stopping at a solid strip. Reaches into the status bar / home indicator area.
struct EdgeFade: View {
    let edge: VerticalEdge
    var solidTo: CGFloat = 0.45

    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: solidTo), .init(color: .clear, location: 1)],
                               startPoint: edge == .top ? .top : .bottom, endPoint: edge == .top ? .bottom : .top)
            }
            .ignoresSafeArea(edges: edge == .top ? .top : .bottom)
            .allowsHitTesting(false)
    }
}
