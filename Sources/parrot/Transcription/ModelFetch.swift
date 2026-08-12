import Foundation
import WhisperKit

/// Downloads a model into the Hub cache (see `ModelCache`) with visible
/// progress, before WhisperKit loads it.
///
/// WhisperKit's own download path (WhisperKit(config)) silently fetches
/// gigabytes with verbose off, which reads as a hang on first run. So we
/// pre-fetch here and let the subsequent load find the cache and skip the
/// download. Model-folder overrides (PARROT_NB_MODEL_FOLDER) never download.
enum ModelFetch {
    /// True when the model has no explicit local folder and nothing matching it
    /// is cached on disk yet — in either cache base, so an existing Documents
    /// cache is not re-downloaded (gh#34).
    static func needsDownload(_ model: TranscriptionModel) -> Bool {
        guard let variant = model.whisperKitID, model.modelFolder == nil else {
            return false
        }
        return ModelCache.cachedVariantDirectory(
            base: ModelCache.base(for: model),
            repo: model.repoID,
            variant: variant
        ) == nil
    }

    /// Downloads and reports `\r`-overwritten percent lines on stderr. On
    /// success the progress line is cleared so the caller's load message
    /// starts on a fresh line.
    static func download(_ model: TranscriptionModel) async throws {
        guard let variant = model.whisperKitID else {
            throw TranscriberError.missingEngineID
        }
        FileHandle.standardError.write(Data("↓ downloading \(model.id) (\(model.sizeMB) MB)…\n".utf8))
        let renderer = ProgressRenderer(label: model.id)
        _ = try await WhisperKit.download(
            variant: variant,
            downloadBase: ModelCache.base(for: model),
            from: model.repoID,
            progressCallback: { renderer.update($0) }
        )
        FileHandle.standardError.write(Data(("\r" + String(repeating: " ", count: 64) + "\r").utf8))
    }

    /// Throttled `\r` progress bar. WhisperKit drives it from a background
    /// queue, so keep the write cadence ~5 Hz and only on a visible change.
    private final class ProgressRenderer {
        private let label: String
        private var lastWrite = Date.distantPast
        private var lastPercent = -1

        init(label: String) {
            self.label = label
        }

        func update(_ progress: Progress) {
            let now = Date()
            guard now.timeIntervalSince(lastWrite) > 0.2 else { return }
            let percent = Int(progress.fractionCompleted * 100)
            guard percent != lastPercent else { return }
            lastWrite = now
            lastPercent = percent
            let width = 25
            let filled = min(max(percent, 0), 100) * width / 100
            let bar = String(repeating: "█", count: filled)
                + String(repeating: "░", count: width - filled)
            FileHandle.standardError.write(Data("\r↓ \(label) \(bar) \(percent)%".utf8))
        }
    }
}
