import XCTest
@testable import parrot

/// Regression test for gh#27: a dictation utterance longer than Whisper's 30 s
/// context window must come back whole.
///
/// Nothing upstream caps utterance length — `HotkeyMonitor` is press/release and
/// `AudioCapture` accumulates until release, so "hold the key and talk for a
/// minute" is an ordinary thing to do. Left to its own sequential seek loop
/// (`chunkingStrategy == nil`), WhisperKit dropped a contiguous block of speech
/// out of the middle of such a capture on the NB route — six consecutive
/// sentences, no marker in the output, nothing in the logs. Since parrot joins
/// `results.map(\.text)` and never looks at segment timestamps, there is no
/// layer below this one that could notice.
///
/// Unlike `RoutingIntegrationTests` this needs no recorded fixture: it
/// synthesises its own speech with `say`, so the failure is reproducible on any
/// machine that has the models and the voice. Opt-in, like the other tests that
/// load real models:
///
///     PARROT_INTEGRATION=1 swift test --filter LongUtteranceTests
final class LongUtteranceTests: XCTestCase {
    /// Sentences chosen to be non-repeating — Whisper loops on repeated text,
    /// which would mask exactly the kind of loss under test. Long enough
    /// (~79 s at Nora's default rate) to span three 30 s windows.
    private static let sentences = [
        "Havnesjefen meldte at nitten fartøy ventet utenfor den nordlige innseilingen i morges.",
        "En geolog fra Bergen beskrev sedimentlagene som uvanlig rike på vulkansk aske.",
        "Regnskapsføreren insisterer på at kvartalsavstemmingen må være ferdig før revisorene kommer.",
        "Biblioteket i Elvegata holder stengt for oppussing gjennom hele september måned.",
        "Marina fant et gammelt lommeur begravd under drivhusets fundament sist tirsdag.",
        "Ingeniørene byttet det korroderte lageret på den andre turbinen uten å stanse produksjonen.",
        "Oppskriften krever safran, ristede mandler og en romslig skvett hvitvinseddik.",
        "Delegater fra fjorten land signerte fiskeriavtalen etter elleve timer med forhandlinger.",
        "Naboen min har tre bikuber på taket og selger honningen på lørdagsmarkedet.",
        "Teleskopet fanget en svak flekk som senere viste seg å være en ukjent komet.",
        "Passasjerene ble overført til buss for tog mellom Sandvika og sentralterminalen.",
        "En pensjonert lærer meldte seg frivillig til å katalogisere hele arkivet med kirkebøker.",
        "Prototypens kabinett sprakk under den tredje termiske syklusen, så vi byttet til titanlegering.",
        "Snøfall stengte fjellovergangen og strandet to hundre bilister over natten i sterk kulde.",
    ]

    /// One distinctive word per sentence, so a missing marker names the sentence
    /// that vanished. Each is a word nb-whisper-small transcribes correctly when
    /// it is decoded at all — this asserts coverage, not transcription accuracy.
    private static let markers = [
        "havnesjefen", "vulkansk", "kvartalsavstemningen", "elvegata", "lommeur",
        "turbinen", "safran", "fiskeriavtalen", "bikuber", "komet",
        "sandvika", "kirkebøker", "titanlegering", "bilister",
    ]

    func testLongNorwegianUtteranceKeepsEverySentence() async throws {
        guard ProcessInfo.processInfo.environment["PARROT_INTEGRATION"] == "1" else {
            throw XCTSkip("integration tests are opt-in: set PARROT_INTEGRATION=1")
        }
        guard let model = ModelRegistry.find("nb-whisper-small") else {
            throw XCTSkip("nb-whisper-small not in the registry")
        }
        let samples = try Self.synthesize(Self.sentences.joined(separator: "\n"))
        let seconds = Double(samples.count) / AudioCapture.targetSampleRate
        XCTAssertGreaterThan(seconds, 60, "fixture must span several 30 s windows to be meaningful")

        let text = try await WhisperKitTranscriber(model: model, language: "no")
            .transcribe(samples)
            .lowercased()

        let missing = Self.markers.filter { !text.contains($0) }
        XCTAssertTrue(
            missing.isEmpty,
            """
            \(missing.count)/\(Self.markers.count) sentences dropped from a \
            \(String(format: "%.1f", seconds))s utterance: \(missing.joined(separator: ", ")).
            Transcript: \(text)
            """
        )
    }

    /// Renders text with `say` straight into the 16 kHz mono PCM that
    /// `AudioCapture` produces, then reads it back through the same reader the
    /// fixture tests use.
    private static func synthesize(_ text: String) throws -> [Float] {
        guard voiceIsInstalled(voice) else {
            throw XCTSkip("voice '\(voice)' not installed — add it in System Settings → Accessibility → Spoken Content")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-long-utterance-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "-v", voice,
            "--data-format=LEI16@16000",
            "-o", url.path,
            text,
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("`say` failed with status \(process.terminationStatus)")
        }
        return try WAVReader.read(url)
    }

    private static let voice = "Nora"

    private static func voiceIsInstalled(_ name: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "?"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .contains { $0.hasPrefix(name) }
    }
}
