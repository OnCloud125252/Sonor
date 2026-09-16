import Foundation

public protocol TranscriptionEngine {
    var name: String { get }
    var isReady: Bool { get }
    
    func prepare() async throws
    
    /// - Parameter vocabularyHints: Words the model should expect, such as dictionary terms and
    ///   snippet triggers. Each engine formats the list the way its backend wants. A model that
    ///   reads no hint ignores the list.
    func transcribe(audioSamples: [Float], language: TranscriptionLanguage, vocabularyHints: [String]) async throws -> String

    /// Stops a running transcription if the backend allows it.
    ///
    /// The live preview and the final transcription share one engine, so a preview pass that
    /// nobody waits for must release the engine early.
    func cancelCurrent()
    
    func unload()
}

public extension TranscriptionEngine {
    /// Backends with no stop hook simply run to the end.
    func cancelCurrent() {}
}
