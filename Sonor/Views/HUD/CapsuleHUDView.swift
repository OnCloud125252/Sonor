import SwiftUI
import Combine
import AppKit

/// Draws the 20 Hz waveform. It observes only `AudioLevelStore`, so the level updates do not
/// invalidate the surrounding HUD buttons, glass surfaces and mode selector.
struct AudioWavesView: View {
    @ObservedObject var levelStore: AudioLevelStore
    let barCount: Int
    let isPaused: Bool
    let textColor: Color

    /// Shortest bar, drawn while the room is quiet.
    static let minimumBarHeight: CGFloat = 3
    /// Tallest bar. The capsule is 40 points tall, so this leaves a clear margin above and
    /// below. Bars that reach 40 touch the glass and the waveform reads as a solid block.
    static let maximumBarHeight: CGFloat = 24

    /// Height of one bar from a value of 0 to 1.
    ///
    /// `AppController` already turned the microphone reading into that value, so the drawing
    /// code does no audio math.
    static func barHeight(for value: Float) -> CGFloat {
        let clamped = CGFloat(min(1, max(0, value)))
        return minimumBarHeight + clamped * (maximumBarHeight - minimumBarHeight)
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(levelStore.levels.suffix(barCount).enumerated()), id: \.offset) { _, level in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isPaused ? textColor.opacity(0.4) : textColor)
                    .frame(width: 3, height: AudioWavesView.barHeight(for: level))
            }
        }
    }
}

struct CapsuleHUDView: View {
    @ObservedObject var controller: AppController
    // `LLMManager.shared.isAvailable` reads these two objects, so the assistant selector
    // appears as soon as a local model finishes downloading or an API endpoint is saved.
    @ObservedObject var modelManager = ModelManager.shared
    @ObservedObject var llmSettings = LLMSettings.shared
    /// The HUD panel is only ordered out, never closed, so SwiftUI keeps rendering it while
    /// it is offscreen. The spinner's `TimelineView(.animation)` then redrew the hidden HUD
    /// at display rate forever (about 15% CPU after every dictation). This flag pauses it.
    @State private var isHUDVisible = false
    @AppStorage("appTheme") private var appTheme = "system"
    @AppStorage("hudPositionMode") private var hudPositionMode: HUDPositionMode = .free
    @AppStorage("overlayDuration") private var overlayDuration: Double = 15.0
    /// The HUD panel forces a dark NSAppearance, so `@Environment(\.colorScheme)` cannot report
    /// the real system theme here. The value is cached and refreshed on theme changes instead:
    /// reading `AppleInterfaceStyle` inside `textColor` cost one UserDefaults lookup per
    /// waveform bar, roughly 1400 lookups per second while recording.
    @State private var systemIsDark = SystemAppearance.prefersDark()
    var effectiveColorScheme: ColorScheme {
        if appTheme == "dark" {
            return .dark
        } else if appTheme == "light" {
            return .light
        } else {
            return systemIsDark ? .dark : .light
        }
    }
    private var isInitializing: Bool {
        return controller.statusText.hasPrefix("Initializing")
    }
    private var isFinalState: Bool {
        let text = controller.statusText
        return text == "Cancelled" || text == "Done!" || text == "No text recognized." || text == "Error: Missing model" || text == "No microphone permission" || text == "Microphone error" || text == "Ready"
    }
    private var contentWidth: CGFloat { HUDMetrics.contentWidth }

    private var showsPause: Bool {
        showPauseButton && !isInitializing && !isFinalState
    }
    private var showsCancel: Bool {
        !isInitializing && !isFinalState
    }
    private var showsSelector: Bool {
        LLMManager.shared.isAvailable && !isInitializing && !isFinalState && controller.isRecording
    }
    /// Once the dictation lands, the card holds the answer. A capsule that only says "done"
    /// beside it adds nothing.
    private var showsOnlyTranscript: Bool {
        isFinalState && controller.isTranscriptPanelVisible
    }

