import XCTest
@testable import parrot

/// Table-driven tests for the routing policy — the pure
/// (language, confidence, duration) → route function (spec §9).
final class RoutingPolicyTests: XCTestCase {
    struct Case {
        let language: String?
        let probability: Float?
        let seconds: Double
        let expected: Route
        let note: String
    }

    func testDefaultPolicyTable() {
        let policy = RoutingPolicy()
        let cases: [Case] = [
            // Clear Norwegian
            Case(language: "no", probability: 0.94, seconds: 3.0, expected: .norwegian, note: "confident Norwegian"),
            Case(language: "no", probability: 0.30, seconds: 3.0, expected: .norwegian, note: "weak Norwegian still routes no"),
            // Clear English
            Case(language: "en", probability: 0.95, seconds: 3.0, expected: .english, note: "confident English"),
            Case(language: "en", probability: 0.60, seconds: 3.0, expected: .english, note: "English exactly at threshold"),
            // English below the confidence gate → Norwegian (the cheap error)
            Case(language: "en", probability: 0.59, seconds: 3.0, expected: .norwegian, note: "English just below threshold"),
            Case(language: "en", probability: 0.10, seconds: 3.0, expected: .norwegian, note: "unconfident English"),
            // Scandinavian cluster all routes to NB-Whisper
            Case(language: "nn", probability: 0.90, seconds: 3.0, expected: .norwegian, note: "nynorsk"),
            Case(language: "da", probability: 0.90, seconds: 3.0, expected: .norwegian, note: "danish → NB route"),
            Case(language: "sv", probability: 0.90, seconds: 3.0, expected: .norwegian, note: "swedish → NB route"),
            // Any other language → default route
            Case(language: "de", probability: 0.99, seconds: 3.0, expected: .norwegian, note: "german → default"),
            Case(language: "fr", probability: 0.80, seconds: 3.0, expected: .norwegian, note: "french → default"),
            // Short utterances skip LID → default route even for "English"
            Case(language: "en", probability: 0.99, seconds: 0.5, expected: .norwegian, note: "short utterance ignores LID"),
            Case(language: "en", probability: 0.99, seconds: 0.6, expected: .english, note: "exactly at the duration floor runs LID"),
            // Missing LID data → default route
            Case(language: nil, probability: nil, seconds: 3.0, expected: .norwegian, note: "LID failed"),
            Case(language: "en", probability: nil, seconds: 3.0, expected: .norwegian, note: "no probability available"),
        ]

        for c in cases {
            let got = policy.route(language: c.language, probability: c.probability, seconds: c.seconds)
            XCTAssertEqual(got, c.expected, c.note)
        }
    }

    func testCustomThreshold() {
        let strict = RoutingPolicy(englishThreshold: 0.9)
        XCTAssertEqual(strict.route(language: "en", probability: 0.85, seconds: 3), .norwegian)
        XCTAssertEqual(strict.route(language: "en", probability: 0.95, seconds: 3), .english)

        let loose = RoutingPolicy(englishThreshold: 0.3)
        XCTAssertEqual(loose.route(language: "en", probability: 0.4, seconds: 3), .english)
    }

    /// Below τ = 0.5 two routes can hold enough mass to clear their gates at
    /// once. The one that cleared by more has to win, and — the assertion that
    /// actually pins it — that must not depend on where either gate sits in the
    /// table. Every case is run against the table and its reverse.
    func testArgmaxOverClearedGatesIgnoresTableOrder() {
        let loose = RoutingPolicy(englishThreshold: 0.3)
        struct Contested {
            let distribution: [String: Float]
            let expected: Route
            let note: String
        }
        let cases: [Contested] = [
            Contested(distribution: ["en": 0.45, "no": 0.35, "de": 0.20],
                      expected: .english,
                      note: "both clear, English by more"),
            Contested(distribution: ["en": 0.35, "no": 0.45, "de": 0.20],
                      expected: .norwegian,
                      note: "both clear, Norwegian by more"),
            // The cluster stands for a model, so its languages pool their mass
            // instead of each losing to English on its own.
            Contested(distribution: ["en": 0.40, "no": 0.25, "sv": 0.20, "da": 0.15],
                      expected: .norwegian,
                      note: "both clear, cluster outweighs English pooled"),
            Contested(distribution: ["en": 0.40, "no": 0.40],
                      expected: .norwegian,
                      note: "exact tie takes the default route"),
        ]

        for c in cases {
            let forward = loose.route(distribution: c.distribution, over: loose.gates)
            let reversed = loose.route(distribution: c.distribution, over: Array(loose.gates.reversed()))
            XCTAssertEqual(forward, c.expected, c.note)
            XCTAssertEqual(reversed, c.expected, "\(c.note) — reversed gate table")
        }
    }

