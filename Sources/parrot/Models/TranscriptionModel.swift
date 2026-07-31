import Foundation

enum Engine: String, Codable {
    case whisperKit
    case parakeet
}

struct TranscriptionModel: Codable {
    let id: String
    let displayName: String
    let engine: Engine
    /// Engine-specific identifier (e.g. "openai_whisper-base.en" for WhisperKit).
    let whisperKitID: String?
    let sizeMB: Int
    let languages: [String]
    let recommended: Bool
    /// Custom HF repo for CoreML artifacts. nil → WhisperKit's default repo
    /// (argmaxinc/whisperkit-coreml). NB-Whisper lives outside the default repo.
    let modelRepo: String?
    /// Local path to a converted model on disk; takes precedence over download.
    let modelFolder: String?
    /// Hidden models are internal dependencies (e.g. the tiny LID model) and
    /// are skipped by `models list` unless --all is passed.
    let hidden: Bool

    init(
        id: String,
        displayName: String,
        engine: Engine,
        whisperKitID: String?,
        sizeMB: Int,
        languages: [String],
        recommended: Bool,
        modelRepo: String? = nil,
        modelFolder: String? = nil,
        hidden: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.engine = engine
        self.whisperKitID = whisperKitID
        self.sizeMB = sizeMB
        self.languages = languages
        self.recommended = recommended
        self.modelRepo = modelRepo
        self.modelFolder = modelFolder
        self.hidden = hidden
    }
}

struct ModelsManifest: Codable {
    let models: [TranscriptionModel]
}
