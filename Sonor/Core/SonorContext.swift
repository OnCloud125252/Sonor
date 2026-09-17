import Foundation

/// The model runs on a background task and the abort request arrives from the hotkey thread,
/// so this type stays off the main actor.
nonisolated public final class SonorContext: @unchecked Sendable {
    private let wrapper: SonorWrapper?

    public init(modelPath: String) {
        // Assigning through a Task left `wrapper` nil right after init returned, so the first
        // transcription after a model load silently produced an empty result.
        self.wrapper = SonorWrapper(modelPath: modelPath)
    }

    /// Stops the running transcription. It returns an empty string soon after.
    public func requestAbort() {
        wrapper?.requestAbort()
    }

    public func transcribe(audioSamples: [Float], language: String = "auto", initialPrompt: String? = nil) async -> String {
        guard let wrapper = wrapper else { return "" }
        return await Task.detached(priority: .userInitiated) {
            var mutableSamples = audioSamples
            return mutableSamples.withUnsafeMutableBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return "" }
                return wrapper.transcribeAudioBuffer(UnsafeMutablePointer(mutating: baseAddress), count: Int32(audioSamples.count), language: language, initialPrompt: initialPrompt)
            }
        }.value
    }
}
