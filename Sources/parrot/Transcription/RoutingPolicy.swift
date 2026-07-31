import Foundation

/// Which model an utterance is dispatched to.
enum Route: String {
    case norwegian = "no"
    case english = "en"
}

/// Per-utterance language routing, kept as a pure function of
/// (LID distribution, duration) so it can be table-tested without audio
/// or models (spec §9).
///
/// Bias: Norwegian is the default route. False-English on Norwegian speech is
/// the expensive error — NB-Whisper on English is merely degraded, stock
/// English Whisper on Norwegian is garbage. So English requires a confident
/// LID hit; everything else falls through to Norwegian.
struct RoutingPolicy {
    static let defaultEnglishThreshold: Float = 0.6
    static let defaultMinLIDSeconds: Double = 0.6

    /// Whisper's LID frequently confuses the Scandinavian languages, and
    /// NB-Whisper is the right target for all of them in practice.
    static let norwegianCluster: Set<String> = ["no", "nn", "da", "sv"]

    /// One route's claim on the LID distribution: the language codes it wants,
    /// and the confidence floor that claim has to clear.
    ///
    /// Gates are data, not branches. `route(distribution:over:)` takes the
    /// argmax over everything that clears, so the order of the table carries no
    /// meaning — `RoutingPolicyTests` pins that by permuting it.
    struct Gate {
        let route: Route
        let languages: Set<String>
        let threshold: Float

        /// Share of the distribution this gate claims. A gate stands for a
        /// model rather than a language, so it claims its whole cluster's mass:
        /// the Scandinavian languages all decode on NB-Whisper, so their
        /// probabilities add up instead of competing with each other.
        func mass(in distribution: [String: Float]) -> Float {
            languages.reduce(0) { $0 + (distribution[$1] ?? 0) }
        }
    }

    /// p(en) must be at least this for the English route.
    var englishThreshold: Float = defaultEnglishThreshold
    /// Utterances shorter than this skip LID entirely — short "ok"/"nei"
    /// gives unreliable LID and the routing cost isn't worth it.
    var minLIDSeconds: Double = defaultMinLIDSeconds
    /// Taken when no gate clears: LID skipped or failed, a language no route
    /// claims, or a claim that fell short of its threshold.
    var defaultRoute: Route = .norwegian

    /// The routes and the mass each one needs to win an utterance.
    var gates: [Gate] {
        [
            // The default route's own cluster carries no floor — anything that
            // clears nothing lands here anyway, so a floor would be dead weight.
            Gate(route: .norwegian, languages: Self.norwegianCluster, threshold: 0),
            Gate(route: .english, languages: ["en"], threshold: englishThreshold),
        ]
    }

    /// True if the utterance is long enough for LID to be worth running.
    func shouldRunLID(seconds: Double) -> Bool {
        seconds >= minLIDSeconds
    }

    /// Routing decision from the top-1 LID result. `language`/`probability` are
    /// nil when LID was skipped (short utterance) or failed — default route.
    func route(language: String?, probability: Float?, seconds: Double) -> Route {
        guard let language, let probability else { return defaultRoute }
        return route(distribution: [language: probability], seconds: seconds)
    }

    /// Routing decision from the whole LID softmax. Preferred over the top-1
    /// form: below τ = 0.5 more than one route can clear its gate at once, and
    /// only the full distribution says which one cleared it by more.
    func route(distribution: [String: Float], seconds: Double) -> Route {
        guard shouldRunLID(seconds: seconds) else { return defaultRoute }
        return route(distribution: distribution, over: gates)
    }

    /// Argmax over the gates this distribution clears, falling back to the
    /// default route when none do. Takes the table explicitly so the tests can
    /// hand it a permuted one and check the answer does not move.
    func route(distribution: [String: Float], over gates: [Gate]) -> Route {
        let cleared = gates.compactMap { gate -> (gate: Gate, mass: Float)? in
            let mass = gate.mass(in: distribution)
            // `mass > 0` matters: a zero-threshold gate would otherwise clear on
            // a language it holds no opinion about.
            guard mass > 0, mass >= gate.threshold else { return nil }
            return (gate, mass)
        }
        guard let winner = cleared.max(by: ordering) else { return defaultRoute }
        return winner.gate.route
    }

    /// Strict weak ordering over cleared gates, total by construction so that
    /// `max(by:)` cannot fall back on the table's order to settle a tie: most
    /// mass wins, an exact tie goes to the default route (a coin flip should
    /// take the cheap error), and anything still level goes to the route id.
    private func ordering(
        _ a: (gate: Gate, mass: Float),
        _ b: (gate: Gate, mass: Float)
    ) -> Bool {
        if a.mass != b.mass { return a.mass < b.mass }
        let aIsDefault = a.gate.route == defaultRoute
        let bIsDefault = b.gate.route == defaultRoute
        if aIsDefault != bIsDefault { return bIsDefault }
        return a.gate.route.rawValue < b.gate.route.rawValue
    }
}
