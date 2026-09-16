import Foundation
import Speech
import AVFoundation
import os

public class AppleSpeechEngine: TranscriptionEngine {
    public let name: String = "Apple Speech (System)"
    
    private var systemRecognizer: SFSpeechRecognizer?

    /// One recognizer per forced language.
    ///
    /// `SFSpeechRecognizer` binds its locale when it is created, so a language change needs a
    /// new instance. Building one per recording would drop the on-device model each time.
    private var localeRecognizers: [String: SFSpeechRecognizer] = [:]

    public var isReady: Bool {
        return systemRecognizer != nil
    }
    
    public init() {}
    
    public func prepare() async throws {
        // Request authorization if needed
        let authStatus = SFSpeechRecognizer.authorizationStatus()
        if authStatus == .notDetermined {
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { _ in
                    continuation.resume()
                }
            }
        }
        
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw NSError(domain: "AppleSpeechEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech recognition not authorized."])
        }
        
        // Initialize recognizer with the default locale or let it automatically detect
        self.systemRecognizer = SFSpeechRecognizer()
        if self.systemRecognizer?.isAvailable == false {
            throw NSError(domain: "AppleSpeechEngine", code: 2, userInfo: [NSLocalizedDescriptionKey: "Speech recognizer is not available."])
        }
    }

    /// Returns the recognizer for the chosen language.
    ///
    /// Apple ships a fixed set of dictation locales. When the chosen one is missing, the system
    /// recognizer still returns text, so Sonor falls back instead of losing the recording.
    private func recognizer(for language: TranscriptionLanguage) throws -> SFSpeechRecognizer {
        guard let systemRecognizer = systemRecognizer else {
            throw NSError(domain: "AppleSpeechEngine", code: 3, userInfo: [NSLocalizedDescriptionKey: "Engine not prepared."])
        }
        guard let locale = language.appleLocale else { return systemRecognizer }
        if let cached = localeRecognizers[locale.identifier] { return cached }
        guard let made = SFSpeechRecognizer(locale: locale), made.isAvailable else {
            return systemRecognizer
        }
        localeRecognizers[locale.identifier] = made
        return made
    }

    public func transcribe(audioSamples: [Float], language: TranscriptionLanguage, vocabularyHints: [String]) async throws -> String {
        let recognizer = try recognizer(for: language)
        
        // Sonor provides 16kHz mono PCM Float arrays
        let sampleRate: Double = 16000.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw NSError(domain: "AppleSpeechEngine", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio format."])
        }
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audioSamples.count)) else {
            throw NSError(domain: "AppleSpeechEngine", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio buffer."])
        }
        
        buffer.frameLength = buffer.frameCapacity
        if let channelData = buffer.floatChannelData?[0] {
            audioSamples.withUnsafeBufferPointer { sourcePtr in
                channelData.update(from: sourcePtr.baseAddress!, count: audioSamples.count)
            }
        }
        
        let request = SFSpeechAudioBufferRecognitionRequest()
        // Apple biases the decoder toward these words. This is its version of an initial prompt.
        request.contextualStrings = vocabularyHints
        request.append(buffer)
        request.endAudio()


        // SFSpeechRecognizer can report an error after a result, and it can stop without ever
        // sending a final result. Both cases must resume the continuation exactly once.
        let hasResumed = OSAllocatedUnfairLock(initialState: false)
        return try await withCheckedThrowingContinuation { continuation in
            var task: SFSpeechRecognitionTask?
            let finish: (Result<String, Error>) -> Void = { outcome in
                let alreadyResumed = hasResumed.withLock { resumed -> Bool in
                    if resumed { return true }
                    resumed = true
                    return false
                }
                guard !alreadyResumed else { return }
                continuation.resume(with: outcome)
            }

            task = recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    finish(.failure(error))
                    return
                }

                guard let result = result else {
                    finish(.failure(NSError(domain: "AppleSpeechEngine", code: 6, userInfo: [NSLocalizedDescriptionKey: "Speech recognition returned no result."])))
                    return
                }

                if result.isFinal {
                    finish(.success(result.bestTranscription.formattedString))
                }
            }

            // Audio is appended up front and ended immediately, so recognition is bounded.
            // This guards against a task that goes silent and never delivers a final result.
            Task {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !hasResumed.withLock({ $0 }) else { return }
                task?.cancel()
                finish(.failure(NSError(domain: "AppleSpeechEngine", code: 7, userInfo: [NSLocalizedDescriptionKey: "Speech recognition timed out."])))
            }
        }
    }
    
    public func unload() {
        self.systemRecognizer = nil
        self.localeRecognizers.removeAll()
    }
}
