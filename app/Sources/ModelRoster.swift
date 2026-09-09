import Foundation

/// The embedding models this install can use, read from `apple-index model`.
///
/// 🛑 THE ROSTER IS NOT A CONSTANT, and hard-coding it here would recreate the
/// bug it exists to fix. `--model` accepted six names on every install while a
/// shipped one could run two: the three PyTorch models need `uv` and
/// `embed_oss.py`, neither of which ships. A name that cannot run was accepted,
/// embedded nothing, and left every search answering lexically in silence. Only
/// `index.py` knows what is present, so only it can answer this.
struct ModelChoice: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let summary: String
    let available: Bool
    let current: Bool
    /// Why it cannot run here. ⚠️ Shown instead of hiding the row: a model that
    /// vanishes from the list reads as one that was removed.
    let unavailableBecause: String?
    /// Longest chunk it was trained on, when the roster says.
    let window: Int?
}

enum ModelRoster {
    /// Ask `index.py`. Returns an empty list when it cannot be asked, which the
    /// window draws as "unavailable" rather than as "no models exist".
    static func read() -> [ModelChoice] {
        guard let script = Paths.indexScript else { return [] }
        let result = Child.run(Paths.python,
                               [script.path, "--db", Paths.database.path,
                                "model", "--json"],
                               timeout: 30)
        guard result.ok, let data = result.out.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let rows = root["models"] as? [[String: Any]] else { return [] }
        return rows.map {
            ModelChoice(name: $0["model"] as? String ?? "?",
                        summary: $0["summary"] as? String ?? "",
                        available: $0["available"] as? Bool ?? false,
                        current: $0["current"] as? Bool ?? false,
                        unavailableBecause: $0["unavailable_because"] as? String,
                        window: $0["window"] as? Int)
        }
    }
}
