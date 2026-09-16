import Foundation

public class WhisperEngine: TranscriptionEngine {
    public let name: String = "Whisper (Local)"
    
    // We store the context here so it gets deallocated when the engine is unloaded.
    private var context: SonorContext?
    private let modelPath: String
    
    public var isReady: Bool {
        return context != nil
    }
    
    public init(modelPath: String) {
        self.modelPath = modelPath
    }
    
    public func prepare() async throws {
        if context != nil { return }
        
        // This simulates downloading or warming up. For Whisper, it loads the model into RAM/VRAM.
        let newContext = await Task.detached { [modelPath] in
            return SonorContext(modelPath: modelPath)
        }.value
        
        self.context = newContext
    }
    
    public func transcribe(audioSamples: [Float], language: TranscriptionLanguage, vocabularyHints: [String]) async throws -> String {
        guard let context = context else {
            throw NSError(domain: "WhisperEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Model not prepared."])
        }
        // whisper.cpp reads `initial_prompt` as free text, so the seed and the words arrive as
        // one line. An `.en` build drops the language itself, so no check is needed here.
        var promptParts: [String] = []
        if let seed = language.scriptSeedPrompt { promptParts.append(seed) }
        if !vocabularyHints.isEmpty { promptParts.append(vocabularyHints.joined(separator: ", ")) }
        let initialPrompt = promptParts.isEmpty ? nil : promptParts.joined(separator: " ")
        return await context.transcribe(audioSamples: audioSamples, language: language.whisperCode, initialPrompt: initialPrompt)
    }
    
    public func cancelCurrent() {
        context?.requestAbort()
    }

    public func unload() {
        // Destroy the context, freeing up RAM/VRAM
        self.context = nil
    }
}
