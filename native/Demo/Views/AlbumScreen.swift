import SwiftUI
import PhotosUI

// MARK: - look

/// An album's colours: the share page's background (shBg), the artwork's main colour washing diagonally into
/// the next with a glow of a third, and words in a deep shade of the main colour rather than plain black.
struct AlbumLook {
    let bg: SharePalette.Background

    init(_ a: Album) {
        var pal: [HSL] = []
        if let art = a.artDataURL, let img = CoverView.image(art) { pal = SharePalette.fromArt(img) }
        if pal.isEmpty { pal = CoverPick(id: a.id).hexes.map(SharePalette.hex) }
        bg = SharePalette.background(pal, 0)
    }

    /// The words (the Read Lyrics button is filled with it).
    var ink: Color { SharePalette.color(bg.ink) }

    var background: some View {
        GeometryReader { g in
            ZStack {
                LinearGradient(colors: [SharePalette.color(bg.top), SharePalette.color(bg.bot)], startPoint: UnitPoint(x: 0.25, y: 0), endPoint: UnitPoint(x: 0.75, y: 1))
                RadialGradient(colors: [SharePalette.color(bg.glow), SharePalette.color(bg.glow).opacity(0)], center: UnitPoint(x: 0.88, y: 0.04), startRadius: 0, endRadius: g.size.width * 0.72)
            }
        }
        .ignoresSafeArea()
    }
}

/// A song's progress as a small coloured tag: Idea, Draft, Demo, Finished.
struct StatusTag: View {
    let status: String
    var body: some View {
        let c = colours
        Text(status.isEmpty ? "Idea" : status)
            .font(.system(size: 11.5, weight: .semibold))
            .padding(.horizontal, 9).padding(.vertical, 3)
            .foregroundStyle(c.ink)
            .background(c.fill, in: Capsule())
    }
    private var colours: (fill: Color, ink: Color) {
        switch status {
        case "Finished": return (Color(hex: 0x34C759).opacity(0.2), Color(hex: 0x1F7A36))
        case "Demo": return (Color(hex: 0x007AFF).opacity(0.15), Color(hex: 0x0A5AC4))
        case "Draft": return (Color(hex: 0xFF9500).opacity(0.2), Color(hex: 0xA35500))
        default: return (Color.black.opacity(0.07), Color(hex: 0x5E5E63))
        }
    }
}

/// The album's artwork, or (with none) a cover drawn from its id like the songs' generated ones.
struct AlbumArt: View {
    let album: Album
    var size: CGFloat
    var radius: CGFloat = 10
    var body: some View {
        Group {
            if let a = album.artDataURL, let img = CoverView.image(a) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                let k = CoverPick(id: album.id)
                ZStack {
                    LinearGradient(colors: [k.a, k.b], startPoint: .topLeading, endPoint: .bottomTrailing)
                    RadialGradient(colors: [k.glow.opacity(0.8), k.glow.opacity(0)], center: UnitPoint(x: k.cx, y: k.cy), startRadius: 0, endRadius: size * 0.8)
                    Image(systemName: "music.note.list").font(.system(size: size * 0.26, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Color.black.opacity(0.08), lineWidth: 0.5))
    }
}

enum AlbumRoute {
    static let prefix = "album:"
    static func id(_ route: String) -> String? { route.hasPrefix(prefix) ? String(route.dropFirst(prefix.count)) : nil }
}

/// Free has one album; Pro as many as you like. Opens the paywall when that's the stop.
@MainActor func canMakeAlbum(_ session: AppSession, _ library: LibraryStore) -> Bool {
    if session.plan.isPro || library.liveAlbums.isEmpty { return true }
    Haptics.warning()
    session.paywallWhy = "albums"
    return false
}

// MARK: - the shelf in the song list

/// Albums along the top of the song list: artwork tiles that scroll sideways, like Apple Music.
struct AlbumShelf: View {
    @Environment(\.library) private var library
    let newAlbum: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Albums").font(.system(size: 20, weight: .bold)).padding(.horizontal, 24).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(albums) { a in
                        NavigationLink(value: AlbumRoute.prefix + a.id) {
                            VStack(alignment: .leading, spacing: 2) {
                                AlbumArt(album: a, size: 148, radius: 10).shadow(color: .black.opacity(0.08), radius: 6, y: 3).padding(.bottom, 6)
                                Text(a.displayTitle).font(.system(size: 15, weight: .medium)).lineLimit(1)
                                let n = library.albumSongs( a.id).count
                                Text("\(a.kind) · \(n) \(n == 1 ? "song" : "songs")").font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(width: 148, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressScale())
                    }
                    Button(action: newAlbum) {
                        VStack(alignment: .leading, spacing: 2) {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05))
                                .frame(width: 148, height: 148)
                                .overlay(Image(systemName: "plus").font(.system(size: 30, weight: .regular)).foregroundStyle(.secondary))
                                .padding(.bottom, 6)
                            Text("New Album").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(PressScale())
                }
                .padding(.horizontal, 24)
            }
        }
        .padding(.top, 18).padding(.bottom, 4)
    }

    /// Newest change first: the album itself or any of its songs.
    private var albums: [Album] {
        library.liveAlbums.sorted { latest($0) > latest($1) }
    }
    private func latest(_ a: Album) -> Double { max(a.updated, library.albumSongs( a.id).map(\.updated).max() ?? 0) }
}

