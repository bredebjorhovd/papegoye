import Foundation
import WhisperKit

/// Bilingual per-utterance router (spec docs/bilingual.md).
///
/// Same shape as WhisperKitTranscriber — an actor behind the Transcriber
/// protocol — so Parrot.swift, overlay, and menu bar wiring stay untouched
/// apart from construction. Holds three warm pipelines:
///
///   lid  multilingual tiny, used ONLY for language identification
///   no   NB-Whisper (also the default/fallback route)
///   en   English-only Whisper
///
/// LID always runs on stock tiny — never on NB-Whisper's own LID head, which
/// is fine-tuned almost exclusively on Norwegian and skewed accordingly.
actor RoutingTranscriber: Transcriber {
    /// Stored rather than computed so it stays nonisolated — the daemon reads
    /// it synchronously while wiring up the menu bar, before any await point.
    let modelID: String
    private let configuration: BilingualConfiguration
    private let norwegian: WhisperKitTranscriber
    private let english: WhisperKitTranscriber
    private var lidPipeline: WhisperKit?
    private var warmedUp = false

    /// Human-readable last routing decision, e.g. "no 0.94 · 12ms".
    /// Surfaced in the menu bar after each utterance.
    private(set) var lastDecision: String?
    /// Last route taken — inspected by integration tests.
    private(set) var lastRoute: Route?

    /// LID only ever looks at the first 30 s — Whisper's context window, and
    /// language rarely changes mid-utterance in dictation.
    private static let lidWindowSamples = Int(30 * AudioCapture.targetSampleRate)

    /// Optional load-time recorder — set by `parrot bench warmup` to time each
    /// pipeline and check the three loads really do overlap. nil in normal use.
    private let recorder: WarmUpRecorder?

    init(configuration: BilingualConfiguration, recorder: WarmUpRecorder? = nil) {
        self.modelID = "\(configuration.norwegian.id)+\(configuration.english.id)"
        self.configuration = configuration
        self.recorder = recorder
        self.norwegian = WhisperKitTranscriber(
            model: configuration.norwegian, language: "no", recorder: recorder
        )
        // English-only models take no language token; only force "en" when the
        // override model is multilingual (else it would re-run its own LID).
        let enLanguage = configuration.english.languages.contains("en")
            && !configuration.english.languages.contains("multi") ? nil : "en"
        self.english = WhisperKitTranscriber(
            model: configuration.english, language: enLanguage, recorder: recorder
        )
    }

    /// Loads all three pipelines concurrently. Fails atomically: if any model
    /// is missing or fails to load, the error names it and nothing starts —
    /// bilingual mode never degrades silently to single-model.
    func warmUp() async throws {
        if warmedUp { return }
        async let noReady: Void = Self.warmUpNamed(norwegian, configuration.norwegian.id)
        async let enReady: Void = Self.warmUpNamed(english, configuration.english.id)
        async let lidReady = warmUpLID()
        try await noReady
        try await enReady
        lidPipeline = try await lidReady
        warmedUp = true
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        if !warmedUp { try await warmUp() }

        let seconds = Double(audio.count) / AudioCapture.targetSampleRate
        let policy = configuration.policy

        var language: String?
        var probability: Float?
        // The whole softmax, not just the top-1 entry: below τ = 0.5 more than
        // one route can clear its gate, and the policy needs every route's mass
        // to say which cleared it by more.
        var distribution: [String: Float] = [:]
        var lidMillis = 0

        if policy.shouldRunLID(seconds: seconds) {
            guard let lidPipeline else { throw TranscriberError.notLoaded }
            let started = Date()
            do {
                let window = audio.count > Self.lidWindowSamples
                    ? Array(audio.prefix(Self.lidWindowSamples)) : audio
                // (sic — WhisperKit 0.18 spells it "detectLangauge")
                let detection = try await lidPipeline.detectLangauge(audioArray: window)
                lidMillis = Int(Date().timeIntervalSince(started) * 1000)
                language = detection.language
                // langProbs carries log-probabilities of the language tokens
                // (softmax over the <|lang|> distribution).
                distribution = detection.langProbs.mapValues { exp($0) }
                probability = distribution[detection.language]
                log(String(format: "◐ lid %@ %.2f · %dms\n",
                           detection.language, probability ?? 0, lidMillis))
            } catch {
                // LID failure is not fatal — fall through to the default route.
                lidMillis = Int(Date().timeIntervalSince(started) * 1000)
                log("◐ lid failed (\(error)) → default route\n")
            }
        } else {
            log(String(format: "◐ lid skip (%.2fs < %.1fs) → %@\n",
                       seconds, policy.minLIDSeconds, policy.defaultRoute.rawValue))
        }

        let route = policy.route(distribution: distribution, seconds: seconds)
        lastRoute = route

        if let language, let probability {
            lastDecision = String(format: "%@→%@ %.2f · %dms",
                                  language, route.rawValue, probability, lidMillis)
        } else {
            lastDecision = "\(route.rawValue) (no lid, \(String(format: "%.1f", seconds))s)"
        }

        let target: WhisperKitTranscriber = route == .english ? english : norwegian
        let decodeStarted = Date()
        let text = try await target.transcribe(audio)
        let decodeMillis = Int(Date().timeIntervalSince(decodeStarted) * 1000)
        log("◐ route \(route.rawValue) (\(target.modelID)) · lid \(lidMillis)ms · decode \(decodeMillis)ms\n")
        return text
    }

    private static func warmUpNamed(_ transcriber: WhisperKitTranscriber, _ id: String) async throws {
        do {
            try await transcriber.warmUp()
        } catch {
            throw RoutingTranscriberError.modelUnavailable(id, error)
        }
    }

    private func warmUpLID() async throws -> WhisperKit {
        try await LIDPipeline.load(configuration.lid, recorder: recorder)
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}

enum RoutingTranscriberError: Error, CustomStringConvertible {
    /// A model required by bilingual mode failed to download or load.
    case modelUnavailable(String, Error)

    var description: String {
        switch self {
        case let .modelUnavailable(id, underlying):
            return "bilingual mode needs model '\(id)' but it failed to load: \(underlying)\n"
                + "try `parrot models download \(id)` and re-run."
        }
    }
}
