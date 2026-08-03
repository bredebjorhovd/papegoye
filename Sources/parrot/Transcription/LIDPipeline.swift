import Foundation
import WhisperKit

/// Loading the language-identification pipeline.
///
/// Shared by `RoutingTranscriber` (which keeps it warm for the whole session)
/// and `parrot bench lid` (which times it), so the bench measures the same
/// pipeline the daemon actually routes on — same repo, same folder override,
/// same prewarm.
enum LIDPipeline {
    static func load(_ model: TranscriptionModel, recorder: WarmUpRecorder? = nil) async throws -> WhisperKit {
        do {
            guard let whisperKitID = model.whisperKitID else {
                throw TranscriberError.missingEngineID
            }
            FileHandle.standardError.write(Data("loading \(model.id) (lid)...\n".utf8))
            if ModelFetch.needsDownload(model) {
                try await ModelFetch.download(model)
            }
            let config = WhisperKitConfig(
                model: whisperKitID,
                modelRepo: model.modelRepo,
                modelFolder: model.modelFolder,
                verbose: false,
                prewarm: true,
                load: true
            )
            let started = recorder?.now()
            let pipeline = try await WhisperKit(config)
            if let recorder, let started {
                recorder.record(modelID: "\(model.id) (lid)", start: started, end: recorder.now())
            }
            FileHandle.standardError.write(Data("✓ \(model.id) ready\n".utf8))
            return pipeline
        } catch {
            throw RoutingTranscriberError.modelUnavailable(model.id, error)
        }
    }
}