// MARK: - the album page

/// Laid out like an album in Apple Music, on the share page's colours: the square artwork, title, artist,
/// the main button between two round ones, then the tracklist.
struct AlbumScreen: View {
    let albumID: String
    @Environment(\.appSession) private var session
    @Environment(\.library) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.pushRoute) private var pushRoute
    @State private var editing = false
    @State private var adding = false
    @State private var reading = false
    @State private var confirmDelete = false

    var body: some View {
        if let a = library.album(albumID) {
            page(a)
        } else {
            Color.clear.onAppear { dismiss() }   // deleted (here or on another device)
        }
    }

    private func page(_ a: Album) -> some View {
        let look = AlbumLook(a)
        let tracks = library.albumSongs(a.id)
        return List {
            header(a, tracks, look)
                .listRowSeparator(.hidden).listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                .moveDisabled(true)
            if tracks.isEmpty {
                VStack(spacing: 6) {
                    Text("No songs yet").font(.system(size: 17, weight: .semibold))
                    Text("Write a new one, or add songs you’ve already started.").font(.system(size: 15)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 30)
                .listRowSeparator(.hidden).listRowBackground(Color.clear)
                .moveDisabled(true)
            }
            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, s in
                trackRow(i, s, tracks)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 14))
                    .overlay(alignment: .top) {
                        Rectangle().fill(.quaternary).frame(height: 0.5).padding(.leading, i == 0 ? 0 : 36)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { remove(s) } label: { Label("Remove", systemImage: "minus.circle") }.tint(.red)
                    }
            }
            .onMove { from, to in
                var ids = tracks.map(\.id)
                ids.move(fromOffsets: from, toOffset: to)
                Haptics.selection()
                library.reorderAlbum(ids)
            }
            if !tracks.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle().fill(.quaternary).frame(height: 0.5)
                    Text(footer(a, tracks)).font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 12)
                }
                .padding(.bottom, 40)
                .listRowSeparator(.hidden).listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 0))
                .moveDisabled(true)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(look.background)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) { topBar(a, tracks) }
        .foregroundStyle(look.ink)
        // the colours are pastel in dark mode too (like the share page), so glass and menus take their light look
        .environment(\.colorScheme, .light)
        .sheet(isPresented: $editing) { AlbumEditSheet(album: a) }
        .sheet(isPresented: $adding) { AddSongsSheet(albumID: a.id) }
        .fullScreenCover(isPresented: $reading) { AlbumReader(album: a, look: look) }
        .confirmDestroy("Delete “\(a.displayTitle)”?", isPresented: $confirmDelete,
                        message: "Its songs stay in your library.", action: "Delete \(a.kind)") {
            Haptics.success()
            library.deleteAlbum(a.id)
            session.toast = "Deleted “\(a.displayTitle)”"
        }
    }

    private func topBar(_ a: Album, _ tracks: [Song]) -> some View {
        GlassGroup(spacing: 10) {
            HStack {
                Button { Haptics.tap(); dismiss() } label: {
                    Icon("ic-back", 22).foregroundStyle(.primary).frame(width: 48, height: 48).contentShape(Circle())
                }
                .buttonStyle(PressScale())
                .glassCircle()
                .accessibilityLabel("Songs")
                Spacer()
                HStack(spacing: 4) {
                    ShareLink(item: tracklist(a, tracks)) {
                        Icon("ic-share", 21).foregroundStyle(.primary).frame(width: 48, height: 48).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Share tracklist")
                    Menu {
                        Button { Haptics.tap(); editing = true } label: { Label("Edit \(a.kind)", systemImage: "pencil") }
                        Button { Haptics.tap(); adding = true } label: { Label("Add Songs", systemImage: "plus") }
                        Section {
                            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete \(a.kind)", systemImage: "trash") }
                        }
                    } label: {
                        Icon("ic-more", 21).foregroundStyle(.primary).frame(width: 48, height: 48).contentShape(Rectangle())
                    }
                    .accessibilityLabel("More")
                }
                .padding(.horizontal, 6)
                .glassCapsule(interactive: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4).padding(.bottom, 6)
    }

    private func header(_ a: Album, _ tracks: [Song], _ look: AlbumLook) -> some View {
        let fin = tracks.filter(\.isFinished).count
        let artist = a.artist.trimmingCharacters(in: .whitespaces).isEmpty ? session.myName : a.artist
        return VStack(spacing: 0) {
            Button { Haptics.tap(); editing = true } label: {
                AlbumArt(album: a, size: 264, radius: 10)
                    .shadow(color: .black.opacity(0.28), radius: 20, y: 10)
            }
            .buttonStyle(PressScale())
            .accessibilityLabel("Edit artwork")
            .padding(.top, 10)
            Text(a.displayTitle).font(.system(size: 23, weight: .bold)).tracking(-0.4).multilineTextAlignment(.center).padding(.top, 24)
            if !artist.isEmpty {
                Text(artist).font(.system(size: 21)).tracking(-0.3).foregroundStyle(.primary).lineLimit(1).padding(.top, 2)
            }
            Text([a.kind, a.year, tracks.isEmpty ? "" : "\(fin) of \(tracks.count) finished"].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 6)
            // Apple Music's Shuffle · Play · Add, here Add Songs · Read Lyrics · New Song
            GlassGroup(spacing: 14) {
                HStack(spacing: 16) {
                    round("plus", "Add Songs") { adding = true }
                    Button { Haptics.tap(); reading = true } label: {
                        Label("Read Lyrics", systemImage: "book.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(look.ink)
                            .frame(width: 176, height: 52)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressScale())
                    .glassCapsule(interactive: true)
                    .disabled(tracks.isEmpty).opacity(tracks.isEmpty ? 0.55 : 1)
                    round("square.and.pencil", "New Song") { newSong(a) }
                }
            }
            .padding(.top, 20).padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity)
    }

    private func round(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button { Haptics.tap(); action() } label: {
            Image(systemName: icon).font(.system(size: 19, weight: .semibold)).foregroundStyle(.primary)
                .frame(width: 52, height: 52).contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .glassCircle()
        .accessibilityLabel(label)
    }

    private func trackRow(_ i: Int, _ s: Song, _ tracks: [Song]) -> some View {
        HStack(spacing: 12) {
            Button { Haptics.tap(); pushRoute(s.id) } label: {
                HStack(spacing: 14) {
                    Text("\(i + 1)").font(.system(size: 16)).monospacedDigit().foregroundStyle(.secondary).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.displayTitle).font(.system(size: 17)).foregroundStyle(.primary).lineLimit(1)
                        Text(s.previewLine).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    StatusTag(status: s.status)
                }
                .frame(minHeight: 64)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Menu {
                if i > 0 { Button { move(tracks, i, -1) } label: { Label("Move Up", systemImage: "arrow.up") } }
                if i < tracks.count - 1 { Button { move(tracks, i, 1) } label: { Label("Move Down", systemImage: "arrow.down") } }
                Section {
                    Button(role: .destructive) { remove(s) } label: { Label("Remove from Album", systemImage: "minus.circle") }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
                    .frame(width: 34, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Song options")
        }
    }

    private func move(_ tracks: [Song], _ i: Int, _ d: Int) {
        var ids = tracks.map(\.id)
        ids.swapAt(i, i + d)
        Haptics.selection()
        withAnimation(.snappy) { library.reorderAlbum(ids) }
    }

    private func remove(_ s: Song) {
        Haptics.tap()
        withAnimation(.snappy) { library.setAlbum([s.id], to: "") }
        session.toast = "Removed “\(s.displayTitle)”"
    }

    private func newSong(_ a: Album) {
        var s = Song.new(artist: session.myName)
        s.albumID = a.id
        s.track = (library.albumSongs(a.id).map(\.track).max() ?? 0) + 1
        library.add(s)
        pushRoute(s.id)
    }

    private func footer(_ a: Album, _ tracks: [Song]) -> String {
        let lines = tracks.reduce(0) { $0 + $1.lyricLines.count }
        let last = max(a.updated, tracks.map(\.updated).max() ?? 0)
        let ago = RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: last / 1000), relativeTo: Date())
        return "\(tracks.count) \(tracks.count == 1 ? "song" : "songs"), \(lines) \(lines == 1 ? "line" : "lines") · Edited \(ago)"
    }

    private func tracklist(_ a: Album, _ tracks: [Song]) -> String {
        ([a.displayTitle, [a.kind, a.year].filter { !$0.isEmpty }.joined(separator: " · "), ""]
            + tracks.enumerated().map { "\($0.offset + 1). \($0.element.displayTitle)" }).joined(separator: "\n")
    }
}

// MARK: - Read Lyrics

/// Every song's words in track order, big and bold on the album's colour, like lyrics in Apple Music.
struct AlbumReader: View {
    let album: Album
    let look: AlbumLook
    @Environment(\.library) private var library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    AlbumArt(album: album, size: 56, radius: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(album.displayTitle).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                        Text([album.kind, album.year].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 24)
                ForEach(Array(library.albumSongs(album.id).enumerated()), id: \.element.id) { i, s in
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(i + 1)").font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
                        Text(s.displayTitle).font(.system(size: 30, weight: .bold)).tracking(-0.5).padding(.top, 2).padding(.bottom, 14)
                        lyrics(s)
                    }
                    .padding(.vertical, 24)
                    .overlay(alignment: .top) { if i > 0 { Rectangle().fill(.quaternary).frame(height: 0.5) } }
                }
            }
            .foregroundStyle(look.ink)
            .padding(.horizontal, 26)
            .padding(.top, 8).padding(.bottom, 60)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(look.background)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Spacer()
                Button { Haptics.tap(); dismiss() } label: {
                    Icon("ic-close", 20).foregroundStyle(.primary).frame(width: 46, height: 46).contentShape(Circle())
                }
                .buttonStyle(PressScale())
                .glassCircle()
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 16).padding(.top, 4)
        }
        .foregroundStyle(look.ink)
        .environment(\.colorScheme, .light)
    }

    /// [Section] lines as small headings, blank lines as gaps.
    @ViewBuilder private func lyrics(_ s: Song) -> some View {
        let raw = s.lyrics.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if raw.allSatisfy(\.isEmpty) {
            Text("No lyrics yet").font(.system(size: 22, weight: .semibold)).foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(raw.enumerated()), id: \.offset) { _, l in
                    if l.isEmpty {
                        Color.clear.frame(height: 18)
                    } else if l.hasPrefix("[") && l.hasSuffix("]") {
                        Text(l.dropFirst().dropLast().uppercased()).font(.system(size: 12, weight: .semibold)).tracking(0.8)
                            .foregroundStyle(.secondary).padding(.top, 8).padding(.bottom, 4)
                    } else {
                        Text(l).font(.system(size: 22, weight: .semibold)).lineSpacing(4).foregroundStyle(.primary).padding(.vertical, 3)
                    }
                }
            }
            .textSelection(.enabled)
        }
    }
}

