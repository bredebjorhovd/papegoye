import XCTest
@testable import parrot

/// End-to-end routing tests over fixture WAVs (spec §9). These load real
/// models (~1 GB download on first run) and only make sense on Apple Silicon,
/// so they are opt-in:
///
///     PARROT_INTEGRATION=1 swift test --filter RoutingIntegrationTests
///
/// Fixtures live in Tests/fixtures/ (see the README there). Record them with
/// `parrot --dump-wav` — 16 kHz mono 16-bit PCM. The filename prefix encodes
/// the expectation:
///
///     no-*.wav       → Norwegian route, non-empty transcript
///     en-*.wav       → English route, non-empty transcript
///     short-*.wav    → Norwegian route (LID skipped below duration floor)
///     silence-*.wav  → empty transcript after sanitize
final class RoutingIntegrationTests: XCTestCase {
    static var transcriber: RoutingTranscriber?

    override class func setUp() {
        super.setUp()
        guard ProcessInfo.processInfo.environment["PARROT_INTEGRATION"] == "1" else { return }
        guard let config = try? BilingualConfiguration() else { return }
        transcriber = RoutingTranscriber(configuration: config)
    }

    private func fixtures(prefix: String) throws -> [(name: String, samples: [Float])] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // parrotTests
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("fixtures")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return try files
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".wav") }
            .sorted()
            .map { ($0, try WAVReader.read(URL(fileURLWithPath: dir.appendingPathComponent($0).path))) }
    }

    private func requireTranscriber() throws -> RoutingTranscriber {
        guard ProcessInfo.processInfo.environment["PARROT_INTEGRATION"] == "1" else {
            throw XCTSkip("integration tests are opt-in: set PARROT_INTEGRATION=1")
        }
        guard let t = Self.transcriber else {
            throw XCTSkip("bilingual configuration unavailable")
        }
        return t
    }

    private func assertRoute(
        prefix: String,
        expected: Route,
        expectTranscript: Bool
    ) async throws {
        let transcriber = try requireTranscriber()
        let cases = try fixtures(prefix: prefix)
        if cases.isEmpty {
            throw XCTSkip("no \(prefix)*.wav fixtures present — record with `parrot --dump-wav`")
        }
        for (name, samples) in cases {
            let text = try await transcriber.transcribe(samples)
            let route = await transcriber.lastRoute
            XCTAssertEqual(route, expected, "\(name): wrong route")
            if expectTranscript {
                XCTAssertFalse(text.isEmpty, "\(name): expected non-empty transcript")
            }
        }
    }

    func testNorwegianFixturesRouteToNB() async throws {
        // Covers plain bokmål AND Norwegian with English tech terms — both
        // must land on NB-Whisper (it handles anglicisms).
        try await assertRoute(prefix: "no-", expected: .norwegian, expectTranscript: true)
    }

    func testEnglishFixturesRouteToEN() async throws {
        try await assertRoute(prefix: "en-", expected: .english, expectTranscript: true)
    }

    func testShortFixturesSkipLID() async throws {
        try await assertRoute(prefix: "short-", expected: .norwegian, expectTranscript: false)
    }

    func testSilenceFixturesProduceEmptyTranscript() async throws {
        let transcriber = try requireTranscriber()
        let cases = try fixtures(prefix: "silence-")
        if cases.isEmpty {
            throw XCTSkip("no silence-*.wav fixtures present")
        }
        for (name, samples) in cases {
            // The daemon gates silence on RMS before the transcriber ever
            // sees it; this asserts the second line of defense (sanitize).
            let text = try await transcriber.transcribe(samples)
            XCTAssertTrue(text.isEmpty, "\(name): expected empty transcript, got '\(text)'")
        }
    }
}

/// Minimal reader for the exact format WAVWriter/--dump-wav produces:
/// RIFF, 16-bit PCM, mono. Not a general-purpose WAV parser.
enum WAVReader {
    enum ReadError: Error { case malformed, unsupportedFormat }

    static func read(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count > 44,
              data[0..<4].elementsEqual("RIFF".utf8),
              data[8..<12].elementsEqual("WAVE".utf8)
        else { throw ReadError.malformed }

        // Walk chunks to find fmt and data (WAVWriter emits them in order,
        // but be tolerant of extra chunks from other tools).
        var offset = 12
        var bitsPerSample = 0
        var channels = 0
        var sampleData: Data?
        while offset + 8 <= data.count {
            let id = data[offset..<offset + 4]
            let size = Int(readUInt32LE(data, offset + 4))
            let body = offset + 8
            guard body + size <= data.count else { break }
            if id.elementsEqual("fmt ".utf8), size >= 16 {
                let format = Int(readUInt16LE(data, body))
                channels = Int(readUInt16LE(data, body + 2))
                bitsPerSample = Int(readUInt16LE(data, body + 14))
                guard format == 1 else { throw ReadError.unsupportedFormat }
            } else if id.elementsEqual("data".utf8) {
                sampleData = data.subdata(in: body..<body + size)
            }
            offset = body + size + (size % 2)
        }
        guard bitsPerSample == 16, channels == 1, let sampleData else {
            throw ReadError.unsupportedFormat
        }

        var samples = [Float]()
        samples.reserveCapacity(sampleData.count / 2)
        for i in stride(from: 0, to: sampleData.count - 1, by: 2) {
            let lo = UInt16(sampleData[sampleData.startIndex + i])
            let hi = UInt16(sampleData[sampleData.startIndex + i + 1])
            let value = Int16(bitPattern: lo | (hi << 8))
            samples.append(Float(value) / 32767.0)
        }
        return samples
    }

    private static func readUInt32LE(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    private static func readUInt16LE(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }
}
