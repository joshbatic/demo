import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UserNotifications

/// Account (spec §6): the profile, plan, invitations, name and username, notifications, links, your songs,
/// Muse & privacy, About & support and the account actions, with the plan and credits as their own pages.
struct AccountScreen: View {
    @Environment(AppSession.self) private var session
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var collab = Collab.shared
    @State private var push = Push.shared

    // profile
    @State private var photo: PhotosPickerItem?
    @State private var path: [String] = []
    // notifications
    @State private var notifOpen = false
    @State private var prefs: [String: Bool] = [:]
    // links
    // songs
    @State private var importing = false
    @State private var exportURL: URL?
    @State private var storage: (used: Double, limit: Double)?
    // privacy
    @State private var blocked: [AppSession.Blocked] = []
    @State private var blockedOpen = false
    @State private var confirmBlock: Collab.Invite?
    @State private var confirmReset = false
    // support
    @State private var tickets: [AppSession.Ticket] = []
    // actions
    @State private var confirmSignOut = false
    @State private var confirmDelete = false
    @State private var deleting = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                hero
                planSection
                if !collab.invites.isEmpty { invitesSection }
                profileSection
                linksSection
                songsSection
                privacySection
                supportSection
                actionsSection
            }
            // the photo sits just under the title bar, not a whole section's gap below it
            .contentMargins(.top, 0, for: .scrollContent)
            .listSectionSpacing(.compact)
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { DoneButton { dismiss() } } }
            .navigationDestination(for: String.self) { page in
                switch page {
                case "plan": PlanPage()
                case "credits": CreditsPage(onOpen: { id in dismiss(); session.openSongID = id })
                case "name": NameEditPage()
                case "links": LinksEditPage()
                default: SupportPage(tickets: $tickets)
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText, .text], allowsMultipleSelection: true) { r in
                if case .success(let urls) = r, !urls.isEmpty { Haptics.success(); session.toast = library.importFiles(urls) }
            }
            .sheet(item: Binding(get: { exportURL.map(ShareSheet.IdentURL.init) }, set: { exportURL = $0?.url })) { u in
                ActivityView(items: [u.url])
            }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task {
                    if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) { await session.saveAvatar(img) }
                    photo = nil
                }
            }
            .confirmDestroy("Block \(confirmBlock?.ownerName ?? "")?", isPresented: Binding(get: { confirmBlock != nil }, set: { if !$0 { confirmBlock = nil } }),
                            message: "They won’t be able to invite you to songs. They aren’t told.", action: "Block") {
                if let i = confirmBlock { Task { await session.block(i); blocked = await session.loadBlocked() } }
            }
            .confirmDestroy("Reset what Rate learned?", isPresented: $confirmReset, message: "Rate forgets the style it read from your songs and learns it fresh.", action: "Reset") {
                session.resetRateLearned()
            }
            .confirmDestroy("Sign out of *[demo]?", isPresented: $confirmSignOut, message: "Your songs stay safe in your account.", action: "Sign Out") {
                dismiss(); Task { await session.signOut() }
            }
            .confirmDestroy("Delete your account?", isPresented: $confirmDelete,
                            message: "Your songs, ideas, recordings, share links and profile are deleted from your account, and songs you share stop being shared. Copies on your other devices go when you sign out there. If you pay for Pro through Apple, cancel it in Settings › your name › Subscriptions: deleting your account doesn’t stop billing. This can’t be undone.",
                            action: "Delete Account") {
                deleting = true
                Task {
                    if let err = await session.deleteAccount() { session.toast = err; deleting = false } else { dismiss() }
                }
            }
            .overlay { if deleting { ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity).background(.ultraThinMaterial) } }
        }
        .belowIslandSheet()
        .task {
            if session.accountFocus == "support" { path.append("support"); session.accountFocus = nil }
            async let p: Void = session.refreshPlan()
            async let st = session.myStorage()
            async let bl = session.loadBlocked()
            async let tk = session.tickets()
            await push.refreshStatus()
            storage = await st; blocked = await bl; tickets = await tk
            await p
            await collab.pullInvites()
        }
    }

    // MARK: hero (§6.1)

    private var hero: some View {
        Section {
            VStack(spacing: 8) {
                PhotosPicker(selection: $photo, matching: .images) {
                    Avatar(url: session.profile.avatar_url, name: session.myName, size: 88)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "camera.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: 28, height: 28).background(Color(hex: 0x8E8E93), in: Circle())
                                .overlay(Circle().stroke(Color(uiColor: .systemGroupedBackground), lineWidth: 2.5))
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Change photo")
                HStack(spacing: 6) {
                    Text(session.myName.isEmpty ? "Your account" : session.myName).font(.system(size: 24, weight: .bold))
                    if session.plan.tier == "pro" {
                        Text("Pro").font(.system(size: 12, weight: .bold)).padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Theme.proGreen, in: Capsule()).foregroundStyle(.white)
                    }
                }
                Text([session.profile.username.map { "@" + $0 } ?? "", session.email].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 15)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
        }
    }

    // MARK: plan (§6.6)

    private var planSection: some View {
        Section {
            NavigationLink(value: "plan") {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous).fill(LinearGradient(colors: [Color(hex: 0xFFC2DA), Color(hex: 0xB9A6FF)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        ProMark(size: 14)
                    }
                    .frame(width: 29, height: 29)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(session.plan.tier == "beta" ? "*[demo] Beta" : "*[demo] Pro").font(.system(size: 17))
                            if session.plan.tier == "pro" {
                                Text("Active").font(.system(size: 11, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Theme.proGreen.opacity(0.18), in: Capsule()).foregroundStyle(Theme.proGreen)
                            }
                        }
                        Text(planLine).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if !session.plan.isPro {
                        Button { session.paywallWhy = "" } label: {
                            Text("Go Pro").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.onTint)
                                .padding(.horizontal, 14).frame(height: 30).background(Theme.tint, in: Capsule())
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private var planLine: String {
        switch session.plan.tier {
        case "beta": return "Everything’s unlocked during the beta"
        case "pro": return PlanPage.renews(session.plan.expiresAt).map { "Renews " + $0 } ?? "Everything’s unlocked"
        default: return "Demos, co-writing, lyric sync and more"
        }
    }

    // MARK: invitations (§6.5)

    private var invitesSection: some View {
        Section("Invitations") {
            ForEach(collab.invites) { inv in
                HStack(spacing: 12) {
                    Avatar(url: inv.avatar, name: inv.ownerName, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(inv.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                        HStack(spacing: 4) {
                            Text("from " + inv.ownerName).lineLimit(1)
                            Text("·")
                            Button("Block") { confirmBlock = inv }.buttonStyle(.borderless).foregroundStyle(.red)
                        }
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button { Task { await collab.decline(inv); session.toast = "Invite declined" } } label: {
                        Text("Decline").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.tint)
                            .padding(.horizontal, 12).frame(height: 30).background(BarFill.color, in: Capsule())
                    }
                    .buttonStyle(.borderless)
                    Button { Task { await collab.accept(inv); await Push.shared.ask() } } label: {
                        Text("Accept").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.onTint)
                            .padding(.horizontal, 12).frame(height: 30).background(Theme.tint, in: Capsule())
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: name & username, notifications (§6.2, §6.3)

    @ViewBuilder private var profileSection: some View {
        Section {
            NavigationLink(value: "name") {
                LabeledContent {
                    if let u = session.profile.username, !u.isEmpty { Text("@" + u) } else { Text("Not set") }
                } label: { Label { Text("Name & Username") } icon: { TileIcon("person.text.rectangle.fill", Theme.Tile.blue) } }
            }
            Button { notificationsTapped() } label: {
                LabeledContent {
                    switch push.status {
                    case .authorized, .provisional, .ephemeral: Text("On")
                    case .denied: Text("Off")
                    default: Text("Turn On").foregroundStyle(.blue)
                    }
                } label: { Label { Text("Notifications").foregroundStyle(.primary) } icon: { TileIcon("bell.badge.fill", Theme.Tile.red) } }
            }
            if notifOpen && [UNAuthorizationStatus.authorized, .provisional, .ephemeral].contains(push.status) {
                prefToggle("cowrite", "Co-writing", "When someone accepts your invite or edits a song you share")
                prefToggle("nudge", "Writing reminders", "A gentle nudge after a few days away, at most once a week")
                prefToggle("account", "Account & Pro", "Beta access, Pro and your free trial")
                prefToggle("plays", "Share link plays", "When someone opens a song you shared, once a day")
                Text("Invites and replies from *[demo] Support always come through. To turn everything off, use Settings › *[demo] › Notifications.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func prefToggle(_ k: String, _ title: String, _ sub: String) -> some View {
        Toggle(isOn: Binding(get: { prefs[k] ?? true }, set: { v in prefs[k] = v; Haptics.selection(); Task { await session.setNotifyPref(k, v) } })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(sub).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func notificationsTapped() {
        Haptics.tap()
        Task {
            await push.refreshStatus()
            switch push.status {
            case .notDetermined:
                if await push.ask() { session.toast = "Notifications are on" }
            case .denied:
                session.toast = "Notifications are off for *[demo]. Turn them on in Settings › *[demo] › Notifications."
            default:
                if !notifOpen { prefs = await session.notifyPrefs() }
                withAnimation(.snappy) { notifOpen.toggle() }
            }
        }
    }

    // MARK: links (§6.4)

    private var linksSection: some View {
        Section("Links") {
            linkRow("Spotify", "spotify", session.profile.link_spotify)
            linkRow("Instagram", "instagram", session.profile.link_instagram)
            linkRow("TikTok", "tiktok", session.profile.link_tiktok)
        }
    }

    private func linkRow(_ title: String, _ kind: String, _ url: String?) -> some View {
        NavigationLink(value: "links") {
            LabeledContent(title) {
                Text(AppSession.linkLabel(url, kind: kind) ?? "Add")
            }
        }
    }

    // MARK: your songs (§6.8)

    private var songsSection: some View {
        Section("Your songs") {
            NavigationLink(value: "credits") {
                LabeledContent {
                    Text("\(CreditsPage.finished(library, me: session.userID).count)")
                } label: { Label("Credits", systemImage: "music.note") }
            }
            .labelStyle(TileLabelStyle(color: Theme.Tile.orange))
            Button { Haptics.tap(); importing = true } label: {
                Label { Text("Import Songs").foregroundStyle(.primary) } icon: { TileIcon("square.and.arrow.down", Theme.Tile.blue) }
            }
            Button {
                Haptics.tap()
                if let u = library.exportFile() { exportURL = u } else { session.toast = "No songs to export yet" }
            } label: {
                Label { Text("Export All Songs").foregroundStyle(.primary) } icon: { TileIcon("square.and.arrow.up", Theme.Tile.green) }
            }
            LabeledContent {
                if let st = storage {
                    Text(SongFiles.size(st.used) + " of " + SongFiles.size(st.limit)).foregroundStyle(st.used >= st.limit ? Color.red : .secondary)
                } else { Text("—") }
            } label: { Label { Text("Storage") } icon: { TileIcon("internaldrive.fill", Theme.Tile.gray) } }
        }
    }

    // MARK: Muse & privacy (§6.9)

    private var privacySection: some View {
        Section {
            Toggle(isOn: Binding(get: { AIService.shared.consent == "yes" }, set: { on in
                Haptics.selection()
                if on { AIService.shared.consent = "yes"; session.toast = "AI features are on" }
                else { AIService.shared.consent = "no"; session.toast = "AI features are off" }
            })) {
                Label { Text("AI Features") } icon: { TileIcon("sparkles", Theme.Tile.purple) }
            }
            Button { confirmReset = true } label: {
                Label { Text("Reset What Rate Learned").foregroundStyle(.primary) } icon: { TileIcon("arrow.counterclockwise", Theme.Tile.indigo) }
            }
            if !blocked.isEmpty {
                Button { withAnimation(.snappy) { blockedOpen.toggle() } } label: {
                    LabeledContent {
                        Text("\(blocked.count)")
                    } label: { Label { Text("Blocked").foregroundStyle(.primary) } icon: { TileIcon("hand.raised.fill", Theme.Tile.pink) } }
                }
                if blockedOpen {
                    ForEach(blocked) { b in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(b.name)
                                if !b.username.isEmpty { Text("@" + b.username).font(.footnote).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Button("Unblock") { Task { await session.unblock(b); blocked = await session.loadBlocked() } }.buttonStyle(.borderless)
                        }
                    }
                }
            }
        } header: { Text("Muse & privacy") } footer: {
            Text("AI features send what you’re working on to OpenAI.")
        }
    }

    // MARK: about & support (§6.10)

    private var supportSection: some View {
        Section("About & support") {
            Button { openURL(URL(string: "https://hellodemo.app/privacy.html")!) } label: {
                Label { Text("Privacy Policy").foregroundStyle(.primary) } icon: { TileIcon("hand.raised.fill", Theme.Tile.blue) }
            }
            Button { openURL(URL(string: "https://hellodemo.app/terms.html")!) } label: {
                Label { Text("Terms of Service").foregroundStyle(.primary) } icon: { TileIcon("doc.text.fill", Theme.Tile.gray) }
            }
            NavigationLink(value: "support") {
                LabeledContent {
                    let n = tickets.reduce(0) { $0 + $1.replies.count }
                    if n > 0 { Text(n == 1 ? "1 reply" : "\(n) replies") }
                } label: { Label { Text("Contact Support") } icon: { TileIcon("bubble.left.and.text.bubble.right.fill", Theme.Tile.green) } }
            }
        }
    }

    // MARK: actions (§6.11)

    private var actionsSection: some View {
        Section {
            Button {
                Haptics.tap()
                dismiss()
                Task { await session.signOut() }
            } label: {
                Label { Text("Switch Account").foregroundStyle(.primary) } icon: { TileIcon("person.2.fill", Theme.Tile.indigo) }
            }
            Button("Sign Out", role: .destructive) { confirmSignOut = true }
            Button("Delete Account", role: .destructive) { Haptics.warning(); confirmDelete = true }
        } footer: {
            Text("Version \(Config.appCommit)").textSelection(.enabled).frame(maxWidth: .infinity).padding(.top, 10)
        }
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

/// Puts a Label's icon on a coloured tile (for rows built from a plain Label).
struct TileLabelStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title.foregroundStyle(.primary)
        } icon: {
            configuration.icon.font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 29, height: 29).background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}

// MARK: - Name & Username (§6.2)

/// Settings-style: the fields in a form, Save in the navigation bar.
struct NameEditPage: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var user = ""
    @State private var error: String?
    @State private var saving = false
    @FocusState private var focus: Int?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name).textContentType(.name).submitLabel(.next).focused($focus, equals: 0)
                    .onSubmit { focus = 1 }
            } header: { Text("Name") } footer: { Text("Shown on song credits.") }
            Section {
                HStack(spacing: 2) {
                    Text("@").foregroundStyle(.secondary)
                    TextField("username", text: Binding(get: { user }, set: { user = $0.replacingOccurrences(of: "@", with: "").replacingOccurrences(of: " ", with: "") }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.username)
                        .submitLabel(.done).focused($focus, equals: 1).onSubmit { save() }
                }
            } header: { Text("Username") } footer: {
                Text(error ?? "3–20 letters, numbers or underscores. Co-writers find you by it.")
                    .foregroundStyle(error == nil ? Color.secondary : Color.red)
            }
        }
        .navigationTitle("Name & Username")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() } else { Button("Save") { save() }.fontWeight(.semibold) }
            }
        }
        .onAppear {
            name = session.profile.display_name ?? session.myName
            user = session.profile.username ?? ""
        }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        Task {
            let hadUser = !(session.profile.username ?? "").isEmpty
            let err = await session.saveNameAndUsername(name: name, username: user)
            saving = false
            if let err { error = err; Haptics.warning(); return }
            Haptics.success(); session.toast = "Saved"
            dismiss()
            if !hadUser && !(session.profile.username ?? "").isEmpty {
                await Push.shared.ask("You’ll get a notification when someone invites you to a song.")
            }
        }
    }
}

// MARK: - Links (§6.4)

struct LinksEditPage: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var spotify = ""
    @State private var instagram = ""
    @State private var tiktok = ""
    @State private var saving = false

    var body: some View {
        Form {
            Section {
                field("Spotify", "Artist link", $spotify, url: session.profile.link_spotify)
                field("Instagram", "@username", $instagram, url: session.profile.link_instagram)
                field("TikTok", "@username", $tiktok, url: session.profile.link_tiktok)
            } footer: { Text("Paste a link, or just your @handle.") }
        }
        .navigationTitle("Links")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() } else {
                    Button("Save") {
                        saving = true
                        Task {
                            let ok = await session.saveLinks(spotify: spotify, instagram: instagram, tiktok: tiktok)
                            saving = false
                            if ok { dismiss() }
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            spotify = session.profile.link_spotify ?? ""
            instagram = AppSession.linkLabel(session.profile.link_instagram, kind: "instagram") ?? ""
            tiktok = AppSession.linkLabel(session.profile.link_tiktok, kind: "tiktok") ?? ""
        }
    }

    private func field(_ title: String, _ ph: String, _ text: Binding<String>, url: String?) -> some View {
        HStack {
            Text(title)
            TextField(ph, text: text).multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            if let u = url.flatMap(URL.init(string:)) {
                Button { openURL(u) } label: { Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless).accessibilityLabel("Open " + title)
            }
        }
    }
}

// MARK: - Contact Support (§6.10)

struct SupportPage: View {
    @Binding var tickets: [AppSession.Ticket]
    @Environment(AppSession.self) private var session
    @State private var topic = "bug"
    @State private var message = ""
    @State private var diag = true
    @State private var sending = false
    @State private var error: String?

    static let topics: [(String, String)] = [("bug", "Something’s not working"), ("account", "Account or sign-in"), ("billing", "Subscription or billing"), ("idea", "Idea or request"), ("other", "Something else")]

    var body: some View {
        Form {
            Section {
                Picker("Topic", selection: $topic) { ForEach(Self.topics, id: \.0) { Text($0.1).tag($0.0) } }
                TextField("What’s happening? What were you doing when it went wrong? The more detail, the faster we can help.", text: Binding(get: { message }, set: { message = String($0.prefix(4000)) }), axis: .vertical)
                    .lineLimit(4...12)
            } footer: {
                if let error { Text(error).foregroundStyle(.red) } else { Text("We reply by email to \(session.email), usually within a day.") }
            }
            Section {
                Toggle("Include Diagnostics", isOn: $diag)
            } footer: { Text("Your app version, device, plan, sync status and recent error messages. Never your lyrics or songs.") }
            if !tickets.isEmpty {
                Section("Your messages") {
                    ForEach(tickets) { t in ticket(t) }
                }
            }
        }
        .navigationTitle("Contact Support")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if sending { ProgressView() } else { Button("Send") { send() }.fontWeight(.semibold).disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
        }
    }

    private func send() {
        guard !sending else { return }
        sending = true
        Task {
            let err = await session.sendSupport(topic: topic, message: message, diagnostics: diag)
            sending = false
            if let err { error = err; Haptics.warning(); return }
            error = nil; message = ""
            Haptics.success(); session.toast = "Sent. We’ll reply by email."
            tickets = await session.tickets()
            await Push.shared.ask("You’ll also get a notification when we reply.")
        }
    }

    private func ticket(_ t: AppSession.Ticket) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(t.fromUs ? "From *[demo]" : (Self.topics.first { $0.0 == t.topic }?.1 ?? "Message")).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(t.status == "replied" ? "Answered" : t.status == "closed" ? "Closed" : "Waiting for a reply")
                    .font(.caption.weight(.semibold)).foregroundStyle(t.status == "replied" ? Theme.proGreen : .secondary)
            }
            Text(SupportForm.ago(t.created)).font(.caption).foregroundStyle(.secondary)
            Text(t.message).font(.subheadline)
            ForEach(Array(t.replies.enumerated()), id: \.offset) { _, r in
                VStack(alignment: .leading, spacing: 2) {
                    Text("*[demo] · " + SupportForm.ago(r.at)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(r.text).font(.subheadline)
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(BarFill.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(.vertical, 4)
    }
}

enum SupportForm {
    /// "just now", "5 min ago", "3 h ago", "2 d ago", else a date.
    static func ago(_ iso: String) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return "" }
        let s = Date().timeIntervalSince(d)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86_400 { return "\(Int(s / 3600)) h ago" }
        if s < 7 * 86_400 { return "\(Int(s / 86_400)) d ago" }
        return d.formatted(date: .abbreviated, time: .omitted)
    }
}

// MARK: - Plan page (§6.6)

struct PlanPage: View {
    @Environment(AppSession.self) private var session
    @State private var store = Store.shared

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    ZStack {
                        Circle().fill(LinearGradient(colors: [Color(hex: 0xFFC2DA), Color(hex: 0xB9A6FF)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        ProMark(size: 26)
                    }
                    .frame(width: 64, height: 64)
                    switch session.plan.tier {
                    case "beta":
                        Text("*[demo] Beta").font(.title2.bold())
                        Text("Everything’s unlocked while *[demo] is in beta.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                    case "pro":
                        HStack(spacing: 6) {
                            Text("*[demo] Pro").font(.title2.bold())
                            Text("Active").font(.system(size: 12, weight: .bold)).padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Theme.proGreen.opacity(0.18), in: Capsule()).foregroundStyle(Theme.proGreen)
                        }
                        Text(Self.renews(session.plan.expiresAt, long: true).map { "Renews " + $0 } ?? "Thanks for supporting *[demo].").foregroundStyle(.secondary)
                    default:
                        Text("Free").font(.title2.bold())
                        Text("Unlimited songs, rhymes and ideas. Free for good.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }
            if session.plan.tier == "pro" {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text("Rates this month"); Spacer(); Text("\(session.plan.heavyMonth) of 100").foregroundStyle(.secondary) }
                        ProgressView(value: min(1, Double(session.plan.heavyMonth) / 100)).tint(Theme.proGreen)
                    }
                    .padding(.vertical, 4)
                }
            }
            if session.plan.isPro {
                Section("Included") {
                    ForEach(Pro.features) { f in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.title)
                                Text(f.sub).font(.footnote).foregroundStyle(.secondary)
                            }
                        } icon: { TileIcon(f.icon, f.color) }
                    }
                }
            }
            Section {
                if !session.plan.isPro {
                    Button("See What’s in Pro") { session.paywallWhy = "" }
                }
                if session.plan.tier == "pro" && session.plan.source == "apple" {
                    Button("Manage Subscription") { Task { await store.manage() } }
                }
                Button(store.busy == "restore" ? "Restoring…" : "Restore Purchases") { Task { await store.restore(session: session) } }
                    .disabled(store.busy != nil)
            }
        }
        .navigationTitle("*[demo] Pro")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// "12 Nov 2026" (or "12 November 2026") from the plan's expiry.
    static func renews(_ iso: String?, long: Bool = false) -> String? {
        guard let iso else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return nil }
        let o = DateFormatter(); o.dateFormat = long ? "d MMMM yyyy" : "d MMM yyyy"
        return o.string(from: d)
    }
}

// MARK: - Credits page (§6.7)

struct CreditsPage: View {
    var onOpen: (String) -> Void
    @Environment(AppSession.self) private var session
    @Environment(LibraryStore.self) private var library

    /// Finished songs with a title that are yours, co-written, or not shared.
    static func finished(_ library: LibraryStore, me: String?) -> [Song] {
        library.songs.filter { s in
            s.status == "Finished" && !s.title.trimmingCharacters(in: .whitespaces).isEmpty
                && (!s.isShared || s.owner.isEmpty || s.owner == me || (s.raw["members"]?.array ?? []).contains { $0.string == me })
        }
        .sorted { $0.updated > $1.updated }
    }

    private func cowriters(_ s: Song) -> [String] {
        let me = session.myName.lowercased()
        return s.credits.map(\.name).filter { !$0.isEmpty && $0.lowercased() != me }
    }

    private func isCo(_ s: Song) -> Bool { (s.isShared && s.owner != session.userID) || !cowriters(s).isEmpty }

    var body: some View {
        let list = Self.finished(library, me: session.userID)
        List {
            if list.isEmpty {
                VStack(spacing: 6) {
                    Text("No credits yet").font(.headline)
                    Text("Mark a song Finished and it shows up here.").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 30)
                .listRowBackground(Color.clear)
            } else {
                Section {
                    HStack {
                        stat(list.count, "Songs")
                        stat(list.filter { !isCo($0) }.count, "Written")
                        stat(list.filter(isCo).count, "Co-written")
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    ForEach(list) { s in
                        Button { onOpen(s.id) } label: {
                            HStack(spacing: 12) {
                                CoverView(song: s, size: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.displayTitle).font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                                    Text(withLine(s)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 6)
                                VStack(alignment: .trailing, spacing: 2) {
                                    if let sp = mySplit(s) { Text(sp + "%").font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary) }
                                    if let r = release(s) { Text(r).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Credits")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func stat(_ n: Int, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(n)").font(.system(size: 26, weight: .bold))
            Text(label).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func withLine(_ s: Song) -> String {
        let co = cowriters(s)
        if co.isEmpty { return isCo(s) ? "Co-written" : "Written" }
        let shown = co.prefix(2).joined(separator: " & ")
        return "Co-written with " + shown + (co.count > 2 ? " +\(co.count - 2)" : "")
    }

    private func mySplit(_ s: Song) -> String? {
        let me = session.myName.lowercased()
        return s.credits.first { $0.name.lowercased() == me && $0.hasSplit && !$0.split.isEmpty }?.split
    }

    private func release(_ s: Song) -> String? {
        let raw = s.releaseField("date")
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: raw) else { return nil }
        let o = DateFormatter(); o.dateFormat = "MMM yyyy"
        return o.string(from: d)
    }
}