    /// The waveform takes whatever the other items on the line leave, so both edges of the
    /// overlay line up with the text card above.
    private var targetWidth: CGFloat {
        let step = HUDMetrics.roundControlWidth + HUDMetrics.controlGap
        var taken: CGFloat = 0
        if showsPause { taken += step }
        if controller.canRetryTranscription { taken += step }
        if showsCancel { taken += step }
        if showsSelector { taken += HUDMetrics.assistantWidth + HUDMetrics.controlGap }
        return max(120, contentWidth - taken)
    }
    @State private var showPauseButton = false
    @State private var width: CGFloat = 180
    @State private var height: CGFloat = 40
    @State private var isProcessing = false
    @State private var hasAppeared = false
    @State private var showList = false
    @State private var hoveredModeID: UUID? = nil
    @State private var dragTracker = WindowDragTracker()
    @State private var recordingDuration: TimeInterval = 0
    @State private var dictProgress: CGFloat = 1.0
    @State private var copyProgress: CGFloat = 1.0
    @State private var isCopied: Bool = false
    @State private var isPasted: Bool = false
    @State private var isUndone: Bool = false
    @State private var hoveredButton: String? = nil

    /// The assistant picker.
    ///
    /// It used to take a full width row of its own, which read as a second toolbar. It is now
    /// a tag: in the row layout it shares the bottom line with the waveform, and in the stack
    /// layout it only takes the width of its own name.
    private func assistantSelector(width: CGFloat?, height: CGFloat) -> some View {
        Button(action: {
            if !dragTracker.isDragging { withAnimation { showList.toggle() } }
        }) {
            HStack(spacing: 6) {
                Text(t(controller.currentMode?.name ?? "Wybierz tryb"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: width == nil, vertical: false)
                    .id(controller.currentMode?.id)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    ))
                if width != nil {
                    Spacer(minLength: 4)
                }
                Image(systemName: showList ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.primary.opacity(0.6))
            }
            .padding(.horizontal, 12)
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .glass(cornerRadius: height / 2, colorScheme: effectiveColorScheme)
        }
        .buttonStyle(NoAnimButtonStyle())
        .focusable(false)
        .simultaneousGesture(dragGesture)
    }
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    private var audioWavesView: some View {
        // Each bar takes 5 points. The rest of the capsule holds the padding and the timer.
        let barCount = Int(max(15, min(64, (width - 90) / 5)))
        return HStack(spacing: 0) {
            Spacer()
                .frame(width: 14)
            AudioWavesView(
                levelStore: controller.audioLevelStore,
                barCount: barCount,
                isPaused: controller.isPaused,
                textColor: textColor
            )
            // A flexible gap keeps the bars on the left and the timer on the right. A fixed
            // gap let the whole group drift to the middle of a wide capsule.
            Spacer(minLength: 14)
            if controller.isRecording {
                Text(formatDuration(recordingDuration))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(controller.isPaused ? textColor.opacity(0.4) : textColor.opacity(0.85))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Spacer()
                .frame(width: 12)
        }
        .frame(width: width, height: 40)
        .clipShape(Capsule())
    }
    private var textColor: Color {
        effectiveColorScheme == .dark ? .white : .black
    }
    
    /// Turns the status into words a reader understands.
    ///
    /// `statusText` also drives app state, so the strings themselves cannot change. This maps
    /// them for the screen only. "Processing" and "Modifying" describe the machine. The user
    /// wants to know what is happening to their words.
    private func statusLabel(_ status: String) -> String {
        switch status {
        case "Processing": return "Reading your voice"
        case "Modifying": return "Improving the text"
        case "Done!": return "Pasted"
        case "No text recognized.": return "Heard nothing"
        case "Cancelled": return "Stopped"
        case "Transcription failed": return "Could not read it"
        case "Error: Missing model": return "No model installed"
        case "No microphone permission": return "No microphone access"
        case "Microphone error": return "Microphone problem"
        case "Initializing LLM Model...": return "Waking the assistant"
        default:
            if status.hasPrefix("Initializing") { return "Loading the model" }
            return status
        }
    }

    private var loaderView: some View {
        HStack(spacing: 8) {
            Text(t(statusLabel(controller.statusText)))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(textColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .id(controller.statusText)
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .move(edge: .bottom).combined(with: .opacity)
                ))
            Spacer()
            if !controller.canRetryTranscription {
                TimelineView(.animation(paused: !isHUDVisible)) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    let angle = time.truncatingRemainder(dividingBy: 1.0) * 360.0
                    Circle()
                        .trim(from: 0, to: 0.6)
                        .stroke(
                            textColor,
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                        )
                        .frame(width: 16, height: 16)
                        .rotationEffect(Angle(degrees: angle))
                }
                .transition(.asymmetric(insertion: .scale(scale: 0.5).combined(with: .opacity), removal: .scale(scale: 0.5).combined(with: .opacity)))
            }
        }
        .padding(.horizontal, 14)
        .frame(width: width, height: 40)
    }
    private var selectableModes: [VoiceMode] {
        VoiceMode.active(in: controller.availableModes)
    }
    private var dropdownListView: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 2) {
                ForEach(selectableModes) { mode in
                    Button(action: {
                        controller.selectMode(mode)
                        withAnimation { showList = false }
                    }) {
                        HStack {
                            Text(t(mode.name))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(textColor)
                            Spacer()
                            if controller.currentMode?.id == mode.id {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(textColor)
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(
                            controller.currentMode?.id == mode.id ? Color.primary.opacity(0.2) :
                            (hoveredModeID == mode.id ? Color.primary.opacity(0.1) : Color.clear)
                        )
                        .cornerRadius(8)
                        .contentShape(Rectangle())
                        .onHover { isHovered in
                            if isHovered {
                                hoveredModeID = mode.id
                            } else if hoveredModeID == mode.id {
                                hoveredModeID = nil
                            }
                        }
                    }
                                    .buttonStyle(NoAnimButtonStyle())
                    .focusable(false)
                }
                .padding(4)
            }
        }
        .frame(width: contentWidth)
        .frame(height: min(CGFloat(selectableModes.count) * 30 + 8, 200))
        .glass(cornerRadius: 12, opacity: 0.7, colorScheme: effectiveColorScheme)
        .transition(.asymmetric(
            insertion: .offset(y: 10).combined(with: .opacity),
            removal: .opacity
        ))
    }
    private var dictionaryNotificationView: some View {
        guard let notification = controller.activeDictionaryNotification else { return AnyView(EmptyView()) }
        return AnyView(
            ZStack(alignment: .bottomLeading) {
                Button(action: {}) { Color.white.opacity(0.001) }
                    .buttonStyle(NoAnimButtonStyle())
                HStack(spacing: 8) {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.primary.opacity(0.8))
                        .padding(.leading, 12)
                    Text("\"\(notification.wrong)\" ➔ \"\(notification.correct)\"")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer()
                    Button(action: {
                        if !dragTracker.isDragging {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                isUndone = true
                            }
                            controller.undoDictionaryEntry(delayHide: true)
                        }
                    }) {
                        ZStack {
                            if isUndone {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .transition(.scale.combined(with: .opacity))
                            } else {
                                Text(t("Undo"))
                                    .font(.system(size: 11, weight: .bold))
                                    .fixedSize()
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .foregroundColor(effectiveColorScheme == .dark ? .black : .white)
                        .padding(.horizontal, isUndone ? 0 : 10)
                        .frame(width: isUndone ? 24 : nil, height: 24)
                        .background(effectiveColorScheme == .dark ? Color.white : Color.black)
                        .clipShape(Capsule())
                    }
                                    .buttonStyle(NoAnimButtonStyle())
                    .focusable(false)
                    .padding(.trailing, 8)
                }
                .frame(width: 284, height: 40)
                
                Capsule()
                    .fill(effectiveColorScheme == .dark ? Color.white : Color.black)
                    .frame(width: 284 * dictProgress, height: 4)
                    .opacity(isUndone ? 0 : 1)
            }
            .frame(width: 284, height: 40)
            .contentShape(RoundedRectangle(cornerRadius: 20))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .glass(cornerRadius: 20, colorScheme: effectiveColorScheme)
            .onAppear {
                isUndone = false
                dictProgress = 1.0
                withAnimation(.linear(duration: 5.0)) {
                    dictProgress = 0.0
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
            .simultaneousGesture(dragGesture)
        )
    }
    private var copyNotificationView: some View {
        guard let _ = controller.activeCopyNotification else { return AnyView(EmptyView()) }
        return AnyView(
            ZStack(alignment: .bottomLeading) {
                Button(action: {}) { Color.white.opacity(0.001) }
                    .buttonStyle(NoAnimButtonStyle())
                HStack(spacing: 8) {
                    Text(t("Field not detected"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.leading, 14)
                    Spacer()
                    Button(action: {
                        if !dragTracker.isDragging {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                isCopied = true
                            }
                            controller.copyNotificationTextToClipboard(delayHide: true)
                        }
                    }) {
                        HStack(spacing: hoveredButton == "copy" && !isCopied ? 4 : 0) {
                            if isCopied {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .transition(.scale.combined(with: .opacity))
                            } else {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 11, weight: .semibold))
                                if hoveredButton == "copy" {
                                    Text(t("Copy"))
                                        .font(.system(size: 11, weight: .bold))
                                        .fixedSize()
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                        }
                        .foregroundColor(effectiveColorScheme == .dark ? .black : .white)
                        .padding(.horizontal, (hoveredButton == "copy" && !isCopied) ? 10 : 0)
                        .frame(width: (hoveredButton == "copy" && !isCopied) ? nil : 24, height: 24)
                        .background(effectiveColorScheme == .dark ? Color.white : Color.black)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(NoAnimButtonStyle())
                    .focusable(false)
                    .onHover { isHovered in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            if isHovered { hoveredButton = "copy" }
                            else if hoveredButton == "copy" { hoveredButton = nil }
                        }
                    }
                    
                    Button(action: {
                        if !dragTracker.isDragging {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                isPasted = true
                            }
                            controller.pasteCopyNotificationText(delayHide: true)
                        }
                    }) {
                        HStack(spacing: hoveredButton == "paste" && !isPasted ? 4 : 0) {
                            if isPasted {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .transition(.scale.combined(with: .opacity))
                            } else {
                                Image(systemName: "doc.on.clipboard")
                                    .font(.system(size: 11, weight: .semibold))
                                if hoveredButton == "paste" {
                                    Text(t("Paste"))
                                        .font(.system(size: 11, weight: .bold))
                                        .fixedSize()
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                        }
                        .foregroundColor(effectiveColorScheme == .dark ? .black : .white)
                        .padding(.horizontal, (hoveredButton == "paste" && !isPasted) ? 10 : 0)
                        .frame(width: (hoveredButton == "paste" && !isPasted) ? nil : 24, height: 24)
                        .background(effectiveColorScheme == .dark ? Color.white : Color.black)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(NoAnimButtonStyle())
                    .focusable(false)
                    .onHover { isHovered in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            if isHovered { hoveredButton = "paste" }
                            else if hoveredButton == "paste" { hoveredButton = nil }
                        }
                    }
                    
                    Button(action: {
                        if !dragTracker.isDragging {
                            controller.hideCopyNotification()
                        }
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(effectiveColorScheme == .dark ? .black : .white)
                            .frame(width: 24, height: 24)
                            .background(effectiveColorScheme == .dark ? Color.white : Color.black)
                            .clipShape(Circle())
                    }
                    .buttonStyle(NoAnimButtonStyle())
                    .focusable(false)
                    .padding(.trailing, 8)
                }
                .frame(width: 284, height: 40)
                
                Capsule()
                    .fill(effectiveColorScheme == .dark ? Color.white : Color.black)
                    .frame(width: 284 * copyProgress, height: 4)
                    .opacity(isCopied || isPasted ? 0 : 1)
            }
            .frame(width: 284, height: 40)
            .contentShape(RoundedRectangle(cornerRadius: 20))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .safeGlassEffect(cornerRadius: 20, isInteractive: true)
            .onAppear {
                isCopied = false
                isPasted = false
                hoveredButton = nil
                copyProgress = 1.0
                withAnimation(.linear(duration: overlayDuration > 0 ? overlayDuration : 15.0)) {
                    copyProgress = 0.0
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
            .simultaneousGesture(dragGesture)
        )
    }
    private var transcriptPanel: some View {
        TranscriptPanelView(store: controller.transcriptStore, colorScheme: effectiveColorScheme, width: contentWidth)
            .simultaneousGesture(dragGesture)
    }

    @ViewBuilder
    private func assistantTag(width: CGFloat?, height: CGFloat) -> some View {
        if showsSelector {
            assistantSelector(width: width, height: height)
                .transition(.asymmetric(insertion: .offset(y: 20).combined(with: .opacity), removal: .offset(y: 20).combined(with: .opacity)))
        }
    }

    private var mainCapsule: some View {
        Button(action: {
        }) {
            ZStack {
                if !isProcessing && !controller.statusText.hasPrefix("Initializing") {
                    audioWavesView
                        .transition(.asymmetric(insertion: .scale(scale: 0.8).combined(with: .opacity), removal: .scale(scale: 0.5).combined(with: .opacity)))
                } else {
                    loaderView
                        .transition(.asymmetric(insertion: .scale(scale: 0.8).combined(with: .opacity), removal: .scale(scale: 0.5).combined(with: .opacity)))
                }
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.6, blendDuration: 0.3), value: isProcessing)
            .animation(.spring(response: 0.5, dampingFraction: 0.6, blendDuration: 0.3), value: controller.statusText)
            .frame(width: width, height: height)
            .contentShape(Capsule())
            .glass(cornerRadius: 20, colorScheme: effectiveColorScheme)
        }
        .buttonStyle(NoAnimButtonStyle())
        .focusable(false)
        .simultaneousGesture(dragGesture)
    }

    private func roundButton(_ systemName: String, size: CGFloat, weight: Font.Weight, action: @escaping () -> Void) -> some View {
        Button(action: {
            if !dragTracker.isDragging { action() }
        }) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: weight))
                .foregroundColor(textColor)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
                .glass(cornerRadius: 20, colorScheme: effectiveColorScheme)
        }
        .buttonStyle(NoAnimButtonStyle())
        .focusable(false)
        .simultaneousGesture(dragGesture)
        .transition(.asymmetric(insertion: .offset(x: -30).combined(with: .scale(scale: 0.1)).combined(with: .opacity), removal: .offset(x: -30).combined(with: .scale(scale: 0.1)).combined(with: .opacity)))
    }

    @ViewBuilder
    private var pauseButton: some View {
        if showPauseButton && !isInitializing && !isFinalState {
            roundButton(controller.isPaused ? "play.fill" : "pause.fill", size: 14, weight: .medium) {
                controller.togglePause()
            }
        }
    }

    @ViewBuilder
    private var retryButton: some View {
        if controller.canRetryTranscription {
            roundButton("arrow.clockwise", size: 15, weight: .bold) {
                controller.retryTranscription()
            }
        }
    }

    @ViewBuilder
    private var cancelButton: some View {
        if !isInitializing && !isFinalState {
            roundButton("xmark", size: 15, weight: .medium) {
                controller.cancelRecording()
            }
        }
    }

    /// The text card, and one control line under it.
    ///
    /// Order on the line: pause first, because play and pause belong on the left. The waveform
    /// takes the room that is left. The assistant picker sits beside it. Cancel goes last, as
    /// far from pause as the line allows, so a miss on one is never the other.
    private var overlayLayout: some View {
        VStack(spacing: 8) {
            transcriptPanel
            if !showsOnlyTranscript {
                HStack(spacing: HUDMetrics.controlGap) {
                    pauseButton
                    retryButton
                    mainCapsule
                    assistantTag(width: HUDMetrics.assistantWidth, height: HUDMetrics.controlHeight)
                    cancelButton
                }
            }
        }
        .frame(width: contentWidth)
    }

    var body: some View {
        VStack(spacing: 8) {
            if showList {
                dropdownListView
            }
            ZStack(alignment: .bottom) {
                if let _ = controller.activeDictionaryNotification {
                    dictionaryNotificationView
                        .zIndex(2)
                } else if let _ = controller.activeCopyNotification {
                    copyNotificationView
                        .zIndex(2)
                } else {
                    overlayLayout
                        .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .zIndex(1)
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: controller.activeDictionaryNotification != nil)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: controller.activeCopyNotification != nil)
        }
        .frame(width: HUDMetrics.windowWidth, height: 600, alignment: .bottom)
        // A finished dictation normally fades the HUD out at once. The transcript panel keeps
        // it on screen until the store empties itself, so the user can read the edit.
        .opacity((isFinalState || !hasAppeared) && controller.activeDictionaryNotification == nil && controller.activeCopyNotification == nil && !controller.isTranscriptPanelVisible ? 0.0 : 1.0)
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: isFinalState)
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: hasAppeared)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: controller.isTranscriptPanelVisible)
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: controller.activeDictionaryNotification != nil)
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: controller.activeCopyNotification != nil)
        .colorScheme(effectiveColorScheme)
        .onAppear {
            controller.reloadModes()
            showPauseButton = controller.isRecording
            width = targetWidth
            isHUDVisible = true
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                hasAppeared = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("HUDWindowDidShow"))) { _ in
            isHUDVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("HUDWindowDidHide"))) { _ in
            isHUDVisible = false
        }
        .onChange(of: controller.isRecording) {
            if !controller.isRecording {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.6, blendDuration: 0.3)) {
                    showPauseButton = false
                    width = targetWidth
                    height = 40
                    isProcessing = true
                }
            } else {
                recordingDuration = 0
                withAnimation(.spring(response: 0.5, dampingFraction: 0.6, blendDuration: 0.3)) {
                    showPauseButton = true
                    width = targetWidth
                    height = 40
                    isProcessing = controller.statusText != "Listening..." && controller.statusText != "Paused"
                }
            }
        }
        .onChange(of: controller.canRetryTranscription) {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6, blendDuration: 0.3)) {
                width = targetWidth
                isProcessing = controller.statusText != "Listening..." && controller.statusText != "Paused"
            }
        }
        .onChange(of: controller.statusText) {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6, blendDuration: 0.3)) {
                width = targetWidth
                isProcessing = controller.statusText != "Listening..." && controller.statusText != "Paused"
            }
            if isFinalState {
                showList = false
            } else {
                showList = false
            }
        }
        .onChange(of: controller.activeDictionaryNotification) {
            if controller.activeDictionaryNotification == nil && controller.activeCopyNotification == nil && !controller.isRecording {
                showList = false
            }
        }
        .onChange(of: controller.activeCopyNotification) {
            if controller.activeCopyNotification == nil {
                isCopied = false
            }
            if controller.activeDictionaryNotification == nil && controller.activeCopyNotification == nil && !controller.isRecording {
                showList = false
            }
        }
        // A `Timer.publish` here kept waking the app once per second forever, because the HUD
        // panel is only ordered out and never releases its hosting view. This ticks only while
        // a recording is actually running.
        .task(id: controller.isRecording) {
            guard controller.isRecording else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                if controller.isRecording && !controller.isPaused && !controller.statusText.hasPrefix("Initializing") {
                    recordingDuration += 1
                }
            }
        }
        .onChange(of: hudPositionMode) { _, newMode in
            WindowManager.shared.updateHUDPosition(for: newMode)
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: SystemAppearance.themeChangedNotification)) { _ in
            systemIsDark = SystemAppearance.prefersDark()
        }
    }
    var dragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                guard hudPositionMode == .free else { return }
                let currentMouse = NSEvent.mouseLocation
                guard let window = WindowManager.shared.hudWindow else { return }
                if dragTracker.startMouseLocation == nil {
                    dragTracker.startMouseLocation = currentMouse
                    dragTracker.startWindowOrigin = window.frame.origin
                    dragTracker.isDragging = true
                }
                guard let startMouse = dragTracker.startMouseLocation,
                      let startOrigin = dragTracker.startWindowOrigin else { return }
                let deltaX = currentMouse.x - startMouse.x
                let deltaY = currentMouse.y - startMouse.y
                var newX = startOrigin.x + deltaX
                var newY = startOrigin.y + deltaY
                if let screen = window.screen ?? NSScreen.main {
                    let screenFrame = screen.visibleFrame
                    let leftMargin: CGFloat = 33
                    let rightMargin: CGFloat = HUDMetrics.windowWidth - leftMargin
                    let minXBound = screenFrame.minX - leftMargin
                    let maxXBound = screenFrame.maxX - rightMargin
                    // The panel wraps to at most four lines, so this reserves its tallest size.
                    let panelHeight: CGFloat = controller.isTranscriptPanelVisible ? 84 : 0
                    let visibleHeight = (showList ? CGFloat(296) : CGFloat(88)) + panelHeight
                    let minYBound = screenFrame.minY - 8
                    let maxYBound = screenFrame.maxY - visibleHeight - 8
                    newX = max(minXBound, min(newX, maxXBound))
                    newY = max(minYBound, min(newY, maxYBound))
                }
                window.setFrameOrigin(NSPoint(x: newX, y: newY))
            }
            .onEnded { _ in
                if let window = WindowManager.shared.hudWindow {
                    let origin = window.frame.origin
                    UserDefaults.standard.set(origin.x, forKey: "hudWindowX")
                    UserDefaults.standard.set(origin.y, forKey: "hudWindowY")
                }
                dragTracker.startMouseLocation = nil
                dragTracker.startWindowOrigin = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    dragTracker.isDragging = false
                }
            }
    }
}



struct GlassModifier: ViewModifier {
    var cornerRadius: CGFloat
    var opacity: Double = 1.0
    var colorScheme: ColorScheme
    
    func body(content: Content) -> some View {
        content
            .safeGlassEffect(cornerRadius: cornerRadius, isInteractive: true)
    }
}

extension View {
    func glass(cornerRadius: CGFloat = 20, opacity: Double = 1.0, colorScheme: ColorScheme) -> some View {
        self.modifier(GlassModifier(cornerRadius: cornerRadius, opacity: opacity, colorScheme: colorScheme))
    }
}

struct NoAnimButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

class WindowDragTracker {
    var startMouseLocation: NSPoint? = nil
    var startWindowOrigin: NSPoint? = nil
    var isDragging: Bool = false
}