    /// At the default threshold only one route can ever clear, so the argmax is
    /// degenerate and the full distribution must not move any answer.
    func testDistributionMatchesTopOneAtDefaultThreshold() {
        let policy = RoutingPolicy()
        let distributions: [[String: Float]] = [
            ["en": 0.95, "no": 0.03, "de": 0.02],
            ["en": 0.60, "no": 0.30, "sv": 0.10],
            ["en": 0.59, "no": 0.31, "sv": 0.10],
            ["no": 0.70, "en": 0.20, "da": 0.10],
            ["de": 0.50, "en": 0.30, "no": 0.20],
        ]
        for distribution in distributions {
            let top = distribution.max { $0.value < $1.value }!
            XCTAssertEqual(
                policy.route(distribution: distribution, seconds: 3),
                policy.route(language: top.key, probability: top.value, seconds: 3),
                "\(distribution) should route the same either way"
            )
        }

        // Short utterances skip LID however much the distribution says.
        XCTAssertEqual(policy.route(distribution: ["en": 0.99], seconds: 0.5), .norwegian)
        // An empty distribution is a failed LID → default route.
        XCTAssertEqual(policy.route(distribution: [:], seconds: 3), .norwegian)
    }

    func testShouldRunLID() {
        let policy = RoutingPolicy()
        XCTAssertFalse(policy.shouldRunLID(seconds: 0.0))
        XCTAssertFalse(policy.shouldRunLID(seconds: 0.59))
        XCTAssertTrue(policy.shouldRunLID(seconds: 0.6))
        XCTAssertTrue(policy.shouldRunLID(seconds: 30))
    }

    func testAbbreviations() {
        XCTAssertEqual(BilingualConfiguration.abbreviate("nb-whisper-small"), "nb-small")
        XCTAssertEqual(BilingualConfiguration.abbreviate("nb-whisper-base"), "nb-base")
        XCTAssertEqual(BilingualConfiguration.abbreviate("whisper-small.en"), "en-small")
        XCTAssertEqual(BilingualConfiguration.abbreviate("whisper-base.en"), "en-base")
        XCTAssertEqual(BilingualConfiguration.abbreviate("whisper-large-v3-turbo"), "whisper-large-v3-turbo")
    }

    func testBilingualConfigurationResolves() throws {
        let config = try BilingualConfiguration()
        XCTAssertEqual(config.norwegian.id, "nb-whisper-small")
        XCTAssertEqual(config.english.id, "whisper-small.en")
        XCTAssertEqual(config.lid.id, "whisper-tiny")
        XCTAssertEqual(config.shortLabel, "nb-small+en-small")
        XCTAssertEqual(config.models.count, 3)

        XCTAssertThrowsError(try BilingualConfiguration(norwegianModelID: "nope"))
        XCTAssertThrowsError(try BilingualConfiguration(englishModelID: "nope"))
    }

    func testSanitizeStripsNonSpeechMarkers() {
        XCTAssertEqual(WhisperKitTranscriber.sanitize("[BLANK_AUDIO]"), "")
        XCTAssertEqual(WhisperKitTranscriber.sanitize(" (silence) "), "")
        XCTAssertEqual(WhisperKitTranscriber.sanitize("<|nospeech|><|endoftext|>"), "")
        XCTAssertEqual(WhisperKitTranscriber.sanitize("hei  [MUSIC]  verden"), "hei verden")
        XCTAssertEqual(WhisperKitTranscriber.sanitize("Dette er *støy* en test"), "Dette er en test")
    }
}
