import Foundation
import WhisperKit

/// Where model weights live on disk, and the one place that decides it (gh#34).
///
/// WhisperKit's Hub layer (swift-transformers' `HubApi`) defaults its download
/// base to `~/Documents/huggingface`, which is the worst possible place on a
/// Mac with iCloud "Desktop & Documents Folders" turned on — a common default:
///
///   - the ~1 GB of CoreML weights is uploaded to the user's iCloud, and
///   - iCloud *evicts* files it considers cold. Reading or writing an evicted
///     file forces materialisation, which races WhisperKit's own concurrent
///     writes and fails with `EDEADLK` ("Resource deadlock avoided").
///
/// That is why `parrot models download <id>` — one model at a time — usually
/// survives while bilingual warm-up — three concurrent loads — does not.
///
/// So we always pass an explicit `downloadBase`. Every site that needs a cache
/// path goes through this enum so they cannot drift apart.
enum ModelCache {
    /// WhisperKit's own default repo, used when a model doesn't name one.
    static let defaultRepo = "argmaxinc/whisperkit-coreml"

    /// Base for new downloads. `HubApi` appends `models/<repo>` to whatever
    /// base it is given, so the tree under here is the familiar Hub layout —
    /// `~/Library/Application Support/parrot/models/<repo>/<variant>` — just
    /// re-rooted somewhere iCloud does not touch.
    static var applicationSupportBase: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("parrot")
    }

    /// `HubApi`'s default base. We never download here any more, but an
    /// existing install already has ~1 GB sitting in it, and re-fetching that
    /// silently is not acceptable — see `base(for:)`.
    static var documentsBase: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface")
    }

    /// The base to hand WhisperKit for `model`: the legacy Documents cache when
    /// this model is already sitting in it, the new base otherwise. Existing
    /// installs keep working without a re-download; fresh installs never touch
    /// Documents. `parrot models migrate` is how a user leaves the legacy base
    /// behind — never a silent bulk move during warm-up (moving iCloud-managed
    /// files materialises every evicted one first, and can hang for minutes).
    static func base(for model: TranscriptionModel) -> URL {
        guard let variant = model.whisperKitID else { return applicationSupportBase }
        return resolveBase(repo: model.repoID, variant: variant)
    }

    /// The base-selection rule on its own, so it can be exercised against
    /// throwaway directories rather than the real home folder.
    static func resolveBase(
        repo: String,
        variant: String,
        preferred: URL? = nil,
        legacy: URL? = nil
    ) -> URL {
        let preferred = preferred ?? applicationSupportBase
        let legacy = legacy ?? documentsBase
        if cachedVariantDirectory(base: legacy, repo: repo, variant: variant) != nil {
            return legacy
        }
        return preferred
    }

    /// `HubApi.localRepoLocation` — `<base>/models/<repo>`.
    static func repoDirectory(base: URL, repo: String) -> URL {
        base.appendingPathComponent("models/\(repo)")
    }

    /// The cached folder for `variant` under `base`, or nil when nothing
    /// usable is there. WhisperKit fuzzy-matches variant folder names on
    /// download (`whisper-small.en` → `openai_whisper-small.en`), so accept any
    /// non-empty folder whose name contains the variant.
    static func cachedVariantDirectory(base: URL, repo: String, variant: String) -> URL? {
        let repoDir = repoDirectory(base: base, repo: repo)
        let candidates = (try? FileManager.default.contentsOfDirectory(atPath: repoDir.path)) ?? []
        return candidates
            .filter { $0.contains(variant) }
            .map { repoDir.appendingPathComponent($0) }
            .first { directoryNonEmpty($0.path) }
    }

    /// The one WhisperKit configuration used for loading, shared by the
    /// single-model transcriber and the LID pipeline so neither can end up on
    /// a different cache than the other.
    static func configuration(for model: TranscriptionModel) -> WhisperKitConfig {
        WhisperKitConfig(
            model: model.whisperKitID,
            downloadBase: base(for: model),
            modelRepo: model.modelRepo,
            modelFolder: model.modelFolder,
            verbose: false,
            prewarm: true,
            load: true
        )
    }

    static func directoryNonEmpty(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        return !((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).isEmpty
    }

    // MARK: - iCloud

    /// True when `url` — or, if it doesn't exist yet, its nearest existing
    /// ancestor — sits in a folder iCloud syncs. This is what makes the
    /// difference between "your models are on disk" and "your models are a
    /// 1 GB upload that macOS may evict under you".
    static func isInSyncedFolder(_ url: URL) -> Bool {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { return false }
            probe = parent
        }
        if let values = try? probe.resourceValues(forKeys: [.isUbiquitousItemKey]),
           values.isUbiquitousItem == true
        {
            return true
        }
        // Desktop & Documents sync relocates the folder into the CloudDocs
        // container; if the ubiquity flag didn't answer, the resolved path does.
        return probe.resolvingSymlinksInPath().path.contains("/Library/Mobile Documents/")
    }

    /// How many files under `url` iCloud has already evicted (dataless). Each
    /// one is a materialisation that a concurrent load can deadlock against.
    static func evictedFileCount(under url: URL) -> Int {
        let keys: [URLResourceKey] = [.ubiquitousItemDownloadingStatusKey]
        // Hidden files count: the Hub's `.cache/huggingface/download` metadata
        // lives under a dot-directory, and that is exactly what the failing
        // write in gh#34 was.
        guard let walker = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys
        ) else {
            return 0
        }
        var count = 0
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if values?.ubiquitousItemDownloadingStatus == .notDownloaded { count += 1 }
        }
        return count
    }
}

extension TranscriptionModel {
    /// The Hugging Face repo the CoreML artifacts come from. A nil `modelRepo`
    /// means WhisperKit's default repo.
    var repoID: String { modelRepo ?? ModelCache.defaultRepo }
}
