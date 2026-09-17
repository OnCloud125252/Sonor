import SwiftUI
import AppKit
import Combine
import AVFoundation
import CoreAudio
import os

/// Holds the 20 Hz waveform data on its own so that only the waveform view redraws.
/// Publishing this from `AppController` rebuilt the whole HUD tree 20 times per second.
@MainActor
final class AudioLevelStore: ObservableObject {
    static let barCapacity = 40

    /// Seconds between two bars.
    static let tickSeconds: Double = 0.05
    /// How long a bar takes to fall from full height to the floor once the sound stops.
    ///
    /// A bar that follows the microphone straight down drops to the floor between two
    /// syllables, and even inside one word at every consonant. The waveform then reads as a
    /// row of separate spikes instead of the shape of a voice.
    static let releaseSeconds: Double = 0.28
    static let releasePerTick = Float(tickSeconds / releaseSeconds)

    /// The next bar value. It rises at once and falls at a fixed rate.
    ///
    /// A voice starts a syllable faster than it ends one, so the rise has to be immediate and
    /// the fall has to be gentle. Audio meters have worked this way for decades.
    static func nextValue(previous: Float, target: Float) -> Float {
        max(target, previous - releasePerTick)
    }
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: barCapacity)

    func append(_ level: Float) {
        levels.append(level)
        if levels.count > Self.barCapacity {
            levels.removeFirst(levels.count - Self.barCapacity)
        }
    }

    func reset() {
        levels = Array(repeating: 0, count: Self.barCapacity)
    }
}

@MainActor
class AppController: NSObject, ObservableObject {
    
    @Published var isRecording = false {
        didSet {
            updateDictationActive()
        }
    }
    @Published var activeDictionaryNotification: DictionaryNotification? = nil
    @Published var activeCopyNotification: String? = nil
    @Published var isPopoverOpen = false
    @Published var lastTranscription: String? = nil
    private var wasPopoverOpenBeforeRecording = false
    
    /// Displays the current status of the app in the HUD (e.g. "Listening...", "Processing")
    @Published var statusText = "Ready"
    @Published var isTranscribing = false
    @Published var isHovering = false
    @Published var failedAudioSamples: [Float]? = nil
    @Published var failedSelectedMode: VoiceMode? = nil
    var failedHistoryMessageID: UUID? = nil
    @Published var canRetryTranscription: Bool = false
    /// True while the assistant rewrites the transcript and the user can still stop it.
    @Published private(set) var isRefining = false {
        didSet {
            updateDictationActive()
        }
    }

    /// Shortcuts bound to a bare character key are only claimed while a dictation is in
    /// flight. The rewrite counts, because the user can stop it with its own shortcut.
    private func updateDictationActive() {
        HotkeyManager.shared.setDictationActive(isRecording || isRefining)
    }
    
