import Foundation
import XCTest
@testable import parrot

/// `parrot models migrate` — the opt-in way out of the ~/Documents cache
/// (gh#34). No iCloud here: what's checked is that the whole tree lands intact
/// at the new base and that the old copy only disappears after that.
final class CacheMigrationTests: XCTestCase {
    private var root: URL!
    private var source: URL!
    private var destination: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parrot-migration-tests-\(UUID().uuidString)")
        source = root.appendingPathComponent("Documents/huggingface")
        destination = root.appendingPathComponent("Application Support/parrot")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ relativePath: String, _ contents: String, under base: URL? = nil) throws -> URL {
        let url = (base ?? source).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func seedCache() throws {
        try write("models/argmaxinc/whisperkit-coreml/openai_whisper-small.en/TextDecoder.mlmodelc/coremldata.bin", "decoder")
        try write("models/argmaxinc/whisperkit-coreml/openai_whisper-small.en/AudioEncoder.mlmodelc/coremldata.bin", "encoder")
        try write("models/argmaxinc/whisperkit-coreml/openai_whisper-tiny/config.json", "{}")
        // Tokenizer repos sit beside the weights and have to come along too,
        // or a migrated install has half its cache in each place.
        try write("models/openai/whisper-small.en/tokenizer.json", "tokens")
    }

    private func plan() -> CacheMigration.Plan {
        CacheMigration.plan(source: source, destination: destination)
    }

    // MARK: - Planning

    func testPlanCoversEveryFileWithItsRelativePath() throws {
        try seedCache()
        let planned = plan()
        XCTAssertEqual(planned.items.count, 4)
        XCTAssertEqual(
            planned.items.map(\.relativePath),
            [
                "models/argmaxinc/whisperkit-coreml/openai_whisper-small.en/AudioEncoder.mlmodelc/coremldata.bin",
                "models/argmaxinc/whisperkit-coreml/openai_whisper-small.en/TextDecoder.mlmodelc/coremldata.bin",
                "models/argmaxinc/whisperkit-coreml/openai_whisper-tiny/config.json",
                "models/openai/whisper-small.en/tokenizer.json",
            ]
        )
        XCTAssertEqual(planned.totalBytes, 7 + 7 + 2 + 6)
        XCTAssertEqual(planned.evictedCount, 0)
    }

    func testPlanIsEmptyWhenThereIsNoLegacyCache() {
        XCTAssertTrue(plan().isEmpty)
    }

    // MARK: - Running

    func testMigrationMovesTheTreeAndRemovesTheOldCopy() throws {
        try seedCache()
        let planned = plan()
        try CacheMigration.run(planned)

        for item in planned.items {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: item.destination.path),
                "missing after migration: \(item.relativePath)"
            )
        }
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent(
                "models/argmaxinc/whisperkit-coreml/openai_whisper-small.en/TextDecoder.mlmodelc/coremldata.bin"
            ), encoding: .utf8),
            "decoder"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    /// The migrated cache has to be where `ModelCache` looks, or the next run
    /// re-downloads a gigabyte.
    func testMigratedCacheIsFoundByTheCacheLookup() throws {
        try seedCache()
        try CacheMigration.run(plan())
        XCTAssertNotNil(ModelCache.cachedVariantDirectory(
            base: destination,
            repo: "argmaxinc/whisperkit-coreml",
            variant: "whisper-small.en"
        ))
        XCTAssertEqual(
            ModelCache.resolveBase(
                repo: "argmaxinc/whisperkit-coreml",
                variant: "whisper-small.en",
                preferred: destination,
                legacy: source
            ),
            destination
        )
    }

    func testKeepOldLeavesTheSourceInPlace() throws {
        try seedCache()
        try CacheMigration.run(plan(), keepOld: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination
            .appendingPathComponent("models/openai/whisper-small.en/tokenizer.json").path))
    }

    /// An interrupted migration is resumable: already-copied files are left
    /// alone, and a truncated one is replaced rather than kept.
    func testRerunCompletesAPartialMigration() throws {
        try seedCache()
        try write(
            "models/argmaxinc/whisperkit-coreml/openai_whisper-tiny/config.json",
            "{}",
            under: destination
        )
        try write(
            "models/openai/whisper-small.en/tokenizer.json",
            "trunc",  // one byte short of "tokens"
            under: destination
        )
        try CacheMigration.run(plan())
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent(
                "models/openai/whisper-small.en/tokenizer.json"
            ), encoding: .utf8),
            "tokens"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testRelativePathFallsBackToTheFileNameOutsideTheRoot() {
        let outsider = URL(fileURLWithPath: "/elsewhere/model.bin")
        XCTAssertEqual(CacheMigration.relativePath(of: outsider, under: source), "model.bin")
    }
}
