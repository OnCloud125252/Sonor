import Foundation

/// Decides when the microphone hears a voice and not just the room.
///
/// The live preview reads this. Without it the preview runs the transcription model again and
/// again on the same silent buffer, and the text on screen keeps changing by itself.
/// The audio thread reads the threshold on every buffer, so nothing here may touch the main actor.
nonisolated public enum VoiceActivity {

    /// `automatic` follows the room. `manual` uses the mark the user set on the meter.
    public enum Mode: String {
        case automatic
        case manual
    }

    public static let modeKey = "voiceThresholdMode"
    public static let levelKey = "voiceThresholdLevel"

    /// Where the mark sits when the user first switches to manual.
    public static let defaultMeterValue: Double = 0.35

    /// The meter covers this much of the loudness range. Below it there is nothing to hear.
    public static let floorDecibels: Double = -60

    /// A voice must beat the room by this much in automatic mode.
    public static let voiceOverNoise: Float = 3.0

    /// Hard bottom for automatic mode, for a room that is almost silent.
    public static let minimumLevel: Float = 0.006

    /// Turns a raw level reading into the 0 to 1 that the meter draws.
    ///
    /// Loudness grows by multiplication, not by addition. A straight line would push every
    /// normal voice into the first tenth of the bar and leave the rest empty.
    public static func meterValue(forLevel level: Float) -> Double {
        guard level > 0 else { return 0 }
        let decibels = 20 * log10(Double(level))
        return min(1, max(0, (decibels - floorDecibels) / -floorDecibels))
    }

    /// Bottom of the band the waveform draws. A quiet room sits below it.
    public static let waveformQuietDecibels: Double = -45
    /// Top of the band. A shout sits above it.
    public static let waveformLoudDecibels: Double = -12

    /// Bar height for the waveform, 0 to 1.
    ///
    /// The curve is flat at both ends and steep in the middle. A plain logarithm spends most
    /// of the bar on room noise, so the bars never fell to the floor between words, and it
    /// spends the rest on shouting, so one loud syllable spikes far above the others. Speech
    /// lives in the middle, and that is where the bar has to move.
    public static func waveformValue(forLevel level: Float) -> Double {
        guard level > 0 else { return 0 }
        let decibels = 20 * log10(Double(level))
        let band = waveformLoudDecibels - waveformQuietDecibels
        let position = min(1, max(0, (decibels - waveformQuietDecibels) / band))
        // Smoothstep: it starts flat, rises fast, and settles flat again.
        return position * position * (3 - 2 * position)
    }

    /// Turns a mark on the meter back into a level reading.
    public static func level(forMeterValue value: Double) -> Float {
        let clamped = min(1, max(0, value))
        let decibels = floorDecibels + clamped * -floorDecibels
        return Float(pow(10, decibels / 20))
    }

    /// The level a voice must beat right now.
    public static func threshold(manual: Float?, noiseFloor: Float) -> Float {
        if let manual {
            return manual
        }
        return max(minimumLevel, noiseFloor * voiceOverNoise)
    }

    /// Reads the saved setting. Nil means automatic.
    public static func savedManualLevel(in defaults: UserDefaults = .standard) -> Float? {
        guard defaults.string(forKey: modeKey) == Mode.manual.rawValue else { return nil }
        let stored = defaults.object(forKey: levelKey) as? Double ?? defaultMeterValue
        return level(forMeterValue: stored)
    }
}
