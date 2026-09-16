import Foundation
import Darwin
import MachO
import MLXAudioSTT
import MLX
import Hub

final class MLXEngine: TranscriptionEngine {
    var isReady: Bool = false
    var name: String { "MLX (\(repoId))" }
    
    // We store the model as Any because different models might have different types,
    // though they might all conform to a common protocol in MLXAudioSTT.
    // For now, we will handle them specifically.
    private nonisolated(unsafe) var senseVoiceModel: SenseVoiceModel?
    private nonisolated(unsafe) var moonshineModel: MoonshineModel?
    private nonisolated(unsafe) var parakeetModel: ParakeetModel?
    private nonisolated(unsafe) var qwen3ASRModel: Qwen3ASRModel?
    private nonisolated(unsafe) var canaryModel: CanaryModel?
    private nonisolated(unsafe) var nemotronModel: NemotronASRModel?
    private nonisolated(unsafe) var graniteModel: GraniteSpeechModel?
    private nonisolated(unsafe) var fireRedModel: FireRedASR2Model?
    private nonisolated(unsafe) var cohereModel: CohereTranscribeModel?
    
    private let modelId: String
    private let repoId: String
    
    init(modelId: String, repoId: String) {
        self.modelId = modelId
        self.repoId = repoId
    }
    

    
    func prepare() async throws {
        if isReady { return }
        
        let api = HubApi(downloadBase: ModelManager.shared.modelsDirectory, cache: nil, useBackgroundSession: false)
        let repo = Hub.Repo(id: repoId)
        let modelDir = api.localRepoLocation(repo)
        
        // Instantiate the correct model based on the family or id
        // Usually fromPretrained takes a String for the HF repo id or local path. 
        // We will pass the local path.

        
        if repoId.lowercased().contains("sensevoice") {
            self.senseVoiceModel = try SenseVoiceModel.fromDirectory(modelDir)
        } else if repoId.lowercased().contains("moonshine") {
            self.moonshineModel = try await MoonshineModel.fromModelDirectory(modelDir)
        } else if repoId.lowercased().contains("parakeet") {
            self.parakeetModel = try ParakeetModel.fromDirectory(modelDir)
        } else if repoId.lowercased().contains("qwen3") {
            self.qwen3ASRModel = try await Qwen3ASRModel.fromModelDirectory(modelDir)
        } else if repoId.lowercased().contains("canary") {
            self.canaryModel = try await CanaryModel.fromModelDirectory(modelDir)
        } else if repoId.lowercased().contains("nemotron") {
            self.nemotronModel = try NemotronASRModel.fromDirectory(modelDir)
        } else if repoId.lowercased().contains("granite") {
            self.graniteModel = try await GraniteSpeechModel.fromModelDirectory(modelDir)
        } else if repoId.lowercased().contains("firered") {
            self.fireRedModel = try FireRedASR2Model.fromDirectory(modelDir)
        } else if repoId.lowercased().contains("cohere") {
            self.cohereModel = try CohereTranscribeModel.fromDirectory(modelDir)
        } else {
            throw NSError(domain: "MLXEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported MLX model type: \(repoId)"])
        }
        
