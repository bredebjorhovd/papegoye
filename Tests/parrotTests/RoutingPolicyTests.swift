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
