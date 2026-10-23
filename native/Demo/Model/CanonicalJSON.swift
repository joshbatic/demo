import Foundation

/// The web app's `libStr`: JSON with object keys sorted at every level, written compactly the way
/// JavaScript's JSON.stringify does. Sync compares these strings to tell whether anything changed,
/// and to break ties between two copies with the same `updated` time, so the output has to match
/// the web's byte for byte: same number formatting, same string escaping.
nonisolated enum CanonicalJSON {
    static func string(_ v: JSONValue) -> String {
        var out = ""
        out.reserveCapacity(1024)
        write(v, &out)
        return out
    }

    private static func write(_ v: JSONValue, _ out: inout String) {
        switch v {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += number(n)
        case .string(let s): quote(s, &out)
        case .array(let a):
            out += "["
            for (i, x) in a.enumerated() { if i > 0 { out += "," }; write(x, &out) }
            out += "]"
        case .object(let o):
            out += "{"
            // JS sorts keys by UTF-16 code units (Array.prototype.sort on strings)
            let keys = o.keys.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }
            for (i, k) in keys.enumerated() {
                if i > 0 { out += "," }
                quote(k, &out); out += ":"; write(o[k]!, &out)
            }
            out += "}"
        }
    }

    /// Numbers as JavaScript prints them: integers without a decimal point, others in the shortest
    /// form that round-trips, exponent form only outside 1e-7…1e21.
    static func number(_ n: Double) -> String {
        if !n.isFinite { return "null" }
        if n == 0 { return "0" }
        if n.rounded() == n && abs(n) < 1e21 {
            return String(format: "%.0f", n)
        }
        let a = abs(n)
        if a >= 1e-7 && a < 1e21 {
            // Swift's description is the shortest round-trip form, like JS, but may use exponents below 1e-4
            var s = "\(n)"
            if s.contains("e") { s = expandExponent(s) }
            return s
        }
        // JS style exponent: 1e+21, 1.5e-8
        var s = "\(n)"
        if let r = s.range(of: "e") {
            let mant = String(s[s.startIndex..<r.lowerBound])
            var exp = String(s[r.upperBound...])
            if !exp.hasPrefix("-") && !exp.hasPrefix("+") { exp = "+" + exp }
            if exp.hasPrefix("+0") || exp.hasPrefix("-0") { exp = String(exp.prefix(1)) + String(Int(exp.dropFirst()) ?? 0) }
            s = mant + "e" + exp
        }
        return s
    }

    private static func expandExponent(_ s: String) -> String {
        guard let d = Decimal(string: s) else { return s }
        return NSDecimalNumber(decimal: d).stringValue
    }

    /// JSON.stringify string escaping: quote, backslash and control characters only; everything else literal.
    private static func quote(_ s: String, _ out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        out += "\""
    }
}