        isReady = true
    }
    
    func transcribe(audioSamples: [Float], language: TranscriptionLanguage, vocabularyHints: [String]) async throws -> String {
        guard isReady else {
            throw NSError(domain: "MLXEngine", code: 2, userInfo: [NSLocalizedDescriptionKey: "Model not loaded"])
        }
        guard !audioSamples.isEmpty else { return "" }
        
        if repoId.lowercased().contains("qwen3") && !CommandLine.arguments.contains("--worker-mode") {
            return try await runInWorker(audioSamples: audioSamples, language: language, vocabularyHints: vocabularyHints)
        }
        
        return try await performTranscription(audioSamples: audioSamples, language: language, vocabularyHints: vocabularyHints)
    }
    
    private func runInWorker(audioSamples: [Float], language: TranscriptionLanguage, vocabularyHints: [String]) async throws -> String {
        // Write audio samples to a temporary file
        let tempDir = FileManager.default.temporaryDirectory
        let audioFile = tempDir.appendingPathComponent(UUID().uuidString + ".raw")
        
        let audioData = audioSamples.withUnsafeBufferPointer { Data(buffer: $0) }
        try audioData.write(to: audioFile)

        // A term may hold a comma, so the list travels as JSON rather than as joined text.
        let encodedHints = (try? JSONEncoder().encode(vocabularyHints))?.base64EncodedString() ?? ""

        return try await Task.detached {
            defer {
                try? FileManager.default.removeItem(at: audioFile)
            }
            
            guard let executablePath = Bundle.main.executablePath else {
                throw NSError(domain: "MLXEngine", code: 10, userInfo: [NSLocalizedDescriptionKey: "Cannot find executable path"])
            }
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = [
                "--worker-mode",
                "--repo-id", self.repoId,
                "--audio", audioFile.path,
                "--language", language.code,
                "--vocabulary", encodedHints
            ]
            
            let pipe = Pipe()
            process.standardOutput = pipe
            
            // Run process
            try process.run()
            
            // READ FIRST to prevent deadlock! If the child process writes more than 64KB, 
            // it will block waiting for the parent to read. If the parent is blocked in 
            // waitUntilExit(), both will hang forever.
            let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            
            let outputString = String(data: outputData, encoding: .utf8) ?? ""
            
            if process.terminationStatus != 0 || process.terminationReason == .uncaughtSignal {
                // This is the magic! If Qwen3 crashes with OOM (abort), we catch it here instead of crashing the main app!
                throw NSError(domain: "MLXEngine", code: 4, userInfo: [NSLocalizedDescriptionKey: String(localized: "OOM Warning: Brakuje RAMu dla tego nagrania. Zamknij inne programy, albo użyj lżejszego modelu.")])
            }
            
            for line in outputString.components(separatedBy: .newlines) {
                if line.hasPrefix("SUCCESS:") {
                    let base64 = String(line.dropFirst("SUCCESS:".count))
                    if let data = Data(base64Encoded: base64), let text = String(data: data, encoding: .utf8) {
                        return text
                    }
                } else if line.hasPrefix("ERROR:") {
                    let errorText = String(line.dropFirst("ERROR:".count))
                    throw NSError(domain: "MLXEngine", code: 5, userInfo: [NSLocalizedDescriptionKey: errorText])
                }
            }
            
            throw NSError(domain: "MLXEngine", code: 6, userInfo: [NSLocalizedDescriptionKey: "Worker process failed silently"])
        }.value
    }
    
    func performTranscription(audioSamples: [Float], language: TranscriptionLanguage, vocabularyHints: [String]) async throws -> String {

        // Every binding reads the language from the shared parameter block, so a model that
        // supports the choice only needs `withLanguage`. The models that drop the field keep
        // detecting the language themselves.
        let languageCode = language.mlxCode
        let vocabulary = vocabularyHints.joined(separator: ", ")

        // The unload timer can fire while this runs. Capturing the model here keeps it alive
        // for the whole transcription instead of letting `unload()` release it mid-flight.
        let senseVoice = senseVoiceModel
        let moonshine = moonshineModel
        let parakeet = parakeetModel
        let qwen3ASR = qwen3ASRModel
        let canary = canaryModel
        let nemotron = nemotronModel
        let granite = graniteModel
        let fireRed = fireRedModel
        let cohere = cohereModel

        return await Task.detached {
            defer {
                MLX.Memory.clearCache()
            }
            let mlxAudio = MLXArray(audioSamples)
            eval(mlxAudio)
            
            if let model = senseVoice {
                let output = model.generate(audio: mlxAudio, generationParameters: model.defaultGenerationParameters.withLanguage(languageCode))
                return output.text
            } else if let model = moonshine {
                // Moonshine reads English alone and its binding drops the language.
                let output = model.generate(audio: mlxAudio)
                return output.text
            } else if let model = parakeet {
                // The binding copies the language into the result but never into the decoder,
                // so forcing one would change nothing. Parakeet detects it instead.
                let output = model.generate(audio: mlxAudio)
                return output.text
            } else if let model = qwen3ASR {
                // Qwen3 puts `context` in the system turn. That is where a vocabulary hint belongs.
                let base = model.defaultGenerationParameters
                let output = model.generate(
                    audio: mlxAudio,
                    maxTokens: base.maxTokens,
                    temperature: base.temperature,
                    context: vocabulary,
                    language: languageCode,
                    chunkDuration: base.chunkDuration,
                    minChunkDuration: base.minChunkDuration,
                    repetitionPenalty: base.repetitionPenalty,
                    repetitionContextSize: base.repetitionContextSize
                )
                return output.text
            } else if let model = canary {
                let output = model.generate(audio: mlxAudio, generationParameters: model.defaultGenerationParameters.withLanguage(languageCode))
                return output.text
            } else if let model = nemotron {
                let output = model.generate(audio: mlxAudio, generationParameters: model.defaultGenerationParameters.withLanguage(languageCode))
                return output.text
            } else if let model = granite {
                // Granite turns a language into a "Translate the speech to X." instruction, and
                // its `prompt` field replaces that instruction rather than hinting vocabulary.
                // Sonor passes neither, so Granite transcribes what it heard.
                let output = model.generate(audio: mlxAudio)
                return output.text
            } else if let model = fireRed {
                let output = model.generate(audio: mlxAudio, generationParameters: model.defaultGenerationParameters.withLanguage(languageCode))
                return output.text
            } else if let model = cohere {
                let output = model.generate(audio: mlxAudio, generationParameters: model.defaultGenerationParameters.withLanguage(languageCode))
                return output.text
            }
            
            return ""
        }.value
    }
    
    func unload() {
        self.senseVoiceModel = nil
        self.moonshineModel = nil
        self.parakeetModel = nil
        self.qwen3ASRModel = nil
        self.canaryModel = nil
        self.nemotronModel = nil
        self.graniteModel = nil
        self.fireRedModel = nil
        self.cohereModel = nil
        self.isReady = false
        // Force garbage collection of MLX memory
        MLX.Memory.clearCache()
    }
}

private extension STTGenerateParameters {
    /// Returns a copy that asks the decoder for one language.
    ///
    /// Every other field keeps the value the model shipped with, so a tuned chunk length or
    /// repetition penalty survives.
    func withLanguage(_ language: String?) -> STTGenerateParameters {
        STTGenerateParameters(
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP,
            topK: topK,
            verbose: verbose,
            language: language,
            chunkDuration: chunkDuration,
            minChunkDuration: minChunkDuration,
            repetitionPenalty: repetitionPenalty,
            repetitionContextSize: repetitionContextSize,
            kvBits: kvBits,
            kvGroupSize: kvGroupSize,
            quantizedKVStart: quantizedKVStart
        )
    }
}
