import SwiftUI
import Combine

/// Reads the microphone level for the meter.
///
/// It stands apart from the settings screen so that a level update redraws the meter alone.
/// The settings screen is large, and 20 redraws per second of the whole page is wasteful.
@MainActor
final class MicLevelStore: ObservableObject {
    @Published private(set) var meterValue: Double = 0
    @Published private(set) var thresholdMeterValue: Double = 0
    @Published private(set) var isHearingVoice = false

    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor in
            while !Task.isCancelled {
                let audio = AudioManager.shared
                let state = audio.voiceState
                meterValue = VoiceActivity.meterValue(forLevel: audio.currentLevel)
                thresholdMeterValue = VoiceActivity.meterValue(forLevel: state.threshold)
                isHearingVoice = state.isHearingVoice
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        meterValue = 0
        isHearingVoice = false
    }
}

/// Shows what the microphone hears, with the mark that a voice has to beat.
///
/// The bar fills with the live level. The handle is the mark. Drag the handle to set it.
struct VoiceLevelMeter: View {
    @Binding var meterValue: Double
    let isAutomatic: Bool
    @ObservedObject var levels: MicLevelStore

    private static let barHeight: CGFloat = 12
    private static let handleWidth: CGFloat = 5

    /// The mark the bar draws. Automatic mode follows the room, so the app owns the mark.
    private var drawnThreshold: Double {
        isAutomatic ? levels.thresholdMeterValue : meterValue
    }

    private var isLoud: Bool {
        levels.meterValue > drawnThreshold
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: Self.barHeight)

                Capsule()
                    .fill(isLoud ? Color.green : Color.primary.opacity(0.35))
                    .frame(width: max(0, width * levels.meterValue), height: Self.barHeight)
                    .animation(.linear(duration: 0.05), value: levels.meterValue)

                RoundedRectangle(cornerRadius: Self.handleWidth / 2)
                    .fill(isAutomatic ? Color.primary.opacity(0.35) : Color.primary)
                    .frame(width: Self.handleWidth, height: Self.barHeight + 10)
                    .offset(x: max(0, min(width - Self.handleWidth, width * drawnThreshold - Self.handleWidth / 2)))
                    .animation(isAutomatic ? .easeOut(duration: 0.25) : nil, value: drawnThreshold)
            }
            .frame(height: Self.barHeight + 10)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !isAutomatic, width > 0 else { return }
                        meterValue = min(1, max(0, value.location.x / width))
                    }
            )
        }
        .frame(height: Self.barHeight + 10)
        .onAppear { levels.start() }
        .onDisappear { levels.stop() }
    }
}
