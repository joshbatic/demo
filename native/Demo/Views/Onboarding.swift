import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

// MARK: - after sign-up: the welcome page (A) and three tips in the first song (B)

/// Onboarding's first page (RootView's OnboardingView): three things the app does, then into the first song or
/// Bring your songs in (after the name and username step). No paywall, no permission asks.
struct WelcomeSheet: View {
    let onStart: () -> Void
    let onImport: () -> Void

    private static let rows: [(String, String, String)] = [
        ("text.badge.checkmark", "Rhymes as you type", "Write a line and rhymes, syllables and ideas appear above the keyboard."),
        ("mic", "Catch ideas anywhere", "Hum a melody or jot a line. It waits in Ideas until you need it."),
        ("person.2.badge.plus", "Write it together", "Invite a co-writer, and share a link that plays your demo."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(RadialGradient(stops: [.init(color: .white, location: 0), .init(color: .white, location: 0.12),
                                                 .init(color: .white.opacity(0.55), location: 0.13), .init(color: .white.opacity(0.55), location: 0.16),
                                                 .init(color: .white.opacity(0.18), location: 0.17), .init(color: .white.opacity(0.18), location: 1)],
                                         center: .center, startRadius: 0, endRadius: 75))
                    .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1))
                    .frame(width: 150, height: 150)
                    .shadow(color: Color(red: 0.24, green: 0.2, blue: 0.43).opacity(0.18), radius: 20, y: 18)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 210)
            // the colour runs up under the status bar
            .background(LinearGradient(colors: [Color(hex: 0xBFE3F5), Color(hex: 0xCFC8F7), Color(hex: 0xF1D3EC)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea(edges: .top))
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Welcome to *\u{2060}[demo]").font(.system(size: 30, weight: .heavy)).tracking(-0.6)
                Text("Everything for a song, in one place.").font(.system(size: 16)).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(.top, 26)

            VStack(alignment: .leading, spacing: 22) {
                ForEach(Self.rows, id: \.1) { r in
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: r.0).font(.system(size: 24)).frame(width: 32).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.1).font(.system(size: 16, weight: .bold))
                            Text(r.2).font(.system(size: 15)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 26)

            Spacer(minLength: 16)

            VStack(spacing: 10) {
                Button(action: onStart) {
                    Text("Start my first song").font(.system(size: 17, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 52)
                        .background(Theme.tint, in: Capsule()).foregroundStyle(Theme.onTint)
                }
                Button(action: onImport) {
                    Text("I have songs to bring in").font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary).padding(8)
                }
                Text("Free to write with. Pro is optional.").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
    }
}

/// The three tips in the first song, one at a time, above the rhyme bar. "Skip tips" is always there.
struct FirstSongTip: View {
    let step: Int
    let onNext: () -> Void
    let onSkip: () -> Void

    static let tips: [(String, String)] = [
        ("Tap a rhyme to end your line", "The bar follows the word you’re on. The small number is its syllables."),
        ("Hum it before you forget", "Ideas, at the top of your songs, records a voice memo in one tap."),
        ("It saves as you go", "Your song is kept on this phone and in your account. Tap back to see it in your songs."),
    ]

    var body: some View {
        let t = Self.tips[min(step, Self.tips.count - 1)]
        VStack(alignment: .leading, spacing: 4) {
            Text(t.0).font(.system(size: 16, weight: .bold))
            Text(t.1).font(.system(size: 14)).foregroundStyle(.white.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<Self.tips.count, id: \.self) { i in
                        Capsule().fill(i == step ? Color.white : Color.white.opacity(0.3)).frame(width: i == step ? 18 : 6, height: 6)
                    }
                }
                .accessibilityElement().accessibilityLabel("Tip \(step + 1) of \(Self.tips.count)")
                Spacer()
                if step < Self.tips.count - 1 {
                    Button("Skip tips", action: onSkip).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                        .padding(.vertical, 8).padding(.horizontal, 6)
                }
                Button(step < Self.tips.count - 1 ? "Next" : "Done", action: onNext)
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.black)
                    .padding(.vertical, 8).padding(.horizontal, 14).background(.white, in: Capsule())
            }
            .padding(.top, 8)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(Color(hex: 0x1C1C1E), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 15, y: 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Bring your songs in

/// Every way songs come in: Notes and Voice Memos (through the share sheet), lyric files, and pasting.
struct ImportScreen: View {
    @Environment(\.appSession) private var session
    @Environment(\.library) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var pasting = false
    @State private var pasted = ""
    @State private var brought: [(String, String)] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Your songs stay private. Nothing is shared until you share it.")
                        .font(.system(size: 16)).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 4, trailing: 4))
                }
                Section {
                    row("note.text", Color(hex: 0xFFF4C2), Color(hex: 0x7A5B00), "From Notes",
                        "In Notes, tap Share, then *[demo]. Each note becomes a song.")
                    row("waveform", Color(hex: 0xFFE1E1), Color(hex: 0x9A1C1C), "From Voice Memos",
                        "Share a memo to *[demo]. It lands in Ideas, ready to start a song.")
                    row("folder", Color(hex: 0xDCEBFF), Color(hex: 0x0B4AA2), "Lyric files",
                        "Text, PDF or a *[demo] backup. Pick lots at once.", button: "Choose") { picking = true }
                    row("doc.on.clipboard", Color(hex: 0xE6F6EC), Color(hex: 0x146B3A), "Paste lyrics",
                        "The first line becomes the title.", button: "Paste") { pasted = UIPasteboard.general.string ?? ""; pasting = true }
                }
                if !brought.isEmpty {
                    Section("Just brought in") {
                        ForEach(brought, id: \.0) { b in
                            HStack { Text(b.0).lineLimit(1); Spacer(); Text(b.1).font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .navigationTitle("Bring your songs in")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.plainText, .text, .json, .rtf, .pdf], allowsMultipleSelection: true) { r in
                guard case .success(let urls) = r, !urls.isEmpty else { return }
                let before = Set(library.songs.map(\.id))
                session.toast = library.importFiles(urls)
                Haptics.success()
                note(library.songs.filter { !before.contains($0.id) }, "from a file")
            }
            .sheet(isPresented: $pasting) { pasteSheet }
        }
    }

    private func row(_ icon: String, _ bg: Color, _ fg: Color, _ title: String, _ text: String,
                     button: String? = nil, action: (() -> Void)? = nil) -> some View {
        HStack(alignment: button == nil ? .top : .center, spacing: 14) {
            Image(systemName: icon).font(.system(size: 18, weight: .medium)).foregroundStyle(fg)
                .frame(width: 40, height: 40).background(bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .bold))
                Text(text).font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let button, let action {
                Button(button, action: action).font(.system(size: 14, weight: .semibold)).buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule).tint(Theme.tint)
            }
        }
        .padding(.vertical, 4)
    }

    private var pasteSheet: some View {
        NavigationStack {
            TextEditor(text: $pasted)
                .font(.system(size: 17))
                .padding(.horizontal, 12)
                .navigationTitle("Paste lyrics")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { pasting = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add Song") {
                            let t = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                            pasting = false
                            guard !t.isEmpty else { return }
                            let s = Song(raw: SongBackup.fromText(t, name: "Pasted lyrics"))
                            library.add(s)
                            Haptics.success()
                            session.toast = "“\(s.displayTitle)” added"
                            note([s], "pasted")
                        }
                        .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }

    private func note(_ songs: [Song], _ how: String) {
        brought = songs.map { s in (s.displayTitle, "\(how) · \(s.lyricLines.count) lines") } + brought
    }
}

