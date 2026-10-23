import Foundation
import Observation

/// Every AI request goes through here (engines.md §2.1): the consent card the first time, the local
/// request guard, then the `ai-proxy` edge function, whose answer is always JSON.
@MainActor @Observable
final class AIService {
    static let shared = AIService()

    /// Set while the "Use AI features?" card is up; RootView shows it.
    var askingConsent = false
    @ObservationIgnored private var consentWaiters: [CheckedContinuation<Bool, Never>] = []

    enum AIError: LocalizedError {
        case off, notAllowed, message(String)
        var errorDescription: String? {
            switch self {
            case .off: "AI features are off. Turn them on in Account › AI Features."
            case .notAllowed: "Allow access to use this."
            case .message(let m): m
            }
        }
    }

    static let consentMessage = "Lines, Muse, Rate, Writing voice and lyric sync send what you’re working on (your lyrics, the song brief and, for lyric sync, a low-quality copy of the audio) to OpenAI to write suggestions. It’s used only to answer each request, not to train models."

    /// "yes", "no" or "" (not asked yet), per device.
    var consent: String = UserDefaults.standard.string(forKey: "songpad:aiconsent") ?? "" {
        didSet {
            if consent.isEmpty { UserDefaults.standard.removeObject(forKey: "songpad:aiconsent") }
            else { UserDefaults.standard.set(consent, forKey: "songpad:aiconsent") }
        }
    }

    /// `ask`: the request came from a tap, so the card may be shown. Background requests never ask.
    func ensureConsent(ask: Bool) async throws {
        switch consent {
        case "yes": return
        case "no": throw AIError.off
        default:
            guard ask else { throw AIError.off }
            let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                consentWaiters.append(c)
                askingConsent = true
            }
            if !ok { throw AIError.off }
        }
    }

    func answerConsent(_ allow: Bool) {
        consent = allow ? "yes" : "no"
        askingConsent = false
        let w = consentWaiters
        consentWaiters = []
        w.forEach { $0.resume(returning: allow) }
    }

    /// The local guard: 20 a minute, 400 a day (bakedGuardCall).
    private func guardCall() throws {
        let d = UserDefaults.standard
        let day = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        var stamps = (d.array(forKey: "ai.minute") as? [Double]) ?? []
        let now = Date().timeIntervalSince1970
        stamps = stamps.filter { now - $0 < 60 }
        var count = d.double(forKey: "ai.day") == day ? d.integer(forKey: "ai.count") : 0
        if stamps.count >= 20 { throw AIError.message("That’s a lot of requests in a minute. Give it a moment.") }
        if count >= 400 { throw AIError.message("You’ve reached today’s limit for AI suggestions. It resets tomorrow.") }
        stamps.append(now); count += 1
        d.set(stamps, forKey: "ai.minute"); d.set(day, forKey: "ai.day"); d.set(count, forKey: "ai.count")
    }

    /// Sends a prompt and returns the JSON it answered with. `complex` uses the stronger model (Rate, the voice profile).
    func json(_ prompt: String, complex: Bool = false, ask: Bool = true) async throws -> JSONValue {
        try await ensureConsent(ask: ask)
        guard !prompt.isEmpty else { throw AIError.message("Empty prompt.") }
        guard prompt.count <= 24000 else { throw AIError.message("That request is too large to send (\(prompt.count) characters, limit 24000).") }
        try guardCall()
        var body: [String: JSONValue] = ["prompt": .string(prompt)]
        if complex { body["modelTier"] = "complex" }
        let res: JSONValue
        do { res = try await Backend.function("ai-proxy", body: body) }
        catch { throw AIError.message(describe(error)) }
        if let e = res["error"]?.string { throw AIError.message(e) }
        let text = res["text"]?.string ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.message("AI returned an empty response.") }
        return try Self.parse(text)
    }

    /// parseAIJson: the whole text, else a ```json fence, else the first [ or { to the last ] or }.
    nonisolated static func parse(_ raw: String) throws -> JSONValue {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        func decode(_ s: String) -> JSONValue? { try? JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }
        if let v = decode(text) { return v }
        if let m = text.firstMatch(of: #/```(?:json)?\s*([\s\S]*?)```/#.ignoresCase()), let v = decode(String(m.1).trimmingCharacters(in: .whitespacesAndNewlines)) { return v }
        if let s = text.firstIndex(where: { $0 == "[" || $0 == "{" }),
           let e = text.lastIndex(where: { $0 == "]" || $0 == "}" }), s < e,
           let v = decode(String(text[s...e])) { return v }
        throw AIError.message("Could not parse response as JSON")
    }
}

nonisolated extension JSONValue {
    /// The strings in an array answer, trimmed, empties dropped.
    var stringList: [String] {
        (array ?? []).compactMap { $0.string?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
