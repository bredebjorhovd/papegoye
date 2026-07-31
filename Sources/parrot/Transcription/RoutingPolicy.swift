import Foundation

/// Which model an utterance is dispatched to.
enum Route: String {
    case norwegian = "no"
    case english = "en"
}

/// Per-utterance language routing, kept as a pure function of
/// (language, confidence, duration) so it can be table-tested without audio
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

    /// p(en) must be at least this for the English route.
    var englishThreshold: Float = defaultEnglishThreshold
    /// Utterances shorter than this skip LID entirely — short "ok"/"nei"
    /// gives unreliable LID and the routing cost isn't worth it.
    var minLIDSeconds: Double = defaultMinLIDSeconds

    /// True if the utterance is long enough for LID to be worth running.
    func shouldRunLID(seconds: Double) -> Bool {
        seconds >= minLIDSeconds
    }

    /// Routing decision for a detected language. `language`/`probability` are
    /// nil when LID was skipped (short utterance) or failed — default route.
    func route(language: String?, probability: Float?, seconds: Double) -> Route {
        guard shouldRunLID(seconds: seconds),
              let language,
              let probability
        else { return .norwegian }

        if Self.norwegianCluster.contains(language) {
            return .norwegian
        }
        if language == "en", probability >= englishThreshold {
            return .english
        }
        return .norwegian
    }
}
