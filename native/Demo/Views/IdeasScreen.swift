import SwiftUI

/// The Ideas row at the top of the song list.
struct IdeasRow: View {
    static let route = "__ideas__"
    @Environment(LibraryStore.self) private var library

    var body: some View {
        NavigationLink(value: Self.route) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14.5, style: .continuous)
                        .fill(LinearGradient(colors: [Color(hex: 0xFFD6A5), Color(hex: 0xEE8F82)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "lightbulb.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                }
                .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ideas").font(.headline)
                    Text(latest?.text.components(separatedBy: "\n").first ?? "A quick jot for lines, ideas and concepts")
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Text(library.ideas.isEmpty ? "Tap to jot one" : "\(library.ideas.count) \(library.ideas.count == 1 ? "idea" : "ideas") · \(ShortDate.string(latest?.updated ?? 0))")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var latest: Idea? { library.ideas.max { $0.updated < $1.updated } }
}

struct IdeasScreen: View {
    @Environment(LibraryStore.self) private var library
    @State private var jot = ""
    @State private var query = ""
    @State private var editing: Idea?
    @FocusState private var jotFocused: Bool

    var body: some View {
        List {
            Section {
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("A line, a title, an idea…", text: $jot, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($jotFocused)
                        .submitLabel(.done)
                        .onSubmit(save)
                    Button(action: save) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 28))
                    }
                    .disabled(jot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Save idea")
                }
            }
            Section {
                ForEach(filtered) { i in
                    Button { editing = i } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(i.text.isEmpty ? (i.hasMemo ? "Voice memo" : "Empty idea") : i.text)
                                .foregroundStyle(.primary).lineLimit(4)
                            Text(ShortDate.string(i.updated)).font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            Haptics.thud()
                            withAnimation { library.deleteIdea(i.id) }
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
        }
        .navigationTitle("Ideas")
        .searchable(text: $query, prompt: "Search ideas")
        .sheet(item: $editing) { i in IdeaSheet(idea: i) }
    }

    private var filtered: [Idea] {
        let q = query.lowercased()
        return library.ideas.filter { q.isEmpty || $0.text.lowercased().contains(q) }.sorted { $0.updated > $1.updated }
    }

    private func save() {
        let t = jot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        Haptics.tap()
        withAnimation(.snappy) { library.putIdea(Idea.new(text: t)) }
        jot = ""
        jotFocused = false
    }
}

struct IdeaSheet: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    let idea: Idea
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("A line, a title, an idea…", text: $text, axis: .vertical).lineLimit(3...20)
            }
            .navigationTitle("Idea")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    DoneButton { commit(); dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .fraction(0.84)])
        .onAppear { text = idea.text; library.ideaEditingID = idea.id }
        .onDisappear { commit(); library.ideaEditingID = nil }
    }

    private func commit() {
        guard var i = library.ideas.first(where: { $0.id == idea.id }), i.text != text else { return }
        i.text = text
        // a memo with a caption is a line; clearing the caption makes it a memo again
        if i.hasMemo { i.raw["kind"] = .string(text.isEmpty ? "memo" : "line") }
        i.updated = Clock.nowMs
        library.putIdea(i)
    }
}
