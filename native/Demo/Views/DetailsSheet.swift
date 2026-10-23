import SwiftUI
import UIKit

/// The Details sheet's tabs (dseg).
enum DetailsTab: String, CaseIterable, Identifiable {
    case info, audio, chords, credits
    var id: String { rawValue }
    var title: String {
        switch self { case .info: "Info"; case .audio: "Audio"; case .chords: "Chords"; case .credits: "Credits" }
    }
}

/// Song details: Info (facts, notes, versions, actions), Audio, Chords and Credits (spec §2.1).
struct DetailsSheet: View {
    let songID: String
    @State var tab: DetailsTab
    var onRestore: () -> Void = {}
    var onDelete: () -> Void = {}
    var onPlayWithLyrics: () -> Void = {}
    var onLeave: () -> Void = {}
    @Environment(AppSession.self) private var session
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var chordSel: TextSelection?

    static let statuses = ["Idea", "Draft", "Demo", "Finished"]
    static let keys: [String] = ChordChips.notes + ChordChips.notes.map { $0 + "m" }

    private var song: Song? { library.song(songID) }

    var body: some View {
        NavigationStack {
            Form {
                switch tab {
                case .info: info
                case .audio: audio
                case .chords: chords
                case .credits: creditsPane
                }
            }
            // the tabs sit just under the title bar, full width, at the large iOS size
            .contentMargins(.top, 4, for: .scrollContent)
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("Details", selection: Binding(get: { tab }, set: { pick($0) })) {
                    ForEach(DetailsTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.large)
                .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 8)
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { DoneButton { dismiss() } } }
            .confirmationDialog("Delete “\(song?.displayTitle ?? "")”?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Song", role: .destructive) { dismiss(); onDelete() }
            } message: { Text("This can’t be undone.") }
        }
        .presentationDetents([.fraction(0.88)])   // the web's Details sheet is 88% of the screen
    }

    private func pick(_ t: DetailsTab) {
        if t == .credits && !session.plan.isPro {
            Haptics.warning()
            session.toast = "Credits and release details are part of *[demo] Pro"
            return
        }
        Haptics.selection()
        withAnimation(.snappy(duration: 0.2)) { tab = t }
    }

    // MARK: Info

    @ViewBuilder private var info: some View {
        Section {
            field("Artists", \.artist, prompt: "Add artists")
            Picker("Key", selection: binding(\.key)) {
                Text("None").tag("")
                ForEach(Self.keys, id: \.self) { Text($0).tag($0) }
            }
            HStack {
                Text("Tempo")
                Spacer()
                TextField("BPM", text: binding(\.bpm)).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(maxWidth: 120)
            }
            field("Tuning", \.tuning, prompt: "Standard")
            Picker("Status", selection: binding(\.status)) { ForEach(Self.statuses, id: \.self) { Text($0) } }
            HStack {
                Text("Folder")
                Spacer()
                TextField("None", text: binding(\.folder)).multilineTextAlignment(.trailing)
                if !folderSuggestions.isEmpty {
                    Menu {
                        Button("None") { set(\.folder, "") }
                        ForEach(folderSuggestions, id: \.self) { f in Button(f) { set(\.folder, f) } }
                    } label: { Image(systemName: "chevron.up.chevron.down").font(.footnote).foregroundStyle(.secondary) }
                    .accessibilityLabel("Choose a folder")
                }
            }
        }
        Section {
            TextField("Notes: melody ideas, references, co-writers", text: binding(\.notes), axis: .vertical).lineLimit(3...12)
        }
        CollabSection(songID: songID, onLeft: { dismiss(); onLeave() })
        Section("Versions") {
            Button {
                guard var s = song else { return }
                let saved = s.snap("Saved")
                if saved { library.put(s) }
                Haptics.tap()
                session.toast = saved ? "Version saved" : "No changes since the last version"
            } label: { Text("Save Version").frame(maxWidth: .infinity) }
            ForEach((song?.versions ?? []).reversed()) { v in
                Button { restore(v) } label: {
                    HStack {
                        Text(Date(timeIntervalSince1970: v.t / 1000).formatted(.dateTime.month(.abbreviated).day().hour().minute()) + (v.label.isEmpty ? "" : " · " + v.label))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(v.words) words").foregroundStyle(.secondary)
                    }
                }
            }
        }
        Section {
            Button("Copy Lyrics") {
                guard let s = song else { return }
                UIPasteboard.general.string = (s.title.isEmpty ? "" : s.title + "\n\n") + s.lyrics
                Haptics.success(); session.toast = "Copied"
            }
            if song?.artDataURL != nil {
                Button("Remove Cover Art", role: .destructive) {
                    guard var s = song else { return }
                    s.raw["art"] = ""; s.touch(); library.put(s)
                    Haptics.tap(); dismiss()
                }
            }
            Button("Delete Song", role: .destructive) { confirmDelete = true }
        }
    }

    private var folderSuggestions: [String] {
        Array(Set(library.songs.map(\.folder).filter { !$0.isEmpty })).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func restore(_ v: Song.Version) {
        guard var s = song else { return }
        s.snap("Before restore")
        s.setText(lyrics: v.lyrics, rich: v.rich)
        onRestore()          // lets the editor take the new text even if it was just typing
        library.put(s)
        Haptics.success()
        dismiss()
        session.toast = "Restored. Your previous text was saved as a version."
    }

    // MARK: Audio

    private var audio: some View {
        AudioPane(songID: songID, onPlayWithLyrics: { dismiss(); onPlayWithLyrics() })
    }

    // MARK: Chords

    @ViewBuilder private var chords: some View {
        Section {
            TextEditor(text: binding(\.chords), selection: $chordSel)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(minHeight: 220)
                .overlay(alignment: .topLeading) {
                    if (song?.chords ?? "").isEmpty {
                        Text("Am   F   C   G\nChords, tabs, strumming…")
                            .font(.system(.body, design: .monospaced)).foregroundStyle(.tertiary)
                            .padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                    }
                }
        }
        Section {
            FlowLayout(spacing: 8) {
                ForEach(ChordChips.chips(key: song?.key ?? ""), id: \.self) { c in
                    Button { insertChord(c) } label: {
                        Text(c).font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(Theme.tint)
                            .padding(.horizontal, 14).frame(height: 36)
                            .background(BarFill.color, in: Capsule())
                    }
                    .buttonStyle(PressScale())
                }
            }
            .padding(.vertical, 4)
        } footer: {
            Text("Chords for the key of \((song?.key ?? "").isEmpty ? "C" : song!.key). Set the key in Info.")
        }
    }

    /// Puts a chord at the caret, with a space after it (`/` and `|` get spaces both sides).
    private func insertChord(_ c: String) {
        guard var s = song else { return }
        Haptics.tap()
        let ins = (c == "/" || c == "|") ? " \(c) " : c + " "
        var text = s.chords
        var at = text.endIndex
        if let sel = chordSel {
            switch sel.indices {
            case .selection(let r) where r.lowerBound >= text.startIndex && r.upperBound <= text.endIndex:
                text.replaceSubrange(r, with: ins)
                at = text.index(r.lowerBound, offsetBy: ins.count)
            default:
                text += ins; at = text.endIndex
            }
        } else {
            text += ins; at = text.endIndex
        }
        s.chords = text; s.touch(); library.put(s)
        chordSel = TextSelection(insertionPoint: at)
    }

    // MARK: Credits and release (Pro)

    @ViewBuilder private var creditsPane: some View {
        let list = song?.credits ?? []
        Section {
            if list.isEmpty {
                Text("Add writers, producers and performers").foregroundStyle(.secondary)
            }
            ForEach(list.indices, id: \.self) { i in
                VStack(spacing: 8) {
                    HStack {
                        TextField("Name", text: creditBinding(i, \.name))
                        Button { removeCredit(i) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .buttonStyle(.plain).accessibilityLabel("Remove credit")
                    }
                    HStack {
                        Picker("Role", selection: creditBinding(i, \.role)) {
                            ForEach(Song.Credit.roles, id: \.self) { Text($0) }
                        }
                        .labelsHidden()
                        Spacer()
                        if list[i].hasSplit {
                            TextField("Split", text: creditBinding(i, \.split))
                                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 70)
                            Text("%").foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            HStack {
                Text("Credits")
                Spacer()
                if list.filter(\.hasSplit).count > 1 {
                    Button("Split Evenly") { splitEvenly() }.font(.subheadline).textCase(nil)
                }
                Button("Add") { addCredit() }.font(.subheadline.weight(.semibold)).textCase(nil)
            }
        } footer: {
            if splitOK(list) {
                Label(splitNote(list), systemImage: "checkmark.circle.fill").foregroundStyle(Theme.proGreen)
            } else {
                Text(splitNote(list)).foregroundStyle(splitOff(list) ? Color.red : Color.secondary)
            }
        }

        Section {
            HStack {
                Text("ISRC"); Spacer()
                TextField("CC-XXX-YY-NNNNN", text: releaseBinding("isrc", upper: true)).multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
            }
            HStack {
                Text("UPC / EAN"); Spacer()
                TextField("12 or 13 digits", text: releaseBinding("upc", digits: true)).multilineTextAlignment(.trailing).keyboardType(.numberPad)
            }
            releaseDate
            HStack { Text("Label"); Spacer(); TextField("Independent", text: releaseBinding("label")).multilineTextAlignment(.trailing) }
            HStack { Text("Genre"); Spacer(); TextField("e.g. Indie pop", text: releaseBinding("genre")).multilineTextAlignment(.trailing) }
            Toggle("Explicit", isOn: Binding(get: { song?.releaseExplicit ?? false }, set: { v in
                guard var s = song else { return }
                s.setRelease("explicit", .bool(v)); s.touch(); library.put(s)
            }))
        } header: { Text("Release") } footer: {
            let notes = releaseNotes
            if !notes.isEmpty { Text(notes).foregroundStyle(.red) }
        }
    }

    @ViewBuilder private var releaseDate: some View {
        let raw = song?.releaseField("date") ?? ""
        let f = Self.dayFormat
        if let d = f.date(from: raw) {
            DatePicker("Release date", selection: Binding(get: { d }, set: { setReleaseDate(f.string(from: $0)) }), displayedComponents: .date)
                .swipeActions { Button("Clear", role: .destructive) { setReleaseDate("") } }
        } else {
            HStack {
                Text("Release date"); Spacer()
                Button("Add Date") { setReleaseDate(f.string(from: Date())) }
            }
        }
    }

    static let dayFormat: DateFormatter = {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"; return f
    }()

    private func setReleaseDate(_ v: String) {
        guard var s = song else { return }
        s.setRelease("date", .string(v)); s.touch(); library.put(s)
    }

    private var releaseNotes: String {
        guard let s = song else { return "" }
        var out: [String] = []
        let isrc = s.releaseField("isrc"), upc = s.releaseField("upc")
        if !isrc.isEmpty && isrc.range(of: #"^[A-Z]{2}-?[A-Z0-9]{3}-?\d{2}-?\d{5}$"#, options: .regularExpression) == nil {
            out.append("An ISRC looks like CC-XXX-YY-NNNNN (12 characters).")
        }
        if !upc.isEmpty && upc.range(of: #"^\d{12,13}$"#, options: .regularExpression) == nil {
            out.append("A UPC is 12 digits (13 for an EAN).")
        }
        return out.joined(separator: " ")
    }

    private func releaseBinding(_ k: String, upper: Bool = false, digits: Bool = false) -> Binding<String> {
        Binding(get: { song?.releaseField(k) ?? "" }, set: { v in
            guard var s = song else { return }
            var x = v
            if upper { x = x.uppercased() }
            if digits { x = x.filter(\.isNumber) }
            guard x != s.releaseField(k) else { return }
            s.setRelease(k, .string(x)); s.touch(); library.put(s)
        })
    }

    private func creditBinding(_ i: Int, _ kp: WritableKeyPath<Song.Credit, String>) -> Binding<String> {
        Binding(get: {
            let l = song?.credits ?? []
            return i < l.count ? l[i][keyPath: kp] : ""
        }, set: { v in
            guard var s = song else { return }
            var l = s.credits
            guard i < l.count else { return }
            var x = v
            if kp == \Song.Credit.split { x = x.filter { $0.isNumber || $0 == "." } }
            guard l[i][keyPath: kp] != x else { return }
            l[i][keyPath: kp] = x
            if kp == \Song.Credit.role && !l[i].hasSplit { l[i].split = "" }
            s.credits = l; s.touch(); library.put(s)
        })
    }

    private func addCredit() {
        guard var s = song else { return }
        Haptics.tap()
        var l = s.credits
        l.append(l.isEmpty ? Song.Credit(name: session.myName, role: "Writer", split: "100") : Song.Credit(name: "", role: "Writer", split: ""))
        s.credits = l; s.touch(); library.put(s)
    }

    private func removeCredit(_ i: Int) {
        guard var s = song else { return }
        Haptics.tap()
        var l = s.credits
        guard i < l.count else { return }
        l.remove(at: i)
        s.credits = l; s.touch(); library.put(s)
    }

    /// Even splits to two decimals, the remainder on the first writer.
    private func splitEvenly() {
        guard var s = song else { return }
        Haptics.tap()
        var l = s.credits
        let idx = l.indices.filter { l[$0].hasSplit }
        guard idx.count > 1 else { return }
        let each = (100.0 / Double(idx.count) * 100).rounded(.down) / 100
        let first = ((100 - each * Double(idx.count - 1)) * 100).rounded() / 100
        for (n, i) in idx.enumerated() { l[i].split = Self.pct(n == 0 ? first : each) }
        s.credits = l; s.touch(); library.put(s)
    }

    static func pct(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v).replacingOccurrences(of: #"0$"#, with: "", options: .regularExpression)
    }

    private func splitTotal(_ l: [Song.Credit]) -> Double? {
        let w = l.filter(\.hasSplit)
        guard !w.isEmpty, w.contains(where: { !$0.split.isEmpty }) else { return nil }
        return w.reduce(0) { $0 + (Double($1.split) ?? 0) }
    }
    private func splitOK(_ l: [Song.Credit]) -> Bool { if let t = splitTotal(l) { return abs(t - 100) <= 0.01 }; return false }
    private func splitOff(_ l: [Song.Credit]) -> Bool { if let t = splitTotal(l) { return abs(t - 100) > 0.01 }; return false }
    private func splitNote(_ l: [Song.Credit]) -> String {
        guard let t = splitTotal(l) else { return "Splits should add up to 100%." }
        if abs(t - 100) <= 0.01 { return "Writer splits total 100%." }
        return "Writer splits add up to \(Self.pct((t * 100).rounded() / 100))%. They should total 100%."
    }

    // MARK: bindings

    private func field(_ label: String, _ kp: WritableKeyPath<Song, String>, prompt: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(prompt, text: binding(kp)).multilineTextAlignment(.trailing)
        }
    }

    private func set(_ kp: WritableKeyPath<Song, String>, _ v: String) {
        guard var s = song, s[keyPath: kp] != v else { return }
        s[keyPath: kp] = v; s.touch(); library.put(s)
    }

    private func binding(_ kp: WritableKeyPath<Song, String>) -> Binding<String> {
        Binding(get: { song?[keyPath: kp] ?? "" }, set: { set(kp, $0) })
    }
}