    private var currentRecordingSessionID: UUID? = nil
    private var lastRecordingStopTime: Date = Date.distantPast
    private var lastRecordingStartTime: Date = Date.distantPast
    var isCurrentlyProcessing: Bool {
        let nonProcessingStatuses: Set<String> = ["Ready", "Cancelled", "No microphone permission", "Microphone error", "No text recognized.", "Error: Missing model", "Done!", "Transcription failed", "Assistant failed"]
        return !isRecording && !nonProcessingStatuses.contains(statusText) && !statusText.hasPrefix("Mode:")
    }
    let audioLevelStore = AudioLevelStore()
    let transcriptStore = TranscriptStore()
    /// Mirrors `transcriptStore.hasContent`. The HUD reads this instead of the store, so that
    /// live text redraws the panel alone.
    @Published private(set) var isTranscriptPanelVisible = false
    @Published var availableModes: [VoiceMode] = []
    @Published var currentMode: VoiceMode? {
        didSet {
            guard isRecording, let newMode = currentMode, let oldMode = oldValue else { return }
            let oldBehavior = oldMode.audioBehavior ?? .keep
            let newBehavior = newMode.audioBehavior ?? .keep
            if oldBehavior != newBehavior {
                MediaControlService.shared.updateMultimedia(from: oldBehavior, to: newBehavior)
            }
        }
    }
    @Published var activeHotkeyMode: HotkeyMode = .click
    @Published var isPaused = false {
        didSet {
            if isPaused {
                DispatchQueue.global(qos: .userInitiated).async {
                    self.audioManager.pauseRecording()
                }
            } else {
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try self.audioManager.resumeRecording()
                    } catch {
                        print("Failed to resume recording: \(error)")
                    }
                }
            }
        }
    }
    
    private let audioManager = AudioManager.shared
    static let dictationLog = Logger(subsystem: "dev.Sonor", category: "dictation")
    
    
    
    // Task management for cancelling active recordings or processing
    private var currentTask: Task<Void, Never>?
    private var startRecordingTask: Task<Void, Never>?
    
    override init() {
        super.init()
        transcriptStore.onVisibilityChange = { [weak self] isVisible in
            self?.isTranscriptPanelVisible = isVisible
        }
        let modes = VoiceMode.loadAndMigrateModes()
        self.availableModes = modes
        // A launch always starts on the assistant chosen as the default.
        self.currentMode = VoiceMode.resolveDefault(in: modes)
        if let current = self.currentMode {
            TranscriptionManager.shared.applyModelOverride(current.modelOverride)
        }

        setupHotkey()
        NotificationCenter.default.addObserver(forName: Notification.Name("VoiceModesUpdated"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reloadModes()
            }
        }
        NotificationCenter.default.addObserver(forName: Notification.Name("ReleaseWhisperContext"), object: nil, queue: .main) { _ in
            Task { @MainActor in
                TranscriptionManager.shared.resetEngine()
            }
        }
        NotificationCenter.default.addObserver(forName: Notification.Name("PermissionsRevoked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if self.isRecording || self.isCurrentlyProcessing {
                    self.cancelRecording()
                }
            }
        }
        NotificationCenter.default.addObserver(forName: NSNotification.Name("AppWillTerminate"), object: nil, queue: .main) { _ in
        Task { _ = await self.audioManager.stopRecordingAsync() }
        }
        NotificationCenter.default.addObserver(forName: Notification.Name("RetryHistoryTranscription"), object: nil, queue: .main) { [weak self] notification in
            guard let self = self, let id = notification.object as? UUID else { return }
            Task { @MainActor in
                self.retryHistoryTranscription(id: id)
            }
        }
    }
    private var hotkeyDownTime: Date = Date()
    
    private func setupHotkey() {
        HotkeyManager.shared.onHotkeyDown = { [weak self] eventTime in
            self?.hotkeyDownTime = eventTime
            self?.toggleRecording(eventTime: eventTime)
        }
        
        HotkeyManager.shared.onHotkeyUp = { [weak self] eventTime in
            guard let self = self else { return }
            if self.isRecording {
                if eventTime.timeIntervalSince(self.lastRecordingStartTime) < 0.2 {
                    return
                }
                if self.activeHotkeyMode == .hold {
                    self.stopRecordingAndTranscribe()
                } else if self.activeHotkeyMode == .automatic {
                    let duration = eventTime.timeIntervalSince(self.hotkeyDownTime)
                    if duration > 0.4 {
                        self.stopRecordingAndTranscribe()
                    }
                }
            }
        }
        HotkeyManager.shared.onCancelKeyDown = { [weak self] in
            self?.cancelRecording()
        }
        HotkeyManager.shared.onPauseKeyDown = { [weak self] in
            self?.togglePause()
        }
        HotkeyManager.shared.onAssistantKeyDown = { [weak self] in
            self?.selectNextMode()
        }
        HotkeyManager.shared.onSkipRefineKeyDown = { [weak self] in
            self?.skipRefinement()
        }
        HotkeyManager.shared.onPasteKeyDown = { [weak self] in
            guard let self = self, let text = self.lastTranscription, !text.isEmpty else { return }
            
            DispatchQueue.global(qos: .userInitiated).async {
                DispatchQueue.main.async {
                    if let frontApp = NSWorkspace.shared.frontmostApplication {
                        let pid = frontApp.processIdentifier
                        DispatchQueue.global(qos: .userInitiated).async {
                            PasteManager.shared.typeTextDirectly(text: text, targetPID: pid, forceFocusElement: nil)
                        }
                    }
                }
            }
        }

        HotkeyManager.shared.startListening()
    }
    func selectNextMode() {
        guard isRecording else { return }
        
        let terminalStates = ["Cancelled", "Done!", "No text recognized.", "Error: Missing model", "No microphone permission", "Microphone error", "Assistant failed"]
        if isCurrentlyProcessing || terminalStates.contains(statusText) {
            return
        }
        // Each assistant may point at a different model, so availability is per assistant.
        let functionalModes = VoiceMode.active(in: availableModes).filter { mode in
            mode.prompt.isEmpty || LLMManager.shared.isAvailable(for: mode)
        }
        guard !functionalModes.isEmpty else { return }
        guard functionalModes.count > 1 else {
            return
        }
        let currentIndex = functionalModes.firstIndex(where: { $0.id == currentMode?.id }) ?? -1
        let nextIndex = (currentIndex + 1) % functionalModes.count
        let nextMode = functionalModes[nextIndex]
        changeMode(nextMode)
    }
    func changeMode(_ nextMode: VoiceMode) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            self.selectMode(nextMode)
        }
        if !self.isRecording {
            statusText = "Mode: \(nextMode.name)"
        }
        if WindowManager.shared.hudWindow?.isVisible == false {
            WindowManager.shared.showHUD(controller: self)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if self.isRecording {
                if self.statusText.hasPrefix("Mode:") {
                    self.statusText = "Listening..."
                }
            } else {
                if self.statusText.hasPrefix("Mode:") {
                    self.statusText = "Ready"
                    WindowManager.shared.hideHUD()
                }
            }
        }
    }
    func reloadModes() {
        let modes = VoiceMode.loadAndMigrateModes()
        self.availableModes = modes
        let activeModeID = UserDefaults.standard.string(forKey: "activeModeID") ?? ""
        // Keep the running selection, unless it was disabled or deleted in the dashboard.
        let stillUsable = modes.first(where: { $0.id.uuidString == activeModeID && $0.isActive })
        self.currentMode = stillUsable ?? VoiceMode.resolveDefault(in: modes)
        if let current = self.currentMode {
            TranscriptionManager.shared.applyModelOverride(current.modelOverride)
        }
    }

    /// Toggles the recording state. 
    /// Handles accessibility permissions, microphone permissions, and model checking before proceeding.
    func toggleRecording(eventTime: Date = Date()) {
        if isCurrentlyProcessing {
            return
        }
        if isRecording {
            if eventTime.timeIntervalSince(lastRecordingStartTime) < 0.2 {
                return
            }
            stopRecordingAndTranscribe()
        } else {
            if eventTime.timeIntervalSince(lastRecordingStopTime) < 0.5 {
                return
            }
            lastRecordingStartTime = eventTime
            
            let isTrusted = AXIsProcessTrusted()
            let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            
            if !isTrusted || authStatus == .denied || authStatus == .restricted {
                if !isTrusted {
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                    let _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
                }
                WindowManager.shared.openPermissionsWindow()
                return
            } else if authStatus == .notDetermined {
                AVCaptureDevice.requestAccess(for: AVMediaType.audio) { granted in
                    Task { @MainActor in
                        if !granted {
                            WindowManager.shared.openPermissionsWindow()
                        } else {
                            self.toggleRecording()
                        }
                    }
                }
                return
            }

            let modeString = UserDefaults.standard.string(forKey: "hotkeyMode") ?? "Click"
            if modeString == "Hold" { self.activeHotkeyMode = .hold }
            else if modeString == "Automatic" { self.activeHotkeyMode = .automatic }
            else { self.activeHotkeyMode = .click }
            let selectedModelId = ModelManager.shared.selectedWhisperModelId
            guard case .downloaded = ModelManager.shared.whisperStates[selectedModelId] else {
                self.isRecording = false
                WindowManager.shared.openSettings()
                DispatchQueue.main.async {
                    ModelManager.shared.showModelsRequiredModal = true
                }
                return
            }
            let selectedMode = currentMode ?? VoiceMode.resolveDefault(in: availableModes) ?? VoiceMode.defaults[0]
            if self.currentMode?.id != selectedMode.id {
                self.selectMode(selectedMode)
            }
            self.activeCopyNotification = nil
            self.activeDictionaryNotification = nil
            self.canRetryTranscription = false
            self.failedAudioSamples = nil
            self.failedSelectedMode = nil
            
            self.isRecording = true
            let sessionID = UUID()
            self.currentRecordingSessionID = sessionID
            
            wasPopoverOpenBeforeRecording = isPopoverOpen
            
            self.statusText = "Listening..."
            self.transcriptStore.startListening()
            WindowManager.shared.showHUD(controller: self)
            
            self.startRecordingProcess(selectedMode: selectedMode, sessionID: sessionID)
            
            // Load transcription engine in background — only needed when
            // transcription starts (after recording stops), not for capturing audio
            Task {
                do {
                    try await TranscriptionManager.shared.ensureEngineReady()
                } catch {
                    await MainActor.run {
                        print("Engine Error: \(error)")
                    }
                }
            }
        }
    }
    private func startRecordingProcess(selectedMode: VoiceMode, sessionID: UUID) {
        startRecordingTask?.cancel()
        startRecordingTask = Task {
            guard self.isRecording && self.currentRecordingSessionID == sessionID else { return }
            let behavior = selectedMode.audioBehavior ?? .keep
            
            if behavior != .keep {
                MediaControlService.shared.pauseMultimedia(behavior: behavior)
            }
            
            Task {
                await SoundPlayer.shared.playSound(named: "Start")
            }
            
            self.startRecording(sessionID: sessionID)
        }
    }
    private func startRecording(sessionID: UUID) {
        self.isPaused = false
        withAnimation {
            canRetryTranscription = false
            failedAudioSamples = nil
            failedSelectedMode = nil
        }
        performStartRecording(sessionID: sessionID)
    }
    private func performStartRecording(sessionID: UUID) {
        self.isPaused = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                try self.audioManager.startRecording()
                DispatchQueue.main.async {
                    guard self.currentRecordingSessionID == sessionID else {
                        Task { _ = await self.audioManager.stopRecordingAsync() }
                        return
                    }
                    self.isRecording = true
                    NotificationCenter.default.post(name: Notification.Name("HidePermissionViews"), object: nil)
                    withAnimation(.easeInOut(duration: 0.3)) {
                        self.statusText = "Listening..."
                    }
                    self.startLivePreviewIfEnabled()
                    Task { @MainActor in
                        var barValue: Float = 0
                        while self.isRecording {
                            if !self.isPaused {
                                // The store holds bar heights, not raw readings. The mapping
                                // belongs here, where the peak and the live threshold are, and
                                // not in the view that draws 20 times a second.
                                let level = self.audioManager.peakLevelSinceLastRead
                                let target = level.isFinite ? Float(VoiceActivity.waveformValue(forLevel: level)) : 0
                                barValue = AudioLevelStore.nextValue(previous: barValue, target: target)
                                self.audioLevelStore.append(barValue)
                            }
                            try? await Task.sleep(nanoseconds: UInt64(AudioLevelStore.tickSeconds * 1_000_000_000))
                        }
                        self.audioLevelStore.reset()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    MediaControlService.shared.resumeMultimedia()
                    self.statusText = "Microphone error"
                    self.isRecording = false
                    self.transcriptStore.clear()
                    self.hideHUDAfterDelay()
                }
            }
        }
    }

    /// Starts the live preview, when the user asked for it in the settings.
    ///
    /// The preview runs the transcription model again and again, so it costs battery. It stays
    /// off until the user switches it on.
    private func startLivePreviewIfEnabled() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "showTranscriptPanel"),
              defaults.bool(forKey: "showLiveTranscript"),
              !TranscriptionManager.selectedPreviewModelId.isEmpty else { return }
        TranscriptionManager.shared.warmPreviewEngine()
        LivePreviewService.shared.start { [weak self] text in
            self?.transcriptStore.updateLive(text)
        }
    }


    /// Stops the assistant rewrite and types the plain transcript instead.
    func skipRefinement() {
        guard isRefining else { return }
        AssistantWorkflowService.shared.skipRefinement()
    }

    func togglePause() {
        guard isRecording else { 
            return 
        }
        self.isPaused.toggle()
        if self.isPaused {
            self.statusText = "Paused"
        } else {
            self.statusText = "Listening..."
        }
    }

    func selectMode(_ mode: VoiceMode) {
        self.currentMode = mode
        UserDefaults.standard.set(mode.id.uuidString, forKey: "activeModeID")
        
        TranscriptionManager.shared.applyModelOverride(mode.modelOverride)
        Task {
            try? await TranscriptionManager.shared.ensureEngineReady()
            // A mode switch outside a recording warms the model with nothing scheduled to
            // release it. The countdown is restarted so the idle rules still apply.
            if !self.isRecording && !self.isCurrentlyProcessing {
                TranscriptionManager.shared.resetUnloadTimer()
            }
        }
    }
    func cancelRecording() {
        if statusText.hasPrefix("Initializing") { return }
        guard isRecording || isCurrentlyProcessing else { return }
        isRecording = false
        self.isPaused = false
        self.isRefining = false
        self.currentRecordingSessionID = nil
        self.lastRecordingStopTime = Date()
        statusText = "Cancelled"
        LivePreviewService.shared.stop()
        self.transcriptStore.clear()
        let taskToCancel = currentTask
        currentTask = nil
        taskToCancel?.cancel()
        
        startRecordingTask?.cancel()
        startRecordingTask = nil
        
        Task {
            _ = await self.audioManager.stopRecordingAsync()
        }
        
        MediaControlService.shared.resumeMultimedia()
        self.audioLevelStore.reset()
        let modeStr = UserDefaults.standard.string(forKey: "hudPositionMode") ?? "free"
        let isNotchMode = (modeStr == "notch")
        
        if isNotchMode {
            WindowManager.shared.hideHUD()
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + (isNotchMode ? 0.0 : 1.0)) {
            if !self.isRecording && self.statusText == "Cancelled" {
                self.statusText = "Ready"
                if !isNotchMode {
                    WindowManager.shared.hideHUD()
                }
            }
        }
    }

    private func hideHUDAfterDelay() {
        // The transcript panel holds the HUD open a little longer, so the user can read the
        // assistant edit before the overlay goes away.
        let delay = transcriptStore.hasContent ? max(1.5, transcriptStore.activeLingerSeconds + 0.5) : 1.5
        Task { @MainActor in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if !self.isRecording && self.activeDictionaryNotification == nil && self.activeCopyNotification == nil {
                    self.statusText = "Ready"
                    self.transcriptStore.clear()
                    WindowManager.shared.hideHUD()
                }
            }
        }
    }
    func stopRecordingAndTranscribe() {
        guard isRecording else {
            return
        }
        self.isPaused = false
        isRecording = false
        self.currentRecordingSessionID = nil
        self.lastRecordingStopTime = Date()
        statusText = "Processing"
        LivePreviewService.shared.stop()
        // A pass that lands after this point must not open the panel.
        transcriptStore.stopListening()
        if !wasPopoverOpenBeforeRecording {
            isPopoverOpen = false
        }
        
        startRecordingTask?.cancel()
        startRecordingTask = nil

        currentTask = Task {
            let samples = await audioManager.stopRecordingAsync()
            await MainActor.run {
                MediaControlService.shared.resumeMultimedia()
            }
            guard samples.count >= 2000 else {
                await MainActor.run { 
                    self.statusText = "Cancelled" 
                }
                self.hideHUDAfterDelay()
                return
            }
            
            // Silence check removed to prevent falsely cancelling quiet microphones
            
            let selectedMode = await MainActor.run { return self.currentMode ?? VoiceMode.defaults.first! }

            await self.processAudio(samples: samples, selectedMode: selectedMode)
        }
    }
    
    func processAudio(samples: [Float], selectedMode: VoiceMode, historyMessageID: UUID? = nil, isInlineRetry: Bool = false) async {
        let dictionary = UserDefaults.standard.dictionary(forKey: "dictionaryEntries") as? [String: String] ?? [:]
        let snippets = UserDefaults.standard.dictionary(forKey: "snippetsEntries") as? [String: String] ?? [:]
        // A dictionary entry maps a wrong spelling to the right one, so the model should expect
        // the right one. A snippet trigger is the word the user actually says, so it is the key.
        let vocabularyHints = Array(dictionary.values) + Array(snippets.keys)
        let language = TranscriptionLanguage.resolved(modeCode: selectedMode.language)

        do {
            let transcribedText = try await TranscriptionManager.shared.transcribe(audioSamples: samples, language: language, vocabularyHints: vocabularyHints)
            // Written on every dictation so a short result can be traced back to its cause:
            // a short recording means the capture lost audio, a short text means the model did.
            AppController.dictationLog.notice("""
                dictation finished: \(Double(samples.count) / 16000, format: .fixed(precision: 1))s audio, \
                \(transcribedText.count) characters
                """)
            
            if Task.isCancelled {
                if !isInlineRetry {
                    self.hideHUDAfterDelay()
                }
                return
            }
            let rawText = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawText.isEmpty else {
                if !isInlineRetry {
                    await MainActor.run { 
                        self.statusText = "No text recognized."
                        self.transcriptStore.clear()
                    }
                    await SoundPlayer.shared.playSound(named: "Error")
                    self.hideHUDAfterDelay()
                }
                return
            }
            let duration = Double(samples.count) / 16000.0
            UsageTrackingService.shared.recordUsage(duration: duration, text: rawText)
            let correctedText = TextProcessingService.shared.applyCorrections(to: rawText)
            await MainActor.run {
                self.lastTranscription = correctedText
                if !isInlineRetry && UserDefaults.standard.bool(forKey: "showTranscriptPanel") {
                    self.transcriptStore.showTranscript(correctedText)
                }
            }
            await AssistantWorkflowService.shared.execute(
                correctedText: correctedText,
                selectedMode: selectedMode,
                audioSamples: samples,
                historyMessageID: historyMessageID,
                isBackgroundRetry: isInlineRetry,
                onStatusChange: { status in
                    if !isInlineRetry {
                        self.statusText = status
                    }
                },
                onAutoLearnTrigger: { targetPID, text in
                    if !isInlineRetry {
                        self.startAutoLearnTracking(targetPID: targetPID, originalText: text)
                    }
                },
                onCopyNotificationTrigger: { textToCopy in
                    if !isInlineRetry {
                        self.showCopyNotification(text: textToCopy)
                    }
                },
                onAssistantText: { text, isFinal in
                    if !isInlineRetry {
                        self.transcriptStore.updateAssistant(text, isFinal: isFinal)
                    }
                },
                onRefiningChange: { isRefining in
                    if !isInlineRetry {
                        self.isRefining = isRefining
                    }
                }
            )
            if !isInlineRetry {
                self.transcriptStore.markFinished()
                self.hideHUDAfterDelay()
            }
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            if isInlineRetry {
                if let historyMessageID = historyMessageID {
                    await MainActor.run {
                        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown App"
                        let whisperModel = TranscriptionManager.shared.activeModelName
                        let llmModelLabel = LLMManager.shared.activeModelLabel(for: selectedMode)
                        let shouldRunLLM = !selectedMode.prompt.isEmpty
                        MessageMemoryManager.shared.updateMessage(id: historyMessageID, newText: t("Transcription failed"), isError: true, appName: appName, transcriptionModel: whisperModel, llmModel: shouldRunLLM ? llmModelLabel : nil, modeName: selectedMode.name, updateMetadata: true)
                    }
                }
            } else {
                if let historyMessageID = historyMessageID {
                    await MainActor.run {
                        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown App"
                        let whisperModel = TranscriptionManager.shared.activeModelName
                        let llmModelLabel = LLMManager.shared.activeModelLabel(for: selectedMode)
                        let shouldRunLLM = !selectedMode.prompt.isEmpty
                        MessageMemoryManager.shared.updateMessage(id: historyMessageID, newText: t("Transcription failed"), isError: true, appName: appName, transcriptionModel: whisperModel, llmModel: shouldRunLLM ? llmModelLabel : nil, modeName: selectedMode.name, updateMetadata: true)
                        self.transcriptStore.clear()
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.6, blendDuration: 0.3)) {
                            self.statusText = "Transcription failed"
                            self.failedAudioSamples = samples
                            self.failedSelectedMode = selectedMode
                            self.canRetryTranscription = true
                        }
                    }
                } else {
                    await MainActor.run {
                        self.transcriptStore.clear()
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.6, blendDuration: 0.3)) {
                            self.statusText = "Transcription failed"
                            self.failedAudioSamples = samples
                            self.failedSelectedMode = selectedMode
                            self.canRetryTranscription = true
                        }
                        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown App"
                        let whisperModel = TranscriptionManager.shared.activeModelName
                        let llmModelLabel = LLMManager.shared.activeModelLabel(for: selectedMode)
                        let shouldRunLLM = !selectedMode.prompt.isEmpty
                        
                        let msgId = MessageMemoryManager.shared.saveMessage(t("Transcription failed"), samples: samples, isError: true, appName: appName, transcriptionModel: whisperModel, llmModel: shouldRunLLM ? llmModelLabel : nil, modeName: selectedMode.name)
                        self.failedHistoryMessageID = msgId
                    }
                }
                await SoundPlayer.shared.playSound(named: "Error")
                // Do not hide HUD so the user can see the retry button
            }
        }
    }

    func retryTranscription() {
        guard let samples = failedAudioSamples, let mode = failedSelectedMode else { return }
        let histId = self.failedHistoryMessageID
        withAnimation(.spring(response: 0.5, dampingFraction: 0.6, blendDuration: 0.3)) {
            self.canRetryTranscription = false
            self.statusText = "Processing"
        }
        currentTask = Task {
            await self.processAudio(samples: samples, selectedMode: mode, historyMessageID: histId)
        }
    }

    func retryHistoryTranscription(id: UUID) {
        guard let data = MessageMemoryManager.shared.getAudioData(for: id),
              let samples = MessageMemoryManager.shared.convertWAVToSamples(data: data) else { return }
        
        let mode = self.currentMode ?? VoiceMode.defaults.first! // Use currently selected mode
        
        MessageMemoryManager.shared.updateMessage(id: id, newText: t("Processing"), isError: false)
        
        Task {
            await self.processAudio(samples: samples, selectedMode: mode, historyMessageID: id, isInlineRetry: true)
        }
    }

    func quitApp() {
        self.cancelRecording()
        Task { _ = await self.audioManager.stopRecordingAsync() }
        NotificationCenter.default.post(name: NSNotification.Name("AppWillTerminate"), object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            Darwin._exit(0)
        }
    }
    func startAutoLearnTracking(targetPID: pid_t, originalText: String) {
        AutoLearnService.shared.startAutoLearnTracking(targetPID: targetPID, originalText: originalText, currentNotification: activeDictionaryNotification) { [weak self] newNotification in
            guard let self = self else { return }
            self.activeDictionaryNotification = newNotification
            WindowManager.shared.showHUD(controller: self)
            
            let currentWrong = newNotification.wrong
            let currentCorrect = newNotification.correct
            
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await MainActor.run {
                    if self.activeDictionaryNotification?.wrong == currentWrong && self.activeDictionaryNotification?.correct == currentCorrect {
                        self.hideDictionaryNotification()
                    }
                }
            }
        }
    }

    func undoDictionaryEntry(delayHide: Bool = false) {
        if let notification = activeDictionaryNotification {
            AutoLearnService.shared.undoDictionaryEntry(notification: notification)
        }
        
        if delayHide {
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run {
                    self.hideDictionaryNotification()
                }
            }
        } else {
            self.hideDictionaryNotification()
        }
    }
    
    func hideDictionaryNotification() {
        withAnimation(.easeOut(duration: 0.5)) {
            self.activeDictionaryNotification = nil
        }
        if !self.isRecording {
            self.hideHUDAfterDelay()
        }
    }
    
    func showCopyNotification(text: String) {
        self.activeCopyNotification = text
        WindowManager.shared.showHUD(controller: self)
        
        let duration = UserDefaults.standard.double(forKey: "overlayDuration")
        let finalDuration = duration > 0 ? duration : 15.0
        
        Task {
            try? await Task.sleep(nanoseconds: UInt64(finalDuration * 1_000_000_000))
            await MainActor.run {
                if self.activeCopyNotification == text {
                    self.hideCopyNotification()
                }
            }
        }
    }
    
    func hideCopyNotification() {
        withAnimation(.easeOut(duration: 0.5)) {
            self.activeCopyNotification = nil
        }
        if UserDefaults.standard.bool(forKey: "isIncognitoMode") {
            NotificationCenter.default.post(name: NSNotification.Name("PlayIncognitoAnimation"), object: NSNumber(value: true))
        }
        if !self.isRecording {
            self.hideHUDAfterDelay()
        }
    }
    
    func copyNotificationTextToClipboard(delayHide: Bool = false) {
        if let text = activeCopyNotification {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            if delayHide {
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    await MainActor.run {
                        if self.activeCopyNotification == text {
                            self.hideCopyNotification()
                        }
                    }
                }
            } else {
                self.hideCopyNotification()
            }
        }
    }
    
    func pasteCopyNotificationText(delayHide: Bool = false) {
        if let text = activeCopyNotification {
            if let frontApp = NSWorkspace.shared.frontmostApplication {
                let pid = frontApp.processIdentifier
                DispatchQueue.global(qos: .userInitiated).async {
                    PasteManager.shared.typeTextDirectly(text: text, targetPID: pid, forceFocusElement: nil)
                }
            }
            if delayHide {
                Task {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    await MainActor.run {
                        if self.activeCopyNotification == text {
                            self.hideCopyNotification()
                        }
                    }
                }
            } else {
                self.hideCopyNotification()
            }
        }
    }
}




