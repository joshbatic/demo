import Foundation
import Supabase

/// The one Supabase client. Sessions are kept in the Keychain and refreshed automatically (PKCE).
nonisolated enum Backend {
    static let client = SupabaseClient(supabaseURL: Config.supabaseURL, supabaseKey: Config.supabaseAnonKey)

    /// Calls an RPC and returns its JSON result (any shape).
    static func rpc(_ name: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        let res = try await client.rpc(name, params: params).execute()
        if res.data.isEmpty { return .null }
        return (try? JSONDecoder().decode(JSONValue.self, from: res.data)) ?? .null
    }

    /// Calls an edge function. Several of them report problems as HTTP 200 with an `error` field (spec §7.1),
    /// so the caller checks `["error"]` on the result rather than relying on the status.
    static func function(_ name: String, body: [String: JSONValue]) async throws -> JSONValue {
        try await client.functions.invoke(name, options: FunctionInvokeOptions(body: body)) { data, _ in
            (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
        }
    }
}

/// A readable message for anything Supabase throws.
nonisolated func describe(_ error: Error) -> String {
    if let e = error as? PostgrestError { return e.message }
    if let e = error as? AuthError { return e.localizedDescription }
    let s = (error as NSError).localizedDescription
    return s.isEmpty ? "Something went wrong." : s
}
