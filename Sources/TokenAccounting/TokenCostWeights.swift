import Foundation

/// API-price-equivalent activity weights, normalized so one Luna input token is 1 unit.
/// These are an explainable attribution proxy, not the Codex subscription quota formula.
public enum TokenCostWeights {
    public struct ModelRates: Equatable, Sendable {
        public let input: Double
        public let cachedInput: Double
        public let cacheWriteInput: Double
        public let output: Double

        public init(input: Double, cachedInput: Double, cacheWriteInput: Double, output: Double) {
            self.input = input
            self.cachedInput = cachedInput
            self.cacheWriteInput = cacheWriteInput
            self.output = output
        }
    }

    // OpenAI API prices observed 2026-09-16, divided by Luna's $0.20 / MTok input price.
    // Cache writes are 1.25x uncached input; cached reads are 0.1x input for every listed model.
    public static let luna = ModelRates(input: 1, cachedInput: 0.1, cacheWriteInput: 1.25, output: 6)
    public static let terra = ModelRates(input: 10, cachedInput: 1, cacheWriteInput: 12.5, output: 60)
    public static let sol = ModelRates(input: 20, cachedInput: 2, cacheWriteInput: 25, output: 100)
    public static let astra = ModelRates(input: 50, cachedInput: 5, cacheWriteInput: 62.5, output: 250)

    public static func rates(for model: String) -> ModelRates? {
        switch model.lowercased() {
        case "gpt-5.6-luna": return luna
        case "gpt-5.6-terra": return terra
        case "gpt-5.6-sol", "gpt-5.6": return sol
        case "gpt-6-astra": return astra
        default: return nil
        }
    }

    /// Cached tokens are included in `input`. Cache-write tokens are treated as an uncached
    /// subset plus the documented 0.25x write premium, avoiding double counting.
    public static func activityUnits(for bin: HourlyTokenUsage) -> Double {
        let rates = rates(for: bin.model) ?? luna
        let cached = min(bin.counts.input, bin.counts.cachedInput)
        let uncached = max(0, bin.counts.input - cached)
        let writes = min(uncached, bin.counts.cacheWriteInput)
        return Double(uncached) * rates.input
            + Double(cached) * rates.cachedInput
            + Double(writes) * (rates.cacheWriteInput - rates.input)
            + Double(bin.counts.output) * rates.output
    }
}