// MARK: - new / edit

/// The album's artwork, name, kind, year and artist. With `album` nil it makes a new one (holding `adding` songs).
struct AlbumEditSheet: View {
    var album: Album?
    var adding: [String] = []
    /// Runs with the saved album's id (a new album opens straight away from the song list).
    var onSave: ((String) -> Void)? = nil
    @Environment(\.appSession) private var session
    @Environment(\.library) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var draft = Album.new(artist: "")
    @State private var pick = false
    @State private var item: PhotosPickerItem?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { Haptics.tap(); pick = true } label: {
                        VStack(spacing: 10) {
                            AlbumArt(album: draft, size: 168, radius: 12).shadow(color: .black.opacity(0.15), radius: 12, y: 6)
                            Text(draft.artDataURL == nil ? "Add Artwork" : "Change Artwork").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.tint)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("Title", text: Binding(get: { draft.title }, set: { draft.title = $0 }))
                        .font(.system(size: 17, weight: .semibold))
                    Picker("Kind", selection: Binding(get: { draft.kind }, set: { draft.kind = $0 })) {
                        ForEach(Album.kinds, id: \.self) { Text($0) }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Year") {
                        TextField("Year", text: Binding(get: { draft.year }, set: { draft.year = String($0.filter(\.isNumber).prefix(4)) }))
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Artist") {
                        TextField(session.myName.isEmpty ? "Artist" : session.myName, text: Binding(get: { draft.artist }, set: { draft.artist = $0 }))
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .navigationTitle(album == nil ? "New Album" : "Edit \(draft.kind)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(album == nil ? "Create" : "Save") { save() }.fontWeight(.semibold) }
            }
            .photosPicker(isPresented: $pick, selection: $item, matching: .images)
            .onChange(of: item) { _, i in if let i { loadArt(i) } }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                if let album { draft = album }
            }
        }
    }

    private func save() {
        var a = draft
        a.title = a.title.trimmingCharacters(in: .whitespaces)
        a.artist = a.artist.trimmingCharacters(in: .whitespaces)
        if let album, album.raw == a.raw { dismiss(); return }
        a.touch()
        library.putAlbum(a)
        if album == nil && !adding.isEmpty { library.setAlbum(adding, to: a.id) }
        Haptics.success()
        if album == nil { session.toast = adding.isEmpty ? "Made “\(a.displayTitle)”" : "Added to “\(a.displayTitle)”" }
        dismiss()
        onSave?(a.id)
    }

    /// Centre-cropped to a 480 × 480 JPEG at 0.8, the same as a song's cover.
    private func loadArt(_ i: PhotosPickerItem) {
        Task {
            defer { item = nil }
            guard let data = try? await i.loadTransferable(type: Data.self), let img = UIImage(data: data) else {
                session.toast = "Could not read that image"; return
            }
            let side: CGFloat = 480
            let w = img.size.width, h = img.size.height, m = min(w, h)
            let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = 1
            let out = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt).image { _ in
                let scale = side / m
                img.draw(in: CGRect(x: -(w - m) / 2 * scale, y: -(h - m) / 2 * scale, width: w * scale, height: h * scale))
            }
            guard let jpg = out.jpegData(compressionQuality: 0.8) else { session.toast = "Could not read that image"; return }
            draft.setArt("data:image/jpeg;base64," + jpg.base64EncodedString())
            Haptics.success()
        }
    }
}

