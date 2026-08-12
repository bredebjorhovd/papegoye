import Foundation
import XCTest
@testable import parrot

/// The cache-location rules from gh#34: fresh installs must land outside
/// iCloud's reach, and an install that already has ~1 GB in ~/Documents must
/// keep using it rather than silently re-downloading.
///
/// The end-to-end failure needs iCloud "Desktop & Documents Folders" sync to
/// reproduce, so these tests cover what is checkable anywhere: the base every
/// call site resolves, against throwaway directories.
final class ModelCacheTests: XCTestCase {
    private var root: URL!
    private var preferred: URL!
    private var legacy: URL!

    private let repo = "argmaxinc/whisperkit-coreml"
    private let variant = "openai_whisper-small.en"

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parrot-cache-tests-\(UUID().uuidString)")
        preferred = root.appendingPathComponent("Application Support/parrot")
        legacy = root.appendingPathComponent("Documents/huggingface")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes a plausible cached variant: `<base>/models/<repo>/<folder>/x.mlmodelc`.
    @discardableResult
    private func seed(base: URL, folder: String, repo: String? = nil) throws -> URL {
        let dir = ModelCache.repoDirectory(base: base, repo: repo ?? self.repo)
            .appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: dir.appendingPathComponent("TextDecoder.mlmodelc"))
        return dir
    }

    private func resolve() -> URL {
        ModelCache.resolveBase(repo: repo, variant: variant, preferred: preferred, legacy: legacy)
    }

    // MARK: - Base selection

    func testFreshInstallDownloadsOutsideDocuments() {
        XCTAssertEqual(resolve(), preferred)
    }

    func testExistingDocumentsCacheIsPreferredOverARedownload() throws {
        try seed(base: legacy, folder: variant)
        XCTAssertEqual(resolve(), legacy)
    }

    func testPartialDocumentsCacheDoesNotWinTheNewBase() throws {
        // An empty variant folder is a half-finished download, not a cache.
        try FileManager.default.createDirectory(
            at: ModelCache.repoDirectory(base: legacy, repo: repo).appendingPathComponent(variant),
            withIntermediateDirectories: true
        )
        XCTAssertEqual(resolve(), preferred)
    }

    func testUnrelatedModelInDocumentsDoesNotDragTheCacheBack() throws {
        try seed(base: legacy, folder: "openai_whisper-tiny")
        XCTAssertEqual(resolve(), preferred)
    }

    // MARK: - Layout

    /// HubApi appends `models/<repo>` to the base it is given, which is what
    /// makes `~/Library/Application Support/parrot` the right base for the
    /// documented `.../parrot/models/...` layout.
    func testRepoDirectoryMatchesHubLayout() {
        XCTAssertEqual(
            ModelCache.repoDirectory(base: preferred, repo: repo).path,
            preferred.appendingPathComponent("models/argmaxinc/whisperkit-coreml").path
        )
    }

    func testCachedVariantDirectoryFuzzyMatchesTheDownloadedFolderName() throws {
        // WhisperKit stores `whisper-small.en` as `openai_whisper-small.en`.
        let dir = try seed(base: preferred, folder: variant)
        XCTAssertEqual(
            ModelCache.cachedVariantDirectory(base: preferred, repo: repo, variant: "whisper-small.en")?.path,
            dir.path
        )
    }

    func testCachedVariantDirectoryIsNilWhenNothingIsCached() {
        XCTAssertNil(ModelCache.cachedVariantDirectory(base: preferred, repo: repo, variant: variant))
    }

    func testCustomRepoIsHonoured() throws {
        let nbRepo = "Barrymanalow/nb-whisper-coreml"
        try seed(base: legacy, folder: "nb-whisper-small", repo: nbRepo)
        XCTAssertEqual(
            ModelCache.resolveBase(
                repo: nbRepo, variant: "nb-whisper-small", preferred: preferred, legacy: legacy
            ),
            legacy
        )
        // …and doesn't leak into the default repo's answer.
        XCTAssertEqual(resolve(), preferred)
    }

    // MARK: - The shared accessor

    /// The point of `ModelCache`: the load path can't end up on a different
    /// cache than the download path.
    func testLoadConfigurationUsesTheSharedBase() {
        let model = TranscriptionModel(
            id: "whisper-small.en",
            displayName: "Whisper Small (English)",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-small.en",
            sizeMB: 465,
            languages: ["en"],
            recommended: false
        )
        let config = ModelCache.configuration(for: model)
        XCTAssertEqual(config.downloadBase, ModelCache.base(for: model))
        XCTAssertNotNil(config.downloadBase, "a nil base is HubApi's ~/Documents default (gh#34)")
        XCTAssertEqual(config.model, model.whisperKitID)
    }

    func testDefaultRepoIsUsedWhenAModelNamesNone() {
        let model = TranscriptionModel(
            id: "whisper-tiny",
            displayName: "Whisper Tiny",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-tiny",
            sizeMB: 78,
            languages: ["multi"],
            recommended: false
        )
        XCTAssertEqual(model.repoID, ModelCache.defaultRepo)
    }

    // MARK: - Sync detection

    func testAPlainDirectoryIsNotReportedAsSynced() {
        XCTAssertFalse(ModelCache.isInSyncedFolder(preferred))
    }

    func testSyncDetectionWalksUpToAnExistingAncestor() throws {
        // The cache dir usually doesn't exist yet on a fresh install; the
        // question is about the folder it would be created in.
        let missing = root.appendingPathComponent("Documents/huggingface/models/x")
        XCTAssertFalse(ModelCache.isInSyncedFolder(missing))
    }

    func testMobileDocumentsPathIsReportedAsSynced() throws {
        let synced = root
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Documents/huggingface")
        try FileManager.default.createDirectory(at: synced, withIntermediateDirectories: true)
        XCTAssertTrue(ModelCache.isInSyncedFolder(synced))
    }
}
