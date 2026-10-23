import SwiftUI
import UIKit

/// The song list: Pinned first, then folders and Songs, each group ordered by its newest song
/// (spec §1.6), with search, swipe actions and press-and-hold menus.
struct SongListScreen: View {
    @Environment(AppSession.self) private var session
    @Environment(LibraryStore.self) private var library
    @State private var path: [String] = []
    @State private var query = ""
    @State private var showAccount = false
    @State private var confirmDelete: Song?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if query.isEmpty {
                    IdeasRow()
                }
                ForEach(groups, id: \.name) { g in
                    Section {
                        // the folder name is a plain row, not a section header, so it scrolls away
                        // with its songs instead of pinning under the title
                        if !g.name.isEmpty {
                            Text(g.name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 14)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 2, trailing: 20))
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(g.songs) { s in
                            NavigationLink(value: s.id) { SongRow(song: s) }
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
                if !query.isEmpty && groups.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
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

    struct SongGroup { let name: String; let songs: [Song] }

    /// Pinned (newest pin first), then folders and "Songs", each ordered by its newest song.
    private var groups: [SongGroup] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var list = library.songs
        if !q.isEmpty {
            list = list.filter { s in
                [s.title, s.lyrics, s.artist, s.folder].contains { $0.lowercased().contains(q) }
            }
        }
        list.sort { $0.updated > $1.updated }
        let pinned = list.filter { library.isPinned($0.id) }.sorted { (library.pins[$0.id] ?? 0) > (library.pins[$1.id] ?? 0) }
        var byFolder: [String: [Song]] = [:]
        for s in list where !library.isPinned(s.id) { byFolder[s.folder.isEmpty ? "Songs" : s.folder, default: []].append(s) }
        let folders = byFolder.keys.sorted { (byFolder[$0]?.first?.updated ?? 0) > (byFolder[$1]?.first?.updated ?? 0) }
        var out: [SongGroup] = []
        if !pinned.isEmpty { out.append(SongGroup(name: "Pinned", songs: pinned)) }
        out += folders.map { SongGroup(name: $0, songs: byFolder[$0]!) }
        // with nothing else to group, the songs don't need a header
        if out.count == 1 && out[0].name == "Songs" { return [SongGroup(name: "", songs: out[0].songs)] }
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

struct SongRow: View {
    let song: Song
    var body: some View {
        HStack(spacing: 14) {
            CoverView(song: song, size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.displayTitle).font(.headline).lineLimit(1)
                Text(song.previewLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if !meta.isEmpty { Text(meta).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
            }
        }
        .padding(.vertical, 4)
    }

    private var meta: String {
        [song.isShared ? "Shared" : "", song.artist, song.status, song.key, song.bpm.isEmpty ? "" : song.bpm + " BPM", ShortDate.string(song.updated)]
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
        .padding(.top, 6)
        .padding(.bottom, 14)
        .background {
            LinearGradient(stops: [.init(color: Color(uiColor: .systemBackground), location: 0),
                                   .init(color: Color(uiColor: .systemBackground), location: 0.55),
                                   .init(color: Color(uiColor: .systemBackground).opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
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