/// Your songs not in this album yet, to tick and add at the end.
struct AddSongsSheet: View {
    let albumID: String
    var accent: Color = Theme.tint
    @Environment(\.appSession) private var session
    @Environment(\.library) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var picked: [String] = []
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(candidates) { s in
                Button {
                    Haptics.selection()
                    if let i = picked.firstIndex(of: s.id) { picked.remove(at: i) } else { picked.append(s.id) }
                } label: {
                    HStack(spacing: 14) {
                        CoverView(song: s, size: 44)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.displayTitle).font(.system(size: 16, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                            Text([library.album(s.albumID)?.displayTitle ?? "", s.previewLine].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: picked.contains(s.id) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22)).foregroundStyle(picked.contains(s.id) ? accent : Color(uiColor: .tertiaryLabel))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .overlay { if candidates.isEmpty { ContentUnavailableView(query.isEmpty ? "No other songs" : "No Results", systemImage: "music.note") } }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Add Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(picked.isEmpty ? "Add" : "Add \(picked.count)") {
                        library.setAlbum(picked, to: albumID)
                        Haptics.success()
                        dismiss()
                    }
                    .fontWeight(.semibold).disabled(picked.isEmpty)
                }
            }
        }
    }

    private var candidates: [Song] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return library.songs
            .filter { $0.albumID != albumID && Self.canJoin($0, session) }
            .filter { q.isEmpty || ($0.title + " " + $0.lyrics).lowercased().contains(q) }
            .sorted { $0.updated > $1.updated }
    }

    /// Only your own songs go in albums (not co-writes someone else owns, the guide, or empty folders).
    @MainActor static func canJoin(_ s: Song, _ session: AppSession) -> Bool {
        !s.isPlaceholder && !s.isGuide && (!s.isShared || s.owner.isEmpty || s.owner == session.userID)
    }
}
