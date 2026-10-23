import SwiftUI

/// Details › Info › Collaborators (spec §4.12).
struct CollabSection: View {
    let songID: String
    var onLeft: () -> Void
    @Environment(AppSession.self) private var session
    @Environment(LibraryStore.self) private var library
    @State private var people: [Collab.Person] = []
    @State private var invite = ""
    @State private var suggestions: [Collab.Person] = []
    @State private var sending = false
    @State private var note: String?
    @State private var armed: String?
    @State private var confirmStop = false
    @State private var confirmLeave = false

    private var song: Song? { library.song(songID) }
    private var isOwner: Bool { guard let s = song else { return false }; return s.owner.isEmpty || s.owner == session.userID }

    var body: some View {
        if let s = song {
            if !s.isShared { notShared } else { shared(s) }
        }
    }

    // MARK: not shared yet

    private var notShared: some View {
        Section("Collaborators") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: -8) {
                    Avatar(url: session.profile.avatar_url, name: session.myName, size: 34)
                        .overlay(Circle().stroke(Color(uiColor: .secondarySystemGroupedBackground), lineWidth: 2))
                    Image(systemName: "plus").font(.system(size: 14, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 34, height: 34).background(BarFill.color, in: Circle())
                        .overlay(Circle().stroke(Color(uiColor: .secondarySystemGroupedBackground), lineWidth: 2))
                }
                Text("Write this one together").font(.headline)
                Text(session.userID == nil ? "Sign in to write with other people." : "Invite co-writers by username and write it together, live.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button {
                    guard session.plan.isPro else { session.upsell("share"); return }
                    Task { _ = await Collab.shared.share(songID); await load(); await Push.shared.ask() }
                } label: {
                    HStack(spacing: 6) {
                        Text("Share Song").font(.system(size: 15, weight: .semibold))
                        if !session.plan.isPro {
                            Text("Pro").font(.system(size: 10, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.proGreen, in: Capsule()).foregroundStyle(.white)
                        }
                    }
                    .foregroundStyle(Theme.onTint).padding(.horizontal, 16).frame(height: 38).background(Theme.tint, in: Capsule())
                }
                .buttonStyle(PressScale())
                .disabled(session.userID == nil)
            }
            .padding(.vertical, 6)
        }
    }

    // MARK: shared

    @ViewBuilder private func shared(_ s: Song) -> some View {
        Section {
            if isOwner {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("@").foregroundStyle(.secondary)
                        TextField("Invite by username", text: $invite)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .submitLabel(.send).onSubmit { send() }
                        Button("Invite") { send() }
                            .font(.subheadline.weight(.semibold))
                            .disabled(invite.trimmingCharacters(in: .whitespaces).isEmpty || sending)
                    }
                    if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
                    ForEach(suggestions) { p in
                        Button { invite = p.username; send() } label: {
                            HStack(spacing: 10) {
                                Avatar(url: p.avatar, name: p.name, size: 30)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(p.name).foregroundStyle(.primary)
                                    Text("@" + p.username).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(badge(for: p)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .task(id: invite) {
                    try? await Task.sleep(for: .milliseconds(250))
                    suggestions = await Collab.shared.suggest(invite)
                }
            }
            ForEach(people) { p in
                HStack(spacing: 12) {
                    Avatar(url: p.avatar, name: p.name, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name + (p.isMe ? " (you)" : ""))
                        Text(p.role == "invited" ? "Hasn’t accepted yet" : (p.username.isEmpty ? "" : "@" + p.username))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isOwner && !p.isMe {
                        Button(armed == p.id ? "Remove?" : "Remove", role: .destructive) {
                            if armed == p.id { Task { await Collab.shared.remove(p, from: songID); armed = nil; await load() } }
                            else { Haptics.selection(); armed = p.id }
                        }
                        .font(.subheadline).buttonStyle(.borderless)
                    } else {
                        Text(p.role == "owner" ? "Owner" : p.role == "invited" ? "Invited" : "Co-writer")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
            }
            if isOwner && people.count <= 1 {
                Text("No one else yet. Invite a co-writer above.").font(.subheadline).foregroundStyle(.secondary)
            }
            if isOwner {
                Button("Stop Sharing", role: .destructive) { confirmStop = true }
            } else {
                Button("Leave Song", role: .destructive) { confirmLeave = true }
            }
        } header: { Text("Collaborators") } footer: {
            Text(isOwner ? "Co-writers need *[demo] and a username." : "Leaving removes the song from your library.")
        }
        .task(id: s.id) { await load() }
        .confirmationDialog("Stop sharing “\(s.displayTitle)”?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop Sharing", role: .destructive) { Task { await Collab.shared.stopSharing(songID); people = [] } }
        } message: { Text("Your co-writers lose access. The song stays with you.") }
        .confirmationDialog("Leave “\(s.displayTitle)”?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave Song", role: .destructive) {
                onLeft()
                Task { await session.removeSong(s); session.toast = "You left the song" }
            }
        } message: { Text("It’s removed from your devices. The owner can invite you again.") }
    }

    private func badge(for p: Collab.Person) -> String {
        if let x = people.first(where: { $0.id == p.id }) { return x.role == "invited" ? "Invited" : "On song" }
        return "Invite"
    }

    private func load() async { people = await Collab.shared.people(song ?? Song(raw: [:])) }

    private func send() {
        let v = invite.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, !sending else { note = "Enter a username"; return }
        sending = true
        Task {
            let err = await Collab.shared.invite(v, to: songID)
            sending = false
            if let err { note = err; Haptics.warning() }
            else {
                note = nil
                Haptics.success()
                session.toast = "Invited @" + v.replacingOccurrences(of: "@", with: "").lowercased()
                invite = ""; suggestions = []
                await load()
            }
        }
    }
}

/// The invite banner (spec §3.8): "X invited you to write “T” together" with Accept / Not now, 20 s.
struct InviteBanner: View {
    @State private var collab = Collab.shared

    var body: some View {
        if let inv = collab.banner {
            HStack(spacing: 12) {
                Avatar(url: inv.avatar, name: inv.ownerName, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(inv.ownerName) invited you to write “\(inv.title)” together").font(.subheadline.weight(.semibold)).lineLimit(3)
                    HStack(spacing: 8) {
                        Button("Accept") { Task { await collab.accept(inv); await Push.shared.ask() } }
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.onTint)
                            .padding(.horizontal, 14).frame(height: 32).background(Theme.tint, in: Capsule())
                        Button("Not now") { withAnimation { collab.banner = nil } }
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.tint)
                            .padding(.horizontal, 14).frame(height: 32).background(BarFill.color, in: Capsule())
                    }
                    .buttonStyle(PressScale())
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .glass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, 12)
            .hudHit("invite")
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: inv.id) {
                try? await Task.sleep(for: .seconds(20))
                if collab.banner?.id == inv.id { withAnimation { collab.banner = nil } }
            }
        }
    }
}
