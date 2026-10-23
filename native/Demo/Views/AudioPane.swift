import SwiftUI
import QuickLook
import UniformTypeIdentifiers

/// Details › Audio (spec §2.1): audio versions, lyric sync and stems & files. Adding is Pro.
struct AudioPane: View {
    let songID: String
    var onPlayWithLyrics: () -> Void
    @Environment(AppSession.self) private var session
    @Environment(LibraryStore.self) private var library
    @State private var busy: [Busy] = []
    @State private var openID: String?
    @State private var armedDelete: String?
    @State private var importing = false
    @State private var importAudio = true
    @State private var preview: URL?
    private var player: AudioPlayer { AudioPlayer.shared }

    struct Busy: Identifiable { let id = UUID(); var audio: Bool; var status: String }

    private var song: Song? { library.song(songID) }

    var body: some View {
        Group {
            versions
            if let s = song, let cur = s.currentAudio { syncSection(s, cur) }
            files
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: importAudio ? [.audio, .mpeg4Audio, .mp3, .wav, .aiff] : [.item],
                      allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { for u in urls { Task { await add(u, audio: importAudio) } } }
        }
        .quickLookPreview($preview)
        .onChange(of: player.error) { _, e in if let e { session.toast = e; player.error = nil } }
    }

    // MARK: versions

    private var versions: some View {
        Section {
            let items = song?.audioItems ?? []
            if items.isEmpty && busy.filter(\.audio).isEmpty {
                Text("Add a voice memo, demo, mix or master").foregroundStyle(.secondary)
            }
            ForEach(busy.filter(\.audio)) { b in busyRow(b) }
            ForEach(items.reversed()) { a in row(a, audio: true) }
        } header: {
            sectionHeader("Versions") { startImport(audio: true) }
        }
    }

    private var files: some View {
        Section {
            let items = song?.fileItems ?? []
            if items.isEmpty && busy.filter({ !$0.audio }).isEmpty {
                Text("Attach stems, artwork or session files").foregroundStyle(.secondary)
            }
            ForEach(busy.filter { !$0.audio }) { b in busyRow(b) }
            ForEach(items) { f in row(f, audio: false) }
        } header: {
            sectionHeader("Stems & files") { startImport(audio: false) }
        }
    }

