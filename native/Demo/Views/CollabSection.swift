import SwiftUI

/// Details › Info › Collaborators (spec §4.12).
struct CollabSection: View {
    let songID: String
    var onLeft: () -> Void
    /// Invite a Co-writer is shown by the Details sheet itself (a sheet hung on a list row closes when the row goes)
    var onInvite: () -> Void = {}
    /// bumped when that screen closes, to reload the people
    var refresh = 0
    @Environment(\.appSession) private var session
    @Environment(\.library) private var library
    @State private var people: [Collab.Person] = []
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
                // a plain, obvious row; the search itself gets its own screen
                Button { Haptics.tap(); onInvite() } label: {
                    HStack {
                        Text("Invite a Co-writer").foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "plus").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.tint)
                    }
                }
            }
            ForEach(people) { p in
                personRow(avatar: p.avatar, name: p.name + (p.isMe ? " (you)" : ""),
                          sub: p.role == "invited" ? "Hasn’t accepted yet" : (p.username.isEmpty ? "" : "@" + p.username),
                          more: moreAction(p)) {
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
        .task(id: refresh) { if refresh > 0 { await load() } }
        .confirmDestroy("Stop sharing “\(s.displayTitle)”?", isPresented: $confirmStop, message: "Your co-writers lose access. The song stays with you.", action: "Stop Sharing") {
            Task { await Collab.shared.stopSharing(songID); people = [] }
        }
        .confirmDestroy("Leave “\(s.displayTitle)”?", isPresented: $confirmLeave, message: "It’s removed from your devices. The owner can invite you again.", action: "Leave Song") {
            onLeft()
            Task { await session.removeSong(s); session.toast = "You left the song" }
        }
    }

    /// The web's .clrow: 34pt avatar, name and a grey line, something on the right.
    private func personRow<R: View>(avatar: String?, name: String, sub: String, more: (() -> Void)? = nil, @ViewBuilder right: () -> R) -> some View {
        HStack(spacing: 12) {
            Avatar(url: avatar, name: name, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 15.5, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                if !sub.isEmpty { Text(sub).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            right()
            if let more {
                Button { Haptics.tap(); more() } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Report or block \(name)")
            }
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

    /// The "…" on everyone but me and pending invites: Report or Block. Blocking the owner takes the song away.
    private func moreAction(_ p: Collab.Person) -> (() -> Void)? {
        if p.isMe || p.role == "invited" { return nil }
        let name = p.username.isEmpty ? p.name : "@" + p.username
        let isOwnerRow = p.role == "owner", id = songID, session = session, left = onLeft
        return {
            UserActions.show(name, id: p.id, songID: id, session: session) { _ in
                if isOwnerRow { left() } else { Task { await load() } }
            }
        }
    }

    private func load() async { people = await Collab.shared.people(song ?? Song(raw: [:])) }

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

/// Invite a Co-writer: a search for usernames with clear results, each with its own Invite button.
struct InviteSheet: View {
    let songID: String
    @State private var people: [Collab.Person] = []
    @Environment(\.appSession) private var session
    @Environment(\.library) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Collab.Person] = []
    @State private var searching = false
    @State private var blockedIDs: Set<String> = []
    @State private var sent: Set<String> = []
    @State private var sending: String?
    @State private var error: String?
    @FocusState private var focused: Bool

    private var typed: String { query.replacingOccurrences(of: "@", with: "").trimmingCharacters(in: .whitespaces).lowercased() }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        Text("@").font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary).padding(.trailing, -6)
                        TextField("username", text: $query)
                            .font(.system(size: 17))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .textContentType(.username)
                            .submitLabel(.send)
                            .focused($focused)
                            .onSubmit { if !typed.isEmpty { invite(typed, id: "typed") } }
                        if searching { ProgressView().controlSize(.small) }
                        else if !query.isEmpty {
                            Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                                .buttonStyle(.borderless).accessibilityLabel("Clear")
                        }
                    }
                } footer: {
                    Text(error ?? "Search by username. Co-writers need *[demo] and a username.")
                        .foregroundStyle(error == nil ? Color.secondary : Color.red)
                }
                if !results.isEmpty {
                    Section("People") {
                        ForEach(results) { p in row(p) }
                    }
                } else if typed.count >= 2 && !searching {
                    Section {
                        Text("No one with a username starting “\(typed)”.").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Invite a Co-writer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { DoneButton { dismiss() } } }
            .task(id: typed) {
                error = nil
                guard typed.count >= 2 else { results = []; return }
                searching = true
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                results = await Collab.shared.suggest(typed)
                searching = false
            }
            .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focused = true } }
            .task { if let s = library.song(songID) { people = await Collab.shared.people(s) } }
            .task { blockedIDs = Set(await session.loadBlocked().map(\.id)) }
        }
        .presentationDetents([.medium, .large])
    }

    private func status(_ p: Collab.Person) -> String? {
        if blockedIDs.contains(p.id) { return "Blocked" }
        if sent.contains(p.id) { return "Invited" }
        if let x = people.first(where: { $0.id == p.id }) { return x.role == "invited" ? "Invited" : "On song" }
        return nil
    }

    private func row(_ p: Collab.Person) -> some View {
        HStack(spacing: 12) {
            Avatar(url: p.avatar, name: p.name, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                Text("@" + p.username).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let st = status(p) {
                Label(st, systemImage: st == "Blocked" ? "hand.raised.slash" : "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
            } else if sending == p.id {
                ProgressView()
            } else {
                Button { invite(p.username, id: p.id) } label: {
                    Text("Invite").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.onTint)
                        .padding(.horizontal, 16).frame(height: 34).background(Theme.tint, in: Capsule())
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }

    private func invite(_ username: String, id: String) {
        guard sending == nil else { return }
        sending = id
        Task {
            let err = await Collab.shared.invite(username, to: songID)
            sending = nil
            if let err { error = err; Haptics.warning(); return }
            Haptics.success()
            if let p = results.first(where: { $0.username.lowercased() == username.lowercased() }) { sent.insert(p.id) }
            session.toast = "Invited @" + username.lowercased()
        }
    }
}

/// Report or Block someone (App Store guideline 1.2), from Details › Collaborators and Account › Invitations.
@MainActor
enum UserActions {
    static func show(_ name: String, id: String, songID: String?, session: AppSession, blocked: @escaping (String) -> Void = { _ in }) {
        Confirm.options(name, [
            (title: "Report \(name)", red: false, run: { report(name, id: id, songID: songID, session: session, blocked: blocked) }),
            (title: "Block \(name)", red: true, run: { block(name, id: id, session: session, blocked: blocked) })
        ])
    }

    static func block(_ name: String, id: String, session: AppSession, blocked: @escaping (String) -> Void = { _ in }) {
        // after the choices sheet has gone
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            Confirm.destroy("Block \(name)?", message: "They won’t be able to invite you or write with you, and you’ll leave any songs you share. They aren’t told.", action: "Block") {
                Task { await session.blockUser(id, name: name); blocked(id) }
            }
        }
    }

    static func report(_ name: String, id: String, songID: String?, session: AppSession, blocked: @escaping (String) -> Void = { _ in }) {
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            Confirm.sheet { close in
                ReportSheet(name: name, close: close) { reason, details, alsoBlock in
                    guard await session.report(id, name: name, reason: reason, details: details, songID: songID) else { return false }
                    Haptics.success()
                    if alsoBlock { await session.blockUser(id, name: name); blocked(id) }
                    return true
                }
            }
        }
    }
}

/// What's wrong, a few optional words, and "Also block".
struct ReportSheet: View {
    let name: String
    let close: () -> Void
    let send: (_ reason: String, _ details: String, _ alsoBlock: Bool) async -> Bool
    @State private var reason: String?
    @State private var details = ""
    @State private var alsoBlock = false
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(AppSession.reportReasons, id: \.key) { r in
                        Button { Haptics.selection(); reason = r.key } label: {
                            HStack {
                                Text(r.label).foregroundStyle(.primary)
                                Spacer()
                                if reason == r.key { Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(.red) }
                            }
                            .contentShape(Rectangle())
                        }
                        .accessibilityAddTraits(reason == r.key ? .isSelected : [])
                    }
                } header: { Text("What’s wrong?") } footer: {
                    Text("We review every report within 24 hours. \(name) won’t know you reported them.")
                }
                Section {
                    TextField("Add details (optional)", text: $details, axis: .vertical).lineLimit(3...6)
                }
                Section {
                    Toggle("Also block \(name)", isOn: $alsoBlock).toggleStyle(.green)
                }
            }
            .navigationTitle("Report \(name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { close() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "Sending…" : "Report") {
                        guard let reason else { return }
                        busy = true
                        Task {
                            let ok = await send(reason, String(details.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000)), alsoBlock)
                            busy = false
                            if ok { close() }
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(reason == nil || busy)
                }
            }
        }
        .interactiveDismissDisabled(busy)
    }
}
