import SwiftUI

/// Find Release: looks the song up in Apple Music's catalogue (supabase/functions/release-lookup) and fills in its
/// ISRC, UPC, release date, label and genre, plus the ISWC when MusicBrainz has one. Opens searching for the title
/// and artist.
struct FindReleaseSheet: View {
    let songID: String
    @Environment(\.appSession) private var session
    @Environment(\.library) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Hit] = []
    @State private var status: String?
    @State private var busy = false

    struct Hit: Identifiable { let id, title, artist, album, art, year: String }

    private static var storefront: String {
        let r = (Locale.current.region?.identifier ?? "AU").lowercased()
        return r.count == 2 ? r : "au"
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(results) { h in
                    Button { pick(h) } label: {
                        HStack(spacing: 12) {
                            AsyncImage(url: URL(string: h.art)) { $0.resizable().scaledToFill() } placeholder: { Color.primary.opacity(0.06) }
                                .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(h.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                                Text([h.artist, h.album, h.year].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                }
            }
            .listStyle(.plain)
            .overlay {
                if let status {
                    ContentUnavailableView { Label(status, systemImage: busy ? "magnifyingglass" : "music.note") }
                } else if results.isEmpty {
                    ContentUnavailableView("Find your release", systemImage: "music.note", description: Text("Search Apple Music, pick your song, and its details fill in."))
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !results.isEmpty {
                    Text("From Apple Music.").font(.footnote).foregroundStyle(.secondary).padding(.bottom, 8)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Song title and artist")
            .onSubmit(of: .search) { search() }
            .navigationTitle("Find Release")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear {
                guard query.isEmpty, let s = library.song(songID) else { return }
                query = [s.title, s.artist.isEmpty ? session.myName : s.artist].filter { !$0.isEmpty }.joined(separator: " ")
                search()
            }
        }
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return }
        busy = true; status = "Searching Apple Music…"; results = []
        Task {
            defer { busy = false }
            do {
                let r = try await Backend.function("release-lookup", body: ["action": "search", "q": .string(q), "storefront": .string(Self.storefront)])
                if let e = r["error"]?.string { status = e; return }
                results = (r["results"]?.array ?? []).compactMap { x in
                    guard let id = x["id"]?.string else { return nil }
                    return Hit(id: id, title: x["title"]?.string ?? "", artist: x["artist"]?.string ?? "", album: x["album"]?.string ?? "",
                               art: x["art"]?.string ?? "", year: String((x["date"]?.string ?? "").prefix(4)))
                }
                status = results.isEmpty ? "Nothing on Apple Music by that name. New releases can take a few days to appear." : nil
            } catch { status = describe(error) }
        }
    }

    private func pick(_ h: Hit) {
        busy = true; Haptics.tap()
        Task {
            defer { busy = false }
            do {
                let d = try await Backend.function("release-lookup", body: ["action": "detail", "id": .string(h.id), "storefront": .string(Self.storefront)])
                if let e = d["error"]?.string { session.toast = e; return }
                guard var s = library.song(songID) else { return }
                var got: [String] = []
                for (k, name) in [("isrc", "ISRC"), ("upc", "UPC"), ("date", "release date"), ("label", "label"), ("genre", "genre"), ("iswc", "ISWC")] {
                    guard var v = d[k]?.string, !v.isEmpty else { continue }
                    if k == "date" { v = String(v.prefix(10)) }
                    if k == "isrc" || k == "iswc" { v = v.uppercased() }
                    s.setRelease(k, .string(v)); got.append(name)
                }
                if let u = d["url"]?.string, !u.isEmpty { s.setRelease("appleMusic", .string(u)) }
                s.touch(); library.put(s)
                Haptics.success()
                session.toast = got.isEmpty ? "Apple Music had no details for that one"
                    : "Filled in " + (got.count > 1 ? got.dropLast().joined(separator: ", ") + " and " + got.last! : got[0])
                dismiss()
            } catch { session.toast = describe(error) }
        }
    }
}
