import Foundation
import WhisperKit

actor WhisperKitTranscriber: Transcriber {
    let modelID: String
    private let model: TranscriptionModel
    /// Forced decode language (e.g. "no" for the NB route). nil → the model's
    /// own default behavior (English-only models don't take a language token).
    private let language: String?
    /// Optional load-time recorder used by `parrot bench warmup`; nil in normal use.
    private let recorder: WarmUpRecorder?
    private var pipeline: WhisperKit?

    init(model: TranscriptionModel, language: String? = nil, recorder: WarmUpRecorder? = nil) {
        self.modelID = model.id
        self.model = model
        self.language = language
        self.recorder = recorder
    }

    /// Loads the model into memory; downloads first if not already on disk.
    /// Call once at startup so the first hotkey press isn't blocked on model
    /// download/load.
    func warmUp() async throws {
        if pipeline != nil { return }
        guard let whisperKitID = model.whisperKitID else {
            throw TranscriberError.missingEngineID
        }
        if ModelFetch.needsDownload(model) {
            try await ModelFetch.download(model)
        }
        FileHandle.standardError.write(Data("loading \(model.id)...\n".utf8))
        let config = WhisperKitConfig(
            model: whisperKitID,
            modelRepo: model.modelRepo,
            modelFolder: model.modelFolder,
            verbose: false,
            prewarm: true,
            load: true
        )
        let started = recorder?.now()
        pipeline = try await WhisperKit(config)
        if let recorder, let started {
            recorder.record(modelID: model.id, start: started, end: recorder.now())
        }
        FileHandle.standardError.write(Data("✓ \(model.id) ready\n".utf8))
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        if pipeline == nil { try await warmUp() }
        guard let pipeline else { throw TranscriberError.notLoaded }

        var options: DecodingOptions?
        if let language {
            options = DecodingOptions(
                task: .transcribe,
                language: language,
                temperature: 0,
                detectLanguage: false
            )
        }
        let results = try await pipeline.transcribe(audioArray: audio, decodeOptions: options)
        let raw = results.map(\.text).joined(separator: " ")
        return Self.sanitize(raw)
    }

    /// Strip Whisper's non-speech bracket tokens ([BLANK_AUDIO], [MUSIC],
    /// (silence), <|nospeech|>, etc.) and collapse whitespace. When the model
    /// hears silence it emits these literally; we don't want to paste them.
    /// NB-Whisper emits the same bracket-token families on silence, so the
    /// same patterns cover both routes; extend here if new markers show up.
    static func sanitize(_ text: String) -> String {
        let patterns = [
            #"\[[^\]]*\]"#,        // [BLANK_AUDIO], [MUSIC], [Applause]
            #"\([^)]*\)"#,          // (silence), (music playing)
            #"<\|[^|]*\|>"#,        // <|nospeech|>, <|endoftext|>
            #"\*[^*]*\*"#,          // *background noise*
        ]
        var out = text
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TranscriberError: Error {
    case missingEngineID
    case notLoaded
}
