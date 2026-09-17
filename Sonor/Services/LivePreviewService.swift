import Foundation

/// Decides whether the live preview should read the microphone again.
///
/// This is the rule that keeps the words on screen still. The engine reads the whole window
/// again on every pass and returns slightly different words each time, so a pass that nobody
/// asked for rewrites text the user is still reading.
enum LivePreviewGate {

    /// What the audio capture looks like at this moment.
    struct Conditions {
        let isRecording: Bool
        let isPaused: Bool
        let capturedSamples: Int
        /// Uptime in nanoseconds when the microphone last heard a voice. Zero means never.
        let lastVoiceUptime: UInt64
    }

    /// Below one second the buffer holds little more than noise, and the model invents words.
    static let minimumSamples = 16_000

    /// True when a new pass is worth its cost.
    ///
    /// The last test is the one that matters: a pass runs only when the microphone heard a
    /// voice since the pass before. The buffer keeps growing while the room is silent, so a
    /// test on the sample count alone let the engine run for ever on the same quiet audio.
    static func shouldRun(_ conditions: Conditions, lastPassUptime: UInt64) -> Bool {
        guard conditions.isRecording, !conditions.isPaused else { return false }
        guard conditions.capturedSamples >= minimumSamples else { return false }
        return conditions.lastVoiceUptime > lastPassUptime
    }
}

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
                let conditions = LivePreviewGate.Conditions(
                    isRecording: audio.isRecording,
                    isPaused: audio.isPaused,
                    capturedSamples: audio.capturedSampleCount,
                    lastVoiceUptime: audio.lastVoiceUptime
                )
                guard LivePreviewGate.shouldRun(conditions, lastPassUptime: lastPassUptime) else { continue }
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