    private func sectionHeader(_ title: String, add: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button("Add", action: add).font(.subheadline.weight(.semibold)).textCase(nil)
        }
    }

    private func busyRow(_ b: Busy) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(b.status).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    @ViewBuilder private func row(_ a: FileItem, audio: Bool) -> some View {
        let mine = a.isMine(session.userID)
        let canPlay = session.plan.isPro || mine
        let k = AudioPlayer.key(song: songID, item: a.id)
        let playing = player.isActive(k) && player.isPlaying
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if audio {
                    Button { setCurrent(a) } label: {
                        Image(systemName: a.isCurrent ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22)).foregroundStyle(a.isCurrent ? Theme.proGreen : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(a.isCurrent ? "Current version" : "Make this the current version")
                } else {
                    Image(systemName: fileIcon(a.kind)).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(fileColor(a.kind), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                Button { Haptics.selection(); withAnimation(.snappy(duration: 0.33)) { openID = openID == a.id ? nil : a.id; armedDelete = nil } } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.name.isEmpty ? (audio ? "Recording" : "File") : a.name).foregroundStyle(.primary).lineLimit(1)
                        Text(meta(a, audio: audio)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button {
                    guard canPlay else { lockedToast(audio); return }
                    Haptics.tap()
                    if audio { player.toggle(k, item: a, fallbackDuration: a.dur) } else { open(a) }
                } label: {
                    Image(systemName: !canPlay ? "lock.fill" : audio ? (playing ? "pause.fill" : "play.fill") : "arrow.up.right.square")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.tint)
                        .frame(width: 36, height: 36).background(BarFill.color, in: Circle())
                }
                .buttonStyle(PressScale())
                .accessibilityLabel(audio ? (playing ? "Pause" : "Play") : "Open")
            }
            if openID == a.id { editor(a, audio: audio, mine: mine) }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func editor(_ a: FileItem, audio: Bool, mine: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 6) {
                ForEach(audio ? SongFiles.audioKinds : SongFiles.fileKinds, id: \.self) { k in
                    Button { update(a.id, audio: audio) { $0.kind = k }; Haptics.selection() } label: {
                        Text(k).font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(a.kind == k ? Theme.onTint : Theme.tint)
                            .padding(.horizontal, 13).frame(height: 30)
                            .background(a.kind == k ? Theme.tint : BarFill.color, in: Capsule())
                    }
                    .buttonStyle(PressScale())
                }
            }
            TextField("Name", text: Binding(get: { a.name }, set: { v in update(a.id, audio: audio) { $0.name = v } }))
                .padding(.horizontal, 12).frame(height: 38)
                .background(BarFill.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack {
                if audio && mine && SongFiles.needsConversion(a.ext) {
                    Button("Convert to \(SongFiles.convertName)") { Task { await convert(a) } }.buttonStyle(.bordered)
                }
                Spacer()
                Button(armedDelete == a.id ? "Tap Again to Delete" : "Delete", role: .destructive) { delete(a, audio: audio) }
                    .buttonStyle(.bordered)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func meta(_ a: FileItem, audio: Bool) -> String {
        var p = [a.kind]
        if audio && a.dur > 0 { p.append(SongFiles.time(a.dur)) }
        let sz = SongFiles.size(a.size); if !sz.isEmpty { p.append(sz) }
        if let o = a.origExt { p.append("\(a.ext.uppercased()) from \(o)") }
        return p.joined(separator: " · ")
    }

    private func fileIcon(_ kind: String) -> String {
        switch kind { case "Stem": "waveform"; case "Artwork": "photo"; case "Session": "slider.horizontal.3"; default: "doc" }
    }
    private func fileColor(_ kind: String) -> Color {
        switch kind { case "Stem": Theme.Tile.indigo; case "Artwork": Theme.Tile.orange; case "Session": Theme.Tile.teal; default: Theme.Tile.gray }
    }

    // MARK: lyric sync

    private func syncSection(_ s: Song, _ cur: FileItem) -> some View {
        let synced = s.syncAudioID == cur.id && !s.syncLines.isEmpty
        let timed = s.syncLines.filter { $0.t != nil }.count
        return Section("Lyric sync") {
            Group {
                if LyricSync.shared.busySong == songID {
                    HStack(spacing: 10) { ProgressView(); Text(LyricSync.shared.progressText(cur.name)) }
                } else if synced {
                    Text(LocalizedStringKey("**Synced** to “\(cur.name)”: \(timed) of \(s.syncLines.count) lines heard." + (s.syncIsStale ? " Lyrics changed since. Sync again to update." : "")))
                } else if s.syncAudioID != nil && !s.syncLines.isEmpty {
                    Text("Synced to another version.")
                } else {
                    Text("Time every line to “\(cur.name)”.")
                }
            }
            .font(.subheadline).foregroundStyle(.secondary)
            Button(synced ? "Sync Again" : "Sync Lyrics") {
                Task { await LyricSync.shared.run(songID: songID, library: library, session: session) }
            }
            .disabled(LyricSync.shared.busySong != nil)
            Button("Play with Lyrics") {
                guard session.plan.isPro else { session.upsell("play"); return }
                onPlayWithLyrics()
            }
            if synced, let url = lrcFile(s) {
                ShareLink(item: url) { Text("Export .lrc") }
            }
        }
    }

    /// The synced lyrics as an .lrc file (lrcText).
    private func lrcFile(_ s: Song) -> URL? {
        var out: [String] = []
        if !s.title.isEmpty { out.append("[ti:\(s.title)]") }
        if !s.artist.isEmpty { out.append("[ar:\(s.artist)]") }
        if let a = s.audioItems.first(where: { $0.id == s.syncAudioID }), a.dur > 0 { out.append("[length:\(SongFiles.time(a.dur))]") }
        out.append("[re:*[demo]]")
        for l in s.syncLines { if let t = l.t { out.append(Self.stamp(t) + l.text) } }
        let name = (s.title.isEmpty ? "Untitled" : s.title).replacingOccurrences(of: "/", with: "-") + ".lrc"
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        guard (try? (out.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        return url
    }

    static func stamp(_ t: Double) -> String {
        let x = max(0, t), m = Int(x / 60), s = x - Double(m * 60)
        return "[" + (m < 10 ? "0" : "") + "\(m):" + (s < 10 ? "0" : "") + String(format: "%.2f", s) + "]"
    }

    // MARK: actions

    private func startImport(audio: Bool) {
        guard session.plan.isPro else {
            session.upsell("audio")
            return
        }
        importAudio = audio
        importing = true
    }

    private func lockedToast(_ audio: Bool) {
        session.upsell("audio", audio ? "A co-writer added this recording. Go Pro to listen and add your own."
                                      : "A co-writer added this file. Go Pro to open it and add your own.")
    }

    private func open(_ a: FileItem) {
        Task {
            do { preview = try await SongFiles.namedCopy(a) }
            catch { session.toast = "Couldn’t open it: " + SongFiles.message(error) }
        }
    }

    private func setCurrent(_ a: FileItem) {
        guard !a.isCurrent, var s = song else { return }
        Haptics.selection()
        s.audioItems = s.audioItems.map { var x = $0; x.isCurrent = x.id == a.id; return x }
        s.touch(); library.put(s)
        session.toast = "“\(a.name)” is now the current version"
    }

    private func update(_ id: String, audio: Bool, _ change: (inout FileItem) -> Void) {
        guard var s = song else { return }
        if audio {
            var l = s.audioItems; guard let i = l.firstIndex(where: { $0.id == id }) else { return }
            change(&l[i]); s.audioItems = l
        } else {
            var l = s.fileItems; guard let i = l.firstIndex(where: { $0.id == id }) else { return }
            change(&l[i]); s.fileItems = l
        }
        s.touch(); library.put(s)
    }

    private func delete(_ a: FileItem, audio: Bool) {
        guard armedDelete == a.id else { Haptics.selection(); armedDelete = a.id; return }
        guard var s = song else { return }
        Haptics.thud()
        if audio {
            var l = s.audioItems.filter { $0.id != a.id }
            if a.isCurrent, !l.isEmpty { l[l.count - 1].isCurrent = true }
            s.audioItems = l
            if s.syncAudioID == a.id { s.raw.removeValue(forKey: "sync") }
            if player.isActive(AudioPlayer.key(song: songID, item: a.id)) { player.stop() }
        } else {
            s.fileItems = s.fileItems.filter { $0.id != a.id }
        }
        s.tombstoneFile(a.id)
        s.touch(); library.put(s)
        armedDelete = nil; openID = nil
        if a.isLocal { if let u = SongFiles.localFile(for: a) { try? FileManager.default.removeItem(at: u) } }
        else if a.isMine(session.userID) { Task { await SongFiles.remove(a.path) } }
        session.toast = "Deleted “\(a.name)”"
    }

    /// Adds one picked file: converts WAV / AIFF / FLAC to AAC, uploads it (or keeps it on the device when
    /// signed out), and for audio works out the length and waveform. New audio becomes the current version.
    private func add(_ picked: URL, audio: Bool) async {
        let fileName = picked.lastPathComponent
        let display = SongFiles.baseName(fileName)
        var b = Busy(audio: audio, status: "Uploading “\(display)”…")
        busy.append(b)
        defer { busy.removeAll { $0.id == b.id } }
        func status(_ t: String) { b.status = t; if let i = busy.firstIndex(where: { $0.id == b.id }) { busy[i].status = t } }
        do {
            let scoped = picked.startAccessingSecurityScopedResource()
            defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
            let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var local = dir.appending(path: fileName)
            try FileManager.default.copyItem(at: picked, to: local)
            var ext = SongFiles.ext(fileName, mime: "")
            var orig: JSONValue?
            var saved: Double = 0
            if audio && SongFiles.needsConversion(ext) {
                status("Converting “\(display)” to \(SongFiles.convertName)…")
                let before = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.doubleValue ?? 0
                let (converted, newExt, _) = try await SongFiles.convertForUpload(local)
                orig = .object(["name": .string(fileName), "size": .number(before), "mime": .string(SongFiles.mime(forExt: ext))])
                local = converted; ext = newExt
                let after = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.doubleValue ?? 0
                saved = max(0, before - after)
            }
            let data = try Data(contentsOf: local)
            let id = UUID().uuidString.lowercased()
            let mime = SongFiles.mime(forExt: ext)
            var path: String
            if let uid = session.userID {
                status("Uploading “\(display)”…")
                path = "\(uid)/\(songID)/\(id).\(ext)"
                try await SongFiles.upload(data, to: path, mime: mime)
            } else {
                path = "local:\(id)"
                try data.write(to: SongFiles.localURL(id, ext: ext))
            }
            var r: [String: JSONValue] = ["id": .string(id), "name": .string(display), "path": .string(path), "size": .number(Double(data.count)),
                                          "mime": .string(mime), "added": .number(Clock.nowMs),
                                          "kind": .string(audio ? SongFiles.audioKind(fileName) : SongFiles.fileKind(fileName, mime: mime))]
            if let orig { r["orig"] = orig }
            if audio {
                r["dur"] = .number(await SongFiles.duration(local))
                r["peaks"] = .array(await SongFiles.peaks(local).map { .number(Double($0)) })
                r["cur"] = .bool(true)
            }
            guard var s = library.song(songID) else { return }
            if audio {
                s.audioItems = s.audioItems.map { var x = $0; x.isCurrent = false; return x } + [FileItem(raw: r)]
            } else {
                s.fileItems = s.fileItems + [FileItem(raw: r)]
            }
            s.touch(); library.put(s)
            Haptics.success()
            session.toast = saved > 1_048_576 ? "Added “\(display)” as \(ext.uppercased()), saving \(SongFiles.size(saved))" : "Added “\(display)”"
            try? FileManager.default.removeItem(at: dir)
        } catch {
            Haptics.warning()
            session.toast = "Couldn’t upload “\(display)”: " + SongFiles.message(error)
        }
    }

    /// An uploaded WAV / AIFF / FLAC becomes AAC: a new file id and path, the original noted in `orig`.
    private func convert(_ a: FileItem) async {
        let b = Busy(audio: true, status: "Converting “\(a.name)” to \(SongFiles.convertName)…")
        busy.append(b)
        defer { busy.removeAll { $0.id == b.id } }
        do {
            let src = try await SongFiles.namedCopy(a)
            let (out, ext, mime) = try await SongFiles.convertForUpload(src)
            let data = try Data(contentsOf: out)
            let id = UUID().uuidString.lowercased()
            var path = "local:\(id)"
            if let uid = session.userID, !a.isLocal {
                path = "\(uid)/\(songID)/\(id).\(ext)"
                try await SongFiles.upload(data, to: path, mime: mime)
            } else {
                try data.write(to: SongFiles.localURL(id, ext: ext))
            }
            guard var s = library.song(songID), let i = s.audioItems.firstIndex(where: { $0.id == a.id }) else { return }
            var item = s.audioItems[i]
            item.raw["id"] = .string(id)
            item.raw["path"] = .string(path)
            item.raw["size"] = .number(Double(data.count))
            item.raw["mime"] = .string(mime)
            item.raw["orig"] = .object(["name": .string(a.name + "." + a.ext), "size": .number(a.size), "mime": .string(a.mime)])
            var l = s.audioItems; l[i] = item; s.audioItems = l
            if s.syncAudioID == a.id, var sync = s.raw["sync"]?.object { sync["audioId"] = .string(id); s.raw["sync"] = .object(sync) }
            s.tombstoneFile(a.id)
            s.touch(); library.put(s)
            if a.isLocal { if let u = SongFiles.localFile(for: a) { try? FileManager.default.removeItem(at: u) } } else { await SongFiles.remove(a.path) }
            openID = nil
            Haptics.success()
            session.toast = "Converted “\(a.name)”, saving \(SongFiles.size(max(0, a.size - Double(data.count))))"
        } catch {
            session.toast = "Couldn’t convert “\(a.name)”: " + SongFiles.message(error)
        }
    }
}
