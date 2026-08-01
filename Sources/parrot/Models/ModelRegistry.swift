import Foundation

/// Built-in transcription model registry.
///
/// The model list lives directly in source rather than as a JSON resource so
/// the binary stays self-contained — no `Bundle.module` lookup, no per-target
/// resource bundle to ship alongside the executable.
enum ModelRegistry {
    /// HF repo holding the converted NB-Whisper CoreML artifacts. Produced by
    /// scripts/convert-nb-whisper.sh; override per-model via `modelFolder` or
    /// at runtime with PARROT_NB_MODEL_FOLDER for a local conversion.
    /// Namespace is the Hugging Face account, which is not the GitHub one.
    static let nbWhisperRepo = "Barrymanalow/nb-whisper-coreml"

    static let shared: [TranscriptionModel] = [
        TranscriptionModel(
            id: "whisper-base.en",
            displayName: "Whisper Base (English)",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-base.en",
            sizeMB: 145,
            languages: ["en"],
            recommended: true
        ),
        TranscriptionModel(
            id: "whisper-large-v3-turbo",
            displayName: "Whisper Large v3 Turbo",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-large-v3-v20240930_turbo",
            sizeMB: 1620,
            languages: ["multi"],
            recommended: false
        ),
        TranscriptionModel(
            id: "whisper-small.en",
            displayName: "Whisper Small (English)",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-small.en",
            sizeMB: 488,
            languages: ["en"],
            recommended: false
        ),
        TranscriptionModel(
            id: "nb-whisper-small",
            displayName: "NB-Whisper Small (Norwegian)",
            engine: .whisperKit,
            whisperKitID: "nb-whisper-small",
            sizeMB: 500,
            languages: ["no"],
            recommended: false,
            modelRepo: nbWhisperRepo,
            modelFolder: ProcessInfo.processInfo.environment["PARROT_NB_MODEL_FOLDER"]
        ),
        TranscriptionModel(
            id: "nb-whisper-base",
            displayName: "NB-Whisper Base (Norwegian)",
            engine: .whisperKit,
            whisperKitID: "nb-whisper-base",
            sizeMB: 150,
            languages: ["no"],
            recommended: false,
            modelRepo: nbWhisperRepo
        ),
        // Internal dependency of --bilingual: multilingual tiny used only for
        // per-utterance language identification, never for transcription.
        TranscriptionModel(
            id: "whisper-tiny",
            displayName: "Whisper Tiny (multilingual, LID)",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-tiny",
            sizeMB: 42,
            languages: ["multi"],
            recommended: false,
            hidden: true
        ),
    ]

    static func find(_ id: String) -> TranscriptionModel? {
        shared.first { $0.id == id }
    }

    static func recommended() -> TranscriptionModel? {
        shared.first { $0.recommended } ?? shared.first
    }
}

/// Resolved model set for `parrot --bilingual`: NB-Whisper for the Norwegian
/// route, an English Whisper for the English route, multilingual tiny for LID.
///
/// This is deliberately a flag-level composite, not a registry entry — the
/// registry stays purely per-model (spec §10.1).
struct BilingualConfiguration {
    static let defaultNorwegianModelID = "nb-whisper-small"
    static let defaultEnglishModelID = "whisper-small.en"
    static let lidModelID = "whisper-tiny"

    let norwegian: TranscriptionModel
    let english: TranscriptionModel
    let lid: TranscriptionModel
    let policy: RoutingPolicy

    var models: [TranscriptionModel] { [lid, norwegian, english] }

    /// Menu bar label, e.g. "nb-small+en-small".
    var shortLabel: String {
        "\(Self.abbreviate(norwegian.id))+\(Self.abbreviate(english.id))"
    }

    enum ConfigurationError: Error, CustomStringConvertible {
        case unknownModel(String)
        var description: String {
            switch self {
            case .unknownModel(let id):
                return "unknown model: \(id) — run `parrot models list --all` to see options."
            }
        }
    }

    init(
        norwegianModelID: String = defaultNorwegianModelID,
        englishModelID: String = defaultEnglishModelID,
        englishThreshold: Float = RoutingPolicy.defaultEnglishThreshold
    ) throws {
        guard let no = ModelRegistry.find(norwegianModelID) else {
            throw ConfigurationError.unknownModel(norwegianModelID)
        }
        guard let en = ModelRegistry.find(englishModelID) else {
            throw ConfigurationError.unknownModel(englishModelID)
        }
        guard let lid = ModelRegistry.find(Self.lidModelID) else {
            throw ConfigurationError.unknownModel(Self.lidModelID)
        }
        self.norwegian = no
        self.english = en
        self.lid = lid
        self.policy = RoutingPolicy(englishThreshold: englishThreshold)
    }

    /// "nb-whisper-small" → "nb-small", "whisper-small.en" → "en-small",
    /// "whisper-base.en" → "en-base". Anything else passes through unchanged.
    static func abbreviate(_ id: String) -> String {
        if id.hasPrefix("nb-whisper-") {
            return "nb-" + id.dropFirst("nb-whisper-".count)
        }
        if id.hasPrefix("whisper-"), id.hasSuffix(".en") {
            return "en-" + id.dropFirst("whisper-".count).dropLast(".en".count)
        }
        return id
    }
}
