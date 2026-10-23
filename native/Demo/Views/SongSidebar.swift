import SwiftUI

extension EnvironmentValues {
    /// Opens a song (or Ideas) in place of the one showing, from the editor's sidebar.
    @Entry var openRoute: (String) -> Void = { _ in }
}

/// The web's phone sidebar: slides in from the left over a dimmed song, with Ideas, search and the song list.
struct SongSidebar: View {
    @Binding var isOpen: Bool
    let currentID: String
    @Environment(AppSession.self) private var session
    @Environment(LibraryStore.self) private var library
    @Environment(\.openRoute) private var openRoute
    @State private var query = ""
    @State private var drag: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let width = min(310, geo.size.width * 0.86)
            ZStack(alignment: .leading) {
                if isOpen {
                    Color.black.opacity(0.28 * Double(1 - min(1, -drag / width)))
                        .ignoresSafeArea()
                        .onTapGesture { close() }
                        .transition(.opacity)

                    panel
                        .frame(width: width)
                        .frame(maxHeight: .infinity)
                        .background(.regularMaterial)
                        .background(Color(uiColor: .systemBackground).opacity(0.55))
                        .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 28, topTrailingRadius: 28, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 24, x: 8)
                        .ignoresSafeArea(edges: .vertical)
                        .offset(x: min(0, drag))
                        .gesture(DragGesture(minimumDistance: 12)
                            .onChanged { v in drag = min(0, v.translation.width) }
                            .onEnded { v in
                                if v.translation.width < -width * 0.3 || v.predictedEndTranslation.width < -width * 0.6 { close() }
                                else { withAnimation(.snappy) { drag = 0 } }
                            })
                        .transition(.move(edge: .leading))
                }
            }
        }
        .animation(.snappy(duration: 0.32), value: isOpen)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("*[demo]").font(.system(size: 22, weight: .bold)).tracking(-0.4)
                Spacer()
                HStack(spacing: 0) {
                    Button { newSong() } label: {
                        Icon("ic-new", 21).foregroundStyle(Theme.tint).frame(width: 40, height: 40).contentShape(Rectangle())
                    }
                    .buttonStyle(PressScale()).accessibilityLabel("New song")
                    Button { close() } label: {
                        Icon("ic-sidebar", 21).foregroundStyle(Theme.tint).frame(width: 40, height: 40).contentShape(Rectangle())
                    }
                    .buttonStyle(PressScale()).accessibilityLabel("Hide sidebar")
                }
                .padding(.horizontal, 2)
                .glassCapsule(interactive: true)
            }
            .padding(.horizontal, 4)

            Button { go(IdeasRow.route) } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(LinearGradient(colors: [Color(hex: 0xFFD6A5), Color(hex: 0xEE8F82)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        Image(systemName: "lightbulb.fill").font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
                    }
                    .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Ideas").font(.system(size: 16, weight: .semibold))
                        Text("A quick jot for lines and ideas").font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if !library.ideas.isEmpty { Text("\(library.ideas.count)").font(.system(size: 13)).foregroundStyle(.secondary) }
                }
                .padding(8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Icon("ic-search", 16).foregroundStyle(.secondary)
                TextField("Search", text: $query).autocorrectionDisabled().font(.system(size: 16))
            }
            .padding(.horizontal, 12).frame(height: 38)
            .background(BarFill.color, in: Capsule())

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(songs) { s in
                        Button { go(s.id) } label: {
                            HStack(spacing: 12) {
                                CoverView(song: s, size: 44)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(s.displayTitle).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                                    Text(s.previewLine).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(8)
                            .background(s.id == currentID ? BarFill.color : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .padding(.horizontal, 12)
        .safeAreaPadding(.top, 14)
        .safeAreaPadding(.bottom, 12)
    }

    private var songs: [Song] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = library.songs.filter { q.isEmpty || [$0.title, $0.lyrics, $0.artist, $0.folder].contains { $0.lowercased().contains(q) } }
        let pinned = list.filter { library.isPinned($0.id) }.sorted { (library.pins[$0.id] ?? 0) > (library.pins[$1.id] ?? 0) }
        return pinned + list.filter { !library.isPinned($0.id) }.sorted { $0.updated > $1.updated }
    }

    private func close() {
        Haptics.tap()
        withAnimation(.snappy(duration: 0.3)) { isOpen = false; drag = 0 }
    }

    private func go(_ id: String) {
        Haptics.tap()
        withAnimation(.snappy(duration: 0.3)) { isOpen = false; drag = 0 }
        if id != currentID { openRoute(id) }
    }

    private func newSong() {
        let s = Song.new(artist: session.myName)
        library.add(s)
        go(s.id)
    }
}
