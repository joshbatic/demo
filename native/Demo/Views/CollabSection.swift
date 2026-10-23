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
                // the web's .clinv: "@", the field and a filled Invite pill
                HStack(spacing: 8) {
                    Text("@").font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary)
                    TextField("Invite by username", text: $invite)
                        .font(.system(size: 16.5))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.send).onSubmit { send() }
                    let empty = invite.trimmingCharacters(in: .whitespaces).isEmpty
                    Button { send() } label: {
                        Text("Invite").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.onTint)
                            .padding(.horizontal, 16).frame(height: 34).background(Theme.tint, in: Capsule())
                    }
                    .buttonStyle(.borderless)
                    .opacity(empty || sending ? 0.5 : 1)
                    .disabled(empty || sending)
                }
                .padding(.vertical, 2)
                if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
                ForEach(suggestions) { p in
                    let b = badge(for: p)
                    Button { if b == "Invite" { invite = p.username; send() } } label: {
                        personRow(avatar: p.avatar, name: p.name, sub: "@" + p.username) { pill(b, kind: b == "Invite" ? .add : b == "Invited" ? .invited : .plain) }
                    }
                    .buttonStyle(.plain)
                }
            }
            ForEach(people) { p in
                personRow(avatar: p.avatar, name: p.name + (p.isMe ? " (you)" : ""),
                          sub: p.role == "invited" ? "Hasn’t accepted yet" : (p.username.isEmpty ? "" : "@" + p.username)) {
                    if p.role == "owner" {
                        pill("Owner", kind: .owner)
                    } else if p.role == "invited" {
                        pill("Invited", kind: .invited)
                    } else if isOwner && !p.isMe {
                        Button {
                            if armed == p.id { Task { await Collab.shared.remove(p, from: songID); armed = nil; await load() } }
                            else { Haptics.selection(); armed = p.id }
                        } label: {
                            Text(armed == p.id ? "Remove?" : "Remove").font(.system(size: 14))
                                .foregroundStyle(armed == p.id ? Color.red : .secondary)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(armed == p.id ? Color.red.opacity(0.1) : .clear, in: Capsule())
                        }
                        .buttonStyle(.borderless)
                    } else {
                        pill("Co-writer", kind: .plain)
                    }
                }
            }
            if isOwner && people.count <= 1 {
                Text("No one else yet. Invite a co-writer above.").font(.system(size: 13.5)).foregroundStyle(.secondary).padding(.leading, 46)
            }
            Button(role: .destructive) { if isOwner { confirmStop = true } else { confirmLeave = true } } label: {
                Text(isOwner ? "Stop Sharing" : "Leave Song").font(.system(size: 16)).frame(maxWidth: .infinity)
            }
        } header: { Text("Collaborators") } footer: {
            Text(isOwner ? "Co-writers need *[demo] and a username." : "Leaving removes the song from your library.")
        }
        .task(id: s.id) { await load() }
        .task(id: invite) {
            guard isOwner else { return }
            try? await Task.sleep(for: .milliseconds(250))
            suggestions = await Collab.shared.suggest(invite)
        }
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

    /// The web's .clrow: 34pt avatar, name and a grey line, something on the right.
    private func personRow<R: View>(avatar: String?, name: String, sub: String, @ViewBuilder right: () -> R) -> some View {
        HStack(spacing: 12) {
            Avatar(url: avatar, name: name, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 15.5, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                if !sub.isEmpty { Text(sub).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            right()
        }
        .frame(minHeight: 44)
    }

    enum PillKind { case owner, invited, add, plain }

    /// The web's .clbadge: Owner (filled), Invited (peach to lilac), Invite (filled), others grey.
    private func pill(_ t: String, kind: PillKind) -> some View {
        Text(t).font(.system(size: 12, weight: .semibold))
            .foregroundStyle(kind == .owner || kind == .add ? Theme.onTint : kind == .invited ? Color(hex: 0x3B2E5A) : .secondary)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background {
                switch kind {
                case .owner, .add: Capsule().fill(Theme.tint)
                case .invited: Capsule().fill(LinearGradient(colors: [Color(hex: 0xFFD3BE), Color(hex: 0xE3CCFF)], startPoint: .topLeading, endPoint: .bottomTrailing))
                case .plain: Capsule().fill(BarFill.color)
                }
            }
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
