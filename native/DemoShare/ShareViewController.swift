import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// "Save to *[demo]" in the share sheet, for Notes (text) and Voice Memos (audio).
/// The extension can't reach the library, so it leaves each share in the app group's Inbox folder (a small JSON
/// file, and the audio beside it); the app brings them in next time it opens (ShareInbox in Onboarding.swift).
/// Keep `InboxItem` the same as `ShareInbox.Item` there.
let appGroup = "group.app.hellodemo.demo"

struct InboxItem: Codable {
    var id: String
    var kind: String        // "text" or "audio"
    var mode: String        // "song", "idea" or "append"
    var title: String
    var text: String
    var file: String?
    var songID: String?
    var at: Double
}

/// The few things the extension reads from what the app writes for its widgets: signed in, and recent songs.
struct WidgetSnapshot: Decodable {
    struct Item: Decodable { var id: String; var title: String }
    var signedIn: Bool
    var songs: [Item]
}

@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.finish = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        model.cancel = { [weak self] in
            self?.extensionContext?.cancelRequest(withError: NSError(domain: "demo.share", code: 0))
        }
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        Task { await model.load(items.flatMap { $0.attachments ?? [] }) }
    }
}

@MainActor @Observable
final class ShareModel {
    enum Phase { case loading, ready, nothing, signedOut, saved }
    var phase: Phase = .loading
    var text = ""
    var audio: URL?
    var title = ""
    var mode = "song"
    var songID: String?
    var recent: [WidgetSnapshot.Item] = []
    var finish: () -> Void = {}
    var cancel: () -> Void = {}

    var inbox: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appendingPathComponent("Inbox", isDirectory: true)
    }

    func load(_ providers: [NSItemProvider]) async {
        if let d = UserDefaults(suiteName: appGroup)?.data(forKey: "widget.snapshot"),
           let s = try? JSONDecoder().decode(WidgetSnapshot.self, from: d) {
            guard s.signedIn else { phase = .signedOut; return }
            recent = s.songs
            songID = s.songs.first?.id
        }
        for p in providers where audio == nil && p.hasItemConformingToTypeIdentifier(UTType.audio.identifier) {
            audio = await copyAudio(p)
            if let a = audio {
                // Voice Memos names the file after the recording
                title = (p.suggestedName ?? a.deletingPathExtension().lastPathComponent)
                    .replacingOccurrences(of: #"^[0-9a-f-]{36}$"#, with: "Voice memo", options: .regularExpression)
            }
        }
        if audio == nil {
            for p in providers where text.isEmpty {
                if let t = await loadText(p) { text = t }
            }
            text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\u{2028}", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            title = text.components(separatedBy: "\n").first.map { String($0.trimmingCharacters(in: .whitespaces).prefix(80)) } ?? ""
        }
        phase = audio != nil || !text.isEmpty ? .ready : .nothing
    }

    private func loadText(_ p: NSItemProvider) async -> String? {
        for t in [UTType.plainText, .utf8PlainText, .text] where p.hasItemConformingToTypeIdentifier(t.identifier) {
            if let s = try? await p.loadItem(forTypeIdentifier: t.identifier) as? String, !s.isEmpty { return s }
        }
        for (t, kind) in [(UTType.rtf, NSAttributedString.DocumentType.rtf), (.html, .html)] where p.hasItemConformingToTypeIdentifier(t.identifier) {
            if let d = try? await p.loadItem(forTypeIdentifier: t.identifier) as? Data,
               let a = try? NSAttributedString(data: d, options: [.documentType: kind], documentAttributes: nil) { return a.string }
        }
        if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let u = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL,
           let s = try? String(contentsOf: u, encoding: .utf8) { return s }
        return nil
    }

    private func copyAudio(_ p: NSItemProvider) async -> URL? {
        guard let dir = inbox else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return await withCheckedContinuation { c in
            _ = p.loadFileRepresentation(forTypeIdentifier: UTType.audio.identifier) { url, _ in
                guard let url else { c.resume(returning: nil); return }
                let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension
                let dest = dir.appendingPathComponent(UUID().uuidString.lowercased() + "." + ext)
                do { try FileManager.default.copyItem(at: url, to: dest); c.resume(returning: dest) } catch { c.resume(returning: nil) }
            }
        }
    }

    func save() {
        guard let dir = inbox else { cancel(); return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let item = InboxItem(id: id, kind: audio != nil ? "audio" : "text", mode: audio != nil ? "idea" : mode,
                             title: title.trimmingCharacters(in: .whitespacesAndNewlines), text: text,
                             file: audio?.lastPathComponent, songID: mode == "append" ? songID : nil,
                             at: Date().timeIntervalSince1970 * 1000)
        if let d = try? JSONEncoder().encode(item) { try? d.write(to: dir.appendingPathComponent(id + ".json"), options: .atomic) }
        phase = .saved
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { self.finish() }
    }

    func discard() {
        if let a = audio { try? FileManager.default.removeItem(at: a) }
        cancel()
    }
}

struct ShareView: View {
    @Bindable var model: ShareModel

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .loading: ProgressView()
                case .signedOut: message("Sign in to *[demo] first", "Open *[demo] and sign in, then share again.")
                case .nothing: message("Nothing to bring in", "*[demo] can take text from Notes and recordings from Voice Memos.")
                case .saved: message("Saved to *[demo]", model.audio != nil ? "It’ll be in Ideas when you open *[demo]." : "It’ll be there when you open *[demo].", icon: "checkmark.circle.fill")
                case .ready: form
                }
            }
            .navigationTitle("Save to *[demo]")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.discard() } }
                if model.phase == .ready {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { model.save() }.fontWeight(.semibold)
                            .disabled(model.mode == "append" && model.songID == nil)
                    }
                }
            }
        }
    }

    private var form: some View {
        Form {
            if model.audio != nil {
                Section {
                    TextField("Name", text: $model.title)
                } footer: { Text("The recording goes into Ideas, ready to start a song with.") }
            } else {
                Picker("Save as", selection: $model.mode) {
                    Text("New song").tag("song")
                    if !model.recent.isEmpty { Text("Add to a song").tag("append") }
                    Text("Idea").tag("idea")
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                if model.mode == "song" {
                    Section { TextField("Title", text: $model.title) }
                } else if model.mode == "append" {
                    Section {
                        Picker("Song", selection: $model.songID) {
                            ForEach(model.recent, id: \.id) { s in Text(s.title).tag(Optional(s.id)) }
                        }
                    } footer: { Text("Added at the end of the song. Your recent songs are listed.") }
                }
                Section {
                    Text(model.text).font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(14)
                } header: {
                    let n = model.text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
                    Text("\(n) \(n == 1 ? "line" : "lines")")
                } footer: {
                    if model.mode != "idea" { Text("Headings like “Chorus” on their own line become sections.") }
                }
            }
        }
    }

    private func message(_ t: String, _ s: String, icon: String? = nil) -> some View {
        VStack(spacing: 10) {
            if let icon { Image(systemName: icon).font(.system(size: 44)).foregroundStyle(.green) }
            Text(t).font(.title3.weight(.semibold))
            Text(s).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(32)
    }
}
