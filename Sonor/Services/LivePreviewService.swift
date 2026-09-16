import Foundation

/// Runs the transcription engine again and again while the user speaks, so the HUD can show
/// the words before the recording stops.
///
/// The pass rate follows the speed of the model. A slow model simply refreshes less often.
@MainActor
final class LivePreviewService {
    static let shared = LivePreviewService()

    /// Whisper reads audio in 30 second blocks, so a 30 second window is one block and costs
    /// the least per second of speech. Long silences are cut out before the window is filled,
    /// so a pause does not push earlier words out of it.
    static let windowSeconds: Double = 30
    /// Shortest gap between two passes. The preview model reads a window in well under a
    /// second, so the gap only decides how soon a new voice reaches the screen.
    private static let gap: Duration = .milliseconds(150)
    /// Below one second the buffer holds little more than noise, and the model invents words.
    private static let minimumSamples = 16_000

    private var task: Task<Void, Never>?

    private init() {}

    var isRunning: Bool {
        task != nil
    }

    func start(onText: @escaping @MainActor (String) -> Void) {
        stop()
        task = Task { @MainActor in
            var lastPassUptime: UInt64 = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.gap)
                guard !Task.isCancelled else { return }

                let audio = AudioManager.shared
                guard audio.isRecording, !audio.isPaused else { continue }
                guard audio.capturedSampleCount >= Self.minimumSamples else { continue }

                // A pass runs only when the microphone heard a voice since the pass before.
                // The engine reads the whole window again every time, and it returns slightly
                // different words each time. Without this test the text on screen keeps
                // changing while the user says nothing.
                guard audio.lastVoiceUptime > lastPassUptime else { continue }
                lastPassUptime = DispatchTime.now().uptimeNanoseconds

                let samples = audio.snapshotSamples(maxSeconds: Self.windowSeconds)
                guard let text = await TranscriptionManager.shared.transcribePreview(audioSamples: samples) else { continue }
                guard !Task.isCancelled else { return }

                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                onText(trimmed)
            }
        }
    }

    func stop() {
        guard task != nil else { return }
        task?.cancel()
        task = nil
        // The preview model is given back at once. It loads again in about a tenth of a
        // second, so holding its memory between dictations buys nothing.
        TranscriptionManager.shared.releasePreviewEngine()
    }
}
