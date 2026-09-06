import Foundation

/// Decides which configured warm models are not currently resident. Kept free of I/O so the
/// decision is unit-testable against real `/api/ps` shapes.
///
/// Why this exists: `OLLAMA_KEEP_ALIVE=-1` pins a model only until something evicts it. On the
/// MLX runner the prefix cache fills to its hard-coded 8 GiB, a request burst then tips the host
/// into a Metal OOM, and Ollama's recovery evicts every loaded model. The guardian used to warm
/// the set only at startup, so after each OOM the small models stayed unloaded until a human
/// noticed -- three times in the week of 2026-09-01. The same gap also swallowed a subtler case:
/// a client sending its own `keep_alive` ("60m") re-stamps the shared model's expiry and un-pins
/// it fleet-wide.
enum WarmSetRepair {
    /// Minimum spacing between repair attempts for the same model. A warm request against a
    /// model that is mid-load just queues behind the load, so retrying faster gains nothing.
    static let minimumInterval: TimeInterval = 60

    /// Ollama reports `nomic-embed-text:latest` while a config may say `nomic-embed-text`;
    /// treat the two as the same model.
    static func canonicalName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix(":latest") ? String(trimmed.dropLast(":latest".count)) : trimmed
    }

    /// The warm models absent from `loaded`, in configured order.
    static func missing(warmModels: [WarmModelConfig], loaded: [String]) -> [WarmModelConfig] {
        let resident = Set(loaded.map(canonicalName))
        return warmModels.filter { model in
            let name = canonicalName(model.name)
            return !name.isEmpty && !resident.contains(name)
        }
    }

    /// Applies the per-model rate limit. Returns the subset due for a retry and the attempt
    /// map updated for those, so the caller can persist it.
    static func due(
        _ candidates: [WarmModelConfig],
        lastAttempt: [String: Date],
        now: Date
    ) -> (models: [WarmModelConfig], updatedAttempts: [String: Date]) {
        var attempts = lastAttempt
        let models = candidates.filter { model in
            let key = canonicalName(model.name)
            if let last = attempts[key], now.timeIntervalSince(last) < minimumInterval {
                return false
            }
            attempts[key] = now
            return true
        }
        return (models, attempts)
    }
}
