import Foundation

/// Talks to Zotero on this Mac through the Better BibTeX add-on's local server (127.0.0.1:23119): search the
/// library, then export the chosen items as BibTeX. Nothing goes over the internet.
enum Zotero {
    struct Item: Identifiable, Hashable {
        var id: String { citekey }
        let citekey: String
        let title: String
        let authors: String
        let year: String
    }

    enum Failure: LocalizedError {
        case notRunning, bad(String)
        var errorDescription: String? {
            switch self {
            case .notRunning: "Zotero isn't reachable. Open Zotero with the Better BibTeX add-on installed (free, from retorque.re/zotero-better-bibtex)."
            case .bad(let m): m
            }
        }
    }

    static let base = URL(string: "http://127.0.0.1:23119/better-bibtex")!

    /// True when Zotero with Better BibTeX is running.
    static func isReady() async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("cayw").appending(queryItems: [URLQueryItem(name: "probe", value: "true")]))
        req.timeoutInterval = 1.5
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return false }
        return String(data: data, encoding: .utf8)?.contains("ready") == true
    }

    private static func call(_ method: String, _ params: [Any]) async throws -> Any {
        var req = URLRequest(url: base.appendingPathComponent("json-rpc"))
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": method, "params": params, "id": 1])
        let data: Data
        do { (data, _) = try await URLSession.shared.data(for: req) } catch { throw Failure.notRunning }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.bad("Zotero sent an unexpected reply.") }
        if let err = obj["error"] as? [String: Any] { throw Failure.bad((err["message"] as? String) ?? "Zotero reported an error.") }
        return obj["result"] ?? NSNull()
    }

    /// Quick search over titles, authors, years and citation keys.
    static func search(_ terms: String) async throws -> [Item] {
        guard let list = try await call("item.search", [terms]) as? [[String: Any]] else { return [] }
        return list.compactMap { d in
            guard let key = (d["citekey"] ?? d["citationKey"] ?? d["citation-key"]) as? String, !key.isEmpty else { return nil }
            let authors = ((d["author"] as? [[String: Any]]) ?? []).prefix(3).map { ($0["family"] as? String) ?? ($0["literal"] as? String) ?? "" }.filter { !$0.isEmpty }
            let parts = ((d["issued"] as? [String: Any])?["date-parts"] as? [[Any]])?.first?.first
            let year = parts.map { "\($0)" } ?? ""
            return Item(citekey: key, title: (d["title"] as? String) ?? key, authors: authors.joined(separator: ", ") + (authors.count == 3 ? " et al." : ""), year: year)
        }
    }

    /// BibTeX for these citation keys, exactly as Better BibTeX writes it.
    static func bibtex(_ keys: [String]) async throws -> String {
        let result = try await call("item.export", [keys, "Better BibTeX"])
        if let s = result as? String { return s }
        if let arr = result as? [Any], let s = arr.compactMap({ $0 as? String }).last { return s }   // older versions wrapped it
        throw Failure.bad("Zotero didn't return BibTeX for that item.")
    }
}
