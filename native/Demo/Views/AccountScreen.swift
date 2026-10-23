import SwiftUI

struct AccountScreen: View {
    @Environment(AppSession.self) private var session
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Avatar(url: session.profile.avatar_url, name: session.myName, size: 60)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(session.myName.isEmpty ? "Your Name" : session.myName).font(.title3.bold())
                                if session.plan.tier == "pro" {
                                    Text("Pro").font(.caption2.weight(.bold)).padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(Theme.proGreen, in: Capsule()).foregroundStyle(.white)
                                }
                            }
                            if let u = session.profile.username, !u.isEmpty { Text("@" + u).foregroundStyle(.secondary) }
                            Text(session.email).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
                Section {
                    LabeledContent {
                        Text(session.plan.tier == "pro" ? "Active" : session.plan.tier == "beta" ? "Everything’s unlocked" : "Free")
                    } label: {
                        Label { Text(session.plan.tier == "beta" ? "*[demo] Beta" : "*[demo] Pro") } icon: { TileIcon("asterisk", Theme.Tile.purple) }
                    }
                }
                Section("Your songs") {
                    LabeledContent {
                        Text("\(library.songs.count)")
                    } label: { Label { Text("Songs") } icon: { TileIcon("music.note", Theme.Tile.indigo) } }
                    LabeledContent {
                        Text("\(library.ideas.count)")
                    } label: { Label { Text("Ideas") } icon: { TileIcon("lightbulb.fill", Theme.Tile.orange) } }
                    Button { Haptics.tap(); library.sync() } label: {
                        LabeledContent {
                            if library.syncing { ProgressView() } else { Text("Up to date").foregroundStyle(.secondary) }
                        } label: { Label { Text("Sync Now").foregroundStyle(.primary) } icon: { TileIcon("arrow.triangle.2.circlepath", Theme.Tile.blue) } }
                    }
                }
                Section("About") {
                    Link(destination: URL(string: "https://hellodemo.app/privacy.html")!) {
                        Label { Text("Privacy Policy").foregroundStyle(.primary) } icon: { TileIcon("hand.raised.fill", Theme.Tile.gray) }
                    }
                    Link(destination: URL(string: "https://hellodemo.app/terms.html")!) {
                        Label { Text("Terms of Use").foregroundStyle(.primary) } icon: { TileIcon("doc.text.fill", Theme.Tile.gray) }
                    }
                }
                Section {
                    Button("Sign Out", role: .destructive) { confirmSignOut = true }
                } footer: {
                    Text("*[demo] native · build \(Config.appSeq)").frame(maxWidth: .infinity).padding(.top, 8)
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    DoneButton { dismiss() }
                }
            }
            .confirmationDialog("Sign out of *[demo]?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { dismiss(); Task { await session.signOut() } }
            } message: { Text("Your songs stay in your account.") }
        }
        .task { await session.refreshPlan() }
    }
}

/// A Settings-style icon: a white symbol on a solid system-colour tile.
struct TileIcon: View {
    let name: String
    let color: Color
    init(_ name: String, _ color: Color) { self.name = name; self.color = color }
    var body: some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
