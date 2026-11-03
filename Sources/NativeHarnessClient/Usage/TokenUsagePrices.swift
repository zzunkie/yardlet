import Foundation

/// The providers' public API prices per million tokens, copied from their pricing pages on the date
/// each table names, for the API-equivalent cost Settings › Usage shows. Nothing is fetched: a new
/// table comes with a new Yardlet. A model missing here is counted in tokens only.
enum TokenUsagePrices {
    struct Table: Sendable {
        let provider: String
        let source: String
        /// The day the prices were copied, as "yyyy-MM-dd".
        let copied: String
    }

    /// Dollars per million tokens of each kind.
    struct Rates: Equatable, Sendable {
        var input: Double
        var cacheWrite: Double
        /// Claude's 1-hour cache writes; Codex reports one kind of write.
        var longCacheWrite: Double
        var cacheRead: Double
        var output: Double

        func scaled(_ factor: Double) -> Rates {
            Rates(input: input * factor, cacheWrite: cacheWrite * factor, longCacheWrite: longCacheWrite * factor,
                  cacheRead: cacheRead * factor, output: output * factor)
        }
    }

    struct Model: Sendable {
        let rates: Rates
        /// Rates for a request whose prompt (all its input, cached or not) is over `longPromptOver`.
        var longPrompt: Rates?
        var longPromptOver: Int64 = .max
        /// What fast mode multiplies every rate by, where the model has it.
        var fastFactor: Double?
    }

    static let anthropic = Table(provider: "Anthropic", source: "https://platform.claude.com/docs/en/about-claude/pricing",
                                 copied: "2026-11-03")
    static let openAI = Table(provider: "OpenAI", source: "https://developers.openai.com/api/docs/pricing",
                              copied: "2026-11-03")
    static let tables = [anthropic, openAI]

    private static func rates(_ input: Double, _ write5m: Double, _ write1h: Double, _ read: Double,
                              _ output: Double) -> Rates {
        Rates(input: input, cacheWrite: write5m, longCacheWrite: write1h, cacheRead: read, output: output)
    }

    /// Model ids as the transcripts write them, without a date suffix.
    private static let models: [String: Model] = [
        "claude-fable-5-1": Model(rates: rates(10, 12.5, 20, 0.25, 50)),
        "claude-mythos-5-1": Model(rates: rates(10, 12.5, 20, 0.25, 50)),
        "claude-fable-5": Model(rates: rates(10, 12.5, 20, 1, 50)),
        "claude-mythos-5": Model(rates: rates(10, 12.5, 20, 1, 50)),
        "claude-opus-5-5": Model(rates: rates(4, 5, 8, 0.2, 20), fastFactor: 2),
        "claude-opus-5": Model(rates: rates(5, 6.25, 10, 0.5, 25), fastFactor: 2),
        "claude-opus-4-8": Model(rates: rates(5, 6.25, 10, 0.5, 25), fastFactor: 2),
        "claude-opus-4-7": Model(rates: rates(5, 6.25, 10, 0.5, 25)),
        "claude-opus-4-6": Model(rates: rates(5, 6.25, 10, 0.5, 25)),
        "claude-opus-4-5": Model(rates: rates(5, 6.25, 10, 0.5, 25)),
        "claude-opus-4-1": Model(rates: rates(15, 18.75, 30, 1.5, 75)),
        "claude-opus-4": Model(rates: rates(15, 18.75, 30, 1.5, 75)),
        "claude-sonnet-5-5": Model(rates: rates(2, 2.5, 4, 0.1, 10)),
        "claude-sonnet-5": Model(rates: rates(2, 2.5, 4, 0.2, 10)),
        "claude-sonnet-4-6": Model(rates: rates(3, 3.75, 6, 0.3, 15)),
        "claude-sonnet-4-5": Model(rates: rates(3, 3.75, 6, 0.3, 15)),
        "claude-sonnet-4": Model(rates: rates(3, 3.75, 6, 0.3, 15)),
        "claude-haiku-5-5": Model(rates: rates(0.1, 0.125, 0.2, 0.01, 0.5),
                                  longPrompt: rates(0.5, 0.625, 1, 0.05, 2.5), longPromptOver: 100_000),
        "claude-haiku-4-5": Model(rates: rates(1, 1.25, 2, 0.1, 5)),
        "claude-3-5-haiku": Model(rates: rates(0.8, 1, 1.6, 0.08, 4)),
        // OpenAI's Standard tier; a write is priced as its 30-minute write. Over 272K input tokens a
        // request pays the long-context prices.
        "gpt-6-astra": Model(rates: rates(10, 12.5, 12.5, 1, 50), longPrompt: rates(20, 25, 25, 2, 75),
                             longPromptOver: 272_000),
        "gpt-6.1-sol": Model(rates: rates(2, 2.5, 2.5, 0.1, 10), longPrompt: rates(4, 5, 5, 0.2, 15),
                             longPromptOver: 272_000),
        "gpt-6.1-terra": Model(rates: rates(1, 1.25, 1.25, 0.05, 5), longPrompt: rates(2, 2.5, 2.5, 0.1, 7.5),
                               longPromptOver: 272_000),
        "gpt-6-luna": Model(rates: rates(0.1, 0.125, 0.125, 0.01, 0.5), longPrompt: rates(0.2, 0.25, 0.25, 0.02, 0.75),
                            longPromptOver: 272_000),
        "gpt-6-sol": Model(rates: rates(2, 2.5, 2.5, 0.2, 10), longPrompt: rates(4, 5, 5, 0.4, 15),
                           longPromptOver: 272_000)
    ]

    /// The model's prices: its id as written, or without a trailing date (`claude-haiku-4-5-20251001`).
    static func model(_ id: String) -> Model? {
        if let model = models[id] { return model }
        let parts = id.split(separator: "-")
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            return models[parts.dropLast().joined(separator: "-")]
        }
        return nil
    }

    /// The rates one request pays: the long-prompt prices over the threshold, then fast mode and US-only
    /// inference (1.1x on Claude) on top.
    static func rates(model id: String, prompt: Int64, fast: Bool, usOnly: Bool) -> Rates? {
        guard let model = model(id) else { return nil }
        var rates = prompt > model.longPromptOver ? model.longPrompt ?? model.rates : model.rates
        if fast, let factor = model.fastFactor { rates = rates.scaled(factor) }
        if usOnly { rates = rates.scaled(1.1) }
        return rates
    }
}
