import SwiftUI

/// Writing voice (spec §2.2): the song's genre, mood, language and fine-tuning. Saved with the song
/// and kept as the default for new songs.
struct VoiceSheet: View {
    let songID: String
    @Environment(\.library) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appSession) private var session
    @State private var profileDraft: String?
    @State private var profileSave: Task<Void, Never>?
    @State private var tagDraft = ""
    @FocusState private var tagFocus: Bool

    private var pf: [String: JSONValue] { library.song(songID)?.voice ?? WritingVoice.defaults }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(summary).foregroundStyle(.secondary).lineLimit(2)
                        Spacer()
                        Button("Reset") { reset() }.disabled(CanonicalJSON.string(.object(pf)) == CanonicalJSON.string(.object(WritingVoice.defaults)))
                    }
                }
                themes
                Section("Genre") { chipRow("genre", WritingVoice.genres) }
                Section("Mood") { chipRow("mood", WritingVoice.moods) }
                Section("Language") {
                    Picker("Language", selection: stringBinding("reg")) {
                        ForEach(WritingVoice.registers, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented).listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                Section {
                    TextField("e.g. 1970s Glasgow shipyard worker, Melbourne skater kid", text: stringBinding("dial"), axis: .vertical)
                } header: { Text("Who’s singing") } footer: {
                    Text("Saved with this song. Shapes the lines and words suggested for it.")
                }
                museProfile
            }
            .onAppear(perform: migrateImagery)
            .navigationTitle("Writing voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { DoneButton { dismiss() } } }
        }
        .belowIslandSheet()
    }

    private var tags: [String] { (pf["tags"]?.array ?? []).compactMap(\.string) }

    /// Themes and key words: tap to add, type your own, tap a tag to remove it.
    @ViewBuilder private var themes: some View {
        let song = library.song(songID)
        let sugg = WritingVoice.suggestedTags(title: song?.title ?? "", lyrics: song?.lyrics ?? "", have: tags)
        Section {
            if !tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { t in
                        Button { Haptics.selection(); setTags(tags.filter { $0 != t }) } label: {
                            HStack(spacing: 5) {
                                Text(t).font(.system(size: 14, weight: .semibold))
                                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).opacity(0.7)
                            }
                            .foregroundStyle(Theme.onTint)
                            .padding(.horizontal, 12).frame(height: 32)
                            .background(Theme.tint, in: Capsule())
                        }
                        .buttonStyle(PressScale())
                        .accessibilityLabel("Remove \(t)")
                    }
                }
                .padding(.vertical, 4)
            }
            TextField("Add a theme or word", text: $tagDraft)
                .focused($tagFocus)
                .submitLabel(.done)
                .autocorrectionDisabled()
                .onSubmit { let had = !tagDraft.isEmpty; addTag(tagDraft); tagDraft = ""; if had { tagFocus = true } }
            if !sugg.isEmpty {
                FadingHScroll {
                    HStack(spacing: 6) {
                        ForEach(sugg, id: \.self) { t in
                            Button { Haptics.selection(); addTag(t) } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                                    Text(t).font(.system(size: 14, weight: .semibold))
                                }
                                .foregroundStyle(Theme.tint)
                                .padding(.horizontal, 12).frame(height: 32)
                                .background(BarFill.color, in: Capsule())
                            }
                            .buttonStyle(PressScale())
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }
        } header: { Text("Themes and key words") } footer: {
            Text("Lines and rhymes lean toward these where they fit.")
        }
    }

    private func addTag(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !tags.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else { return }
        setTags(Array((tags + [String(t.prefix(40))]).suffix(12)))
    }

    private func setTags(_ a: [String]) { set("tags", .array(a.map { .string($0) })) }

    /// Imagery picks from before themes existed become themes, so nothing set is hidden.
    private func migrateImagery() {
        let img = (pf["img"]?.array ?? []).compactMap(\.string)
        guard !img.isEmpty else { return }
        let labels = img.map { d in WritingVoice.imagery.first { $0.1 == d }?.0 ?? d }
        var a = tags
        for l in labels where !a.contains(l) { a.append(l) }
        setTags(a)
        set("img", .array([]))
    }

    /// "How the muse sees your writing" (engines.md §2.6): the learned profile, editable.
    @ViewBuilder private var museProfile: some View {
        let mz = MuseMemory.shared
        let lines = Prompts.catalog(library.songs).count
        Section {
            if let p = mz.profile, !p.text.isEmpty {
                TextField("", text: Binding(get: { profileDraft ?? p.text }, set: { profileDraft = $0 }), axis: .vertical)
                    .lineLimit(2...6)
                    .onChange(of: profileDraft) { _, v in
                        guard let v else { return }
                        profileSave?.cancel()
                        profileSave = Task { try? await Task.sleep(for: .milliseconds(600)); if !Task.isCancelled { mz.editProfile(v) } }
                    }
            } else {
                Text(lines < 16 ? "Write a few songs and the muse will sum up your style here."
                                : "Not learned yet.")
                    .foregroundStyle(.secondary)
            }
            Button(mz.profile?.text.isEmpty == false ? "Relearn" : "Learn My Voice") {
                guard session.plan.isPro else { session.upsell("voice"); return }
                Task {
                    profileDraft = nil
                    if await mz.buildProfile(manual: true) != nil { Haptics.success() }
                    else if !mz.building { session.toast = "Couldn’t learn it this time. Try again in a moment." }
                }
            }
            .disabled(mz.building || lines < 8)
        } header: { Text("Your style") } footer: {
            if mz.building { Text("Learning from your songs…") }
            else if mz.profile != nil { Text("Learned from your songs. Edit it if it’s off.") }
        }
    }

    // MARK: chips

    private func chipRow(_ key: String, _ options: [String]) -> some View {
        let current = pf[key]?.string ?? "Any"
        var list = options
        if !list.contains(current) { list.insert(current, at: 1) }   // an unknown saved value goes after "Any"
        return ScrollViewReader { proxy in
            FadingHScroll {
                HStack(spacing: 6) {
                    ForEach(list, id: \.self) { o in
                        chip(o, on: o == current) { set(key, .string(o)); withAnimation(.snappy) { proxy.scrollTo(o, anchor: .center) } }
                            .id(o)
                    }
                }
            }
            .onAppear { proxy.scrollTo(current, anchor: .center) }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
    }

    private func chip(_ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button { Haptics.selection(); action() } label: {
            Text(title).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(on ? Theme.onTint : Theme.tint)
                .padding(.horizontal, 14).frame(height: 32)
                .background(on ? Theme.tint : BarFill.color, in: Capsule())
        }
        .buttonStyle(PressScale())
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: values

    private var summary: String {
        var a: [String] = []
        if let g = pf["genre"]?.string, g != "Any" { a.append(g) }
        if let m = pf["mood"]?.string, m != "Any" { a.append(m) }
        a.append(pf["reg"]?.string ?? "Conversational")
        let d = (pf["dial"]?.string ?? "").trimmingCharacters(in: .whitespaces)
        if !d.isEmpty { a.append(d) }
        return a.joined(separator: " · ")
    }

    private func stringBinding(_ k: String) -> Binding<String> {
        Binding(get: { pf[k]?.string ?? "" }, set: { set(k, .string($0)) })
    }

    private func set(_ k: String, _ v: JSONValue) {
        guard var s = library.song(songID) else { return }
        var p = s.voice
        guard p[k] != v else { return }
        p[k] = v
        s.raw["pf"] = .object(p)
        s.touch()
        library.put(s)
        WritingVoice.lastUsed = p
    }

    private func reset() {
        guard var s = library.song(songID) else { return }
        Haptics.tap()
        s.raw["pf"] = .object(WritingVoice.defaults)
        s.touch()
        library.put(s)
        WritingVoice.lastUsed = WritingVoice.defaults
    }
}