// MARK: - lyrics from other apps

nonisolated enum LyricText {
    private static let sections = #"^\s*[\(\[]?\s*(intro|verse|pre[- ]?chorus|chorus|post[- ]?chorus|bridge|middle 8|hook|refrain|interlude|breakdown|tag|outro)(\s*\d+)?\s*[\)\]]?\s*:?\s*$"#

    /// A heading on its own line ("Chorus", "Verse 2:", "(Bridge)") becomes a section tag ("[Chorus]", "[Verse 2]").
    static func tagSections(_ body: String) -> String {
        body.components(separatedBy: "\n").map { line in
            guard line.count <= 24, line.range(of: sections, options: [.regularExpression, .caseInsensitive]) != nil else { return line }
            let name = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t()[]:"))
            let words = name.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            return "[" + words.joined(separator: " ").replacingOccurrences(of: #"(?i)^pre ?chorus"#, with: "Pre-Chorus", options: .regularExpression) + "]"
        }.joined(separator: "\n")
    }
}

// MARK: - what the share extension saved (Notes and Voice Memos)

/// The share extension can't reach the library, so it leaves each share as a small file in the app group's Inbox
/// folder (and the audio beside it). The app brings them in when it opens. Keep `Item` the same as
/// DemoShare/ShareViewController.swift.
@MainActor
enum ShareInbox {
    nonisolated struct Item: Codable {
        var id: String
        var kind: String        // "text" or "audio"
        var mode: String        // "song", "idea" or "append"
        var title: String
        var text: String
        var file: String?       // the audio's file name in Inbox
        var songID: String?     // for "append"
        var at: Double
    }

    static var dir: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetShare.group)?.appendingPathComponent("Inbox", isDirectory: true)
    }
    private static var draining = false

    static func drain(_ session: AppSession) async {
        guard !draining, session.userID != nil, session.phase == .ready, let dir,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        draining = true
        defer { draining = false }
        let library = session.library
        var items: [(URL, Item)] = []
        for n in names where n.hasSuffix(".json") {
            let u = dir.appendingPathComponent(n)
            if let d = try? Data(contentsOf: u), let it = try? JSONDecoder().decode(Item.self, from: d) { items.append((u, it)) }
            else { try? FileManager.default.removeItem(at: u) }
        }
        var said: [String] = []
        for (u, it) in items.sorted(by: { $0.1.at < $1.1.at }) {
            try? FileManager.default.removeItem(at: u)
            if it.kind == "audio", let f = it.file {
                let src = dir.appendingPathComponent(f)
                if !session.plan.isPro && IdeaMemos.memoCount(library) >= IdeaMemos.freeLimit {
                    try? FileManager.default.removeItem(at: src)
                    session.upsell("memos")
                    continue
                }
                let dur = (try? await AVURLAsset(url: src).load(.duration).seconds) ?? 0
                if await IdeaMemos.save(src, dur: dur, text: it.title, library: library, session: session) { said.append("a voice memo") }
                continue
            }
            let text = it.text.replacingOccurrences(of: "\r", with: "")
            if it.mode == "append", let id = it.songID, var s = library.song(id) {
                let add = LyricText.tagSections(text.trimmingCharacters(in: .whitespacesAndNewlines))
                s.lyrics = s.lyrics.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + add + "\n"
                if !s.rich.isEmpty {
                    let esc = add.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                    s.rich += "<br><br>" + esc.replacingOccurrences(of: "\n", with: "<br>")
                }
                s.touch()
                library.put(s)
                said.append("lines in “\(s.displayTitle)”")
                continue
            }
            switch it.mode {
            case "idea":
                library.putIdea(Idea.new(text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
                said.append("an idea")
            default:
                var raw = SongBackup.fromText(text, name: "Shared note")
                let t = it.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty {
                    raw["title"] = .string(String(t.prefix(80)))
                    // the note's first line was its title: don't repeat it as the first lyric
                    let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    var lines = body.components(separatedBy: "\n")
                    if lines.first?.trimmingCharacters(in: .whitespaces) == t { lines.removeFirst() }
                    raw["lyrics"] = .string(LyricText.tagSections(lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                raw["artist"] = .string(session.myName)
                library.add(Song(raw: raw))
                said.append("“\(raw["title"]?.string ?? "a song")”")
            }
        }
        if !said.isEmpty {
            Haptics.success()
            session.toast = said.count == 1 ? "Brought in \(said[0])" : "Brought in \(said.count) things from other apps"
        }
    }
}
