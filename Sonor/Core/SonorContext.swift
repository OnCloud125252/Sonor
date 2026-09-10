import Foundation
import Combine

public class SonorContext: ObservableObject, @unchecked Sendable {
    private var wrapper: SonorWrapper?
    @Published public var isTranscribing = false
    
    nonisolated public init(modelPath: String) {
        // Assigning through a Task left `wrapper` nil right after init returned, so the first
        // transcription after a model load silently produced an empty result.
        self.wrapper = SonorWrapper(modelPath: modelPath)
    }
    
    public func transcribe(audioSamples: [Float], language: String = "auto", initialPrompt: String? = nil) async -> String {
        guard let wrapper = wrapper else { return "" }
        await MainActor.run {
            self.isTranscribing = true
        }
        let result = await Task.detached(priority: .userInitiated) {
            var mutableSamples = audioSamples
            return mutableSamples.withUnsafeMutableBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return "" }
                return wrapper.transcribeAudioBuffer(UnsafeMutablePointer(mutating: baseAddress), count: Int32(audioSamples.count), language: language, initialPrompt: initialPrompt)
            }
        }.value
        await MainActor.run {
            self.isTranscribing = false
        }
        return result
    }
}
