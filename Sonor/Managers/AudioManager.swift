import Foundation
import AVFoundation
import Combine
import CoreAudio
import AudioToolbox
import Accelerate
import os

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// Manages the capture of system audio or microphone input, converting it into
/// 16kHz Float32 PCM samples suitable for Whisper model processing.
class AudioManager: ObservableObject {
    static let shared = AudioManager()
    
    private var audioEngine: AVAudioEngine?
    private var audioConverter: AVAudioConverter? // Converts raw audio to our target format (16kHz)
    /// Serial queue that serializes ALL engine operations to prevent race conditions.
    private let engineQueue = DispatchQueue(label: "com.sonor.engine", qos: .userInitiated)
    
    @Published var isRecording = false
    @Published var audioLevel: Float = 0.0 // RMS audio level for UI visualizations
    private var accumulatedSamples: [Float] = []
    private let samplesQueue = DispatchQueue(label: "com.sonor.samplesQueue")
    private var isTapInstalled = false
    private let targetFormat: AVAudioFormat?

    /// Audio-thread state. The render callback runs on a real-time thread, so every field it
    /// shares with the main thread lives behind this lock instead of a plain stored property.
    private let levelLock = OSAllocatedUnfairLock(initialState: LevelState())
    private struct LevelState {
        var isPaused = false
        var level: Float = 0
        var lastPublish: UInt64 = 0
        /// Follows the quiet parts of the room, so the voice test works on any microphone gain.
        var noiseFloor: Float = 0
        /// Uptime in nanoseconds when the microphone last heard a voice.
        var lastVoice: UInt64 = 0
        /// The mark the user set on the meter. Nil means follow the room.
        var manualThreshold: Float?
        /// The level a voice has to beat right now. The settings meter draws it.
        var threshold: Float = VoiceActivity.minimumLevel
        var isHearingVoice = false
        /// True while the microphone runs only to feed the settings meter.
        var isMonitorOnly = false
        /// Loudest reading since the waveform last looked.
        var peak: Float = 0
    }

    /// Publishing `audioLevel` on every render callback costs a main-thread hop ~47x/sec.
    /// The waveform samples at 20 Hz, so anything faster is wasted work.
    private static let levelPublishInterval: UInt64 = 45_000_000

    var isPaused: Bool {
        get { levelLock.withLock { $0.isPaused } }
        set { levelLock.withLock { $0.isPaused = newValue } }
    }

    /// Latest RMS level, safe to read from any thread.
    var currentLevel: Float {
        levelLock.withLock { $0.level }
    }

    /// Uptime in nanoseconds when the microphone last heard a voice. Zero means never.
    ///
    /// The live preview reads this. Without it the preview runs the transcription model again
    /// and again on the same silent buffer, and the text on screen keeps changing by itself.
    var lastVoiceUptime: UInt64 {
        levelLock.withLock { $0.lastVoice }
    }

    /// The level a voice has to beat right now, and whether it beats it.
    var voiceState: (threshold: Float, isHearingVoice: Bool) {
        levelLock.withLock { ($0.threshold, $0.isHearingVoice) }
    }

    /// Loudest reading since the last call, and it resets the count.
    ///
    /// The waveform draws 20 bars a second while the microphone reports about 47 readings a
    /// second. Reading the latest one alone threw away half the peaks, so a sharp syllable
    /// could land on a short bar.
    var peakLevelSinceLastRead: Float {
        levelLock.withLock { state in
            let peak = state.peak
            state.peak = 0
            return peak
        }
    }

    /// Reads the saved microphone sensitivity into the audio thread.
    /// Call this after the setting changes, so the running capture picks it up at once.
    func applyVoiceThresholdSetting() {
        let manual = VoiceActivity.savedManualLevel()
        levelLock.withLock { $0.manualThreshold = manual }
    }

    /// Starts the microphone only to feed the settings meter. It keeps no samples.
    func startMonitoring() throws {
        guard !isRecording else { return }
        try startRecording(clearSamples: true, monitorOnly: true)
    }

    func stopMonitoring() {
        guard levelLock.withLock({ $0.isMonitorOnly }) else { return }
        Task { _ = await stopRecordingAsync() }
    }
    
    private init() {
        self.targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)
        if targetFormat == nil {
        }
        registerDeviceChangeListener()
    }
    
    deinit {
        unregisterDeviceChangeListener()
    }
    
    // MARK: - Pre-warming
    
    /// Pre-warms the audio engine by creating it (if needed), configuring the input device,
    /// and calling prepare(). Runs asynchronously on the engine queue.
    func prepareEngine() {
        engineQueue.async { [weak self] in
            guard let self = self else { return }
            
            if self.audioEngine != nil {
                // Engine already exists — just make sure it's prepared
                self.audioEngine?.prepare()
                return
            }
            
            // Create new engine
            let engine = AVAudioEngine()
            self.configureDevice(on: engine.inputNode)
            engine.prepare()
            try? engine.start()
            engine.stop()
            self.audioEngine = engine
        }
    }
    
    // MARK: - Device Change Listener
    
    private static let deviceChangeProc: AudioObjectPropertyListenerProc = { _, _, _, clientData in
        guard let clientData = clientData else { return noErr }
        
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("AudioDevicesDidChange"), object: nil)
        }
        
        let manager = Unmanaged<AudioManager>.fromOpaque(clientData).takeUnretainedValue()
        if !manager.isRecording {
            // Device changed while not recording — rebuild engine with new device
            manager.engineQueue.async {
                if let engine = manager.audioEngine {
                    if manager.isTapInstalled {
                        engine.inputNode.removeTap(onBus: 0)
                        manager.isTapInstalled = false
                    }
                    engine.stop()
                }
                manager.audioEngine = nil
                
                let newEngine = AVAudioEngine()
                manager.configureDevice(on: newEngine.inputNode)
                newEngine.prepare()
                manager.audioEngine = newEngine
            }
        }
        return noErr
    }
    
    private func registerDeviceChangeListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            AudioManager.deviceChangeProc,
            selfPtr
        )
    }
    
    private func unregisterDeviceChangeListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            AudioManager.deviceChangeProc,
            selfPtr
        )
    }

    // MARK: - Device Configuration
    
    private func configureDevice(on inputNode: AVAudioInputNode) {
        if let savedDeviceUID = UserDefaults.standard.string(forKey: "selectedAudioDeviceUID"), !savedDeviceUID.isEmpty {
            let devices = getAudioInputDevices()
            if let targetDevice = devices.first(where: { $0.uid == savedDeviceUID }),
               targetDevice.id != kAudioObjectUnknown {
                if let audioUnit = inputNode.audioUnit {
                    var deviceId = targetDevice.id
                    AudioUnitSetProperty(
                        audioUnit,
                        kAudioOutputUnitProperty_CurrentDevice,
                        kAudioUnitScope_Global,
                        0,
                        &deviceId,
                        UInt32(MemoryLayout<AudioDeviceID>.size)
                    )
                }
            }
        }
    }

    // MARK: - Recording
    
    /// Initializes the audio engine and begins capturing samples.
    /// If the engine was pre-warmed via prepareEngine(), start is nearly instantaneous.
    /// - Parameter clearSamples: If true, previously recorded samples are discarded before starting.
    func startRecording(clearSamples: Bool = true, monitorOnly: Bool = false) throws {
        // A dictation that starts while the settings meter runs has to take the capture over,
        // or the samples it needs are thrown away.
        levelLock.withLock { $0.isMonitorOnly = monitorOnly }
        if clearSamples {
            // Must run on samplesQueue: the audio tap appends to this same buffer.
            samplesQueue.sync { accumulatedSamples.removeAll(keepingCapacity: true) }
            // A new room, so the old noise floor does not apply.
            let manual = VoiceActivity.savedManualLevel()
            levelLock.withLock { state in
                state.noiseFloor = 0
                state.lastVoice = 0
                state.peak = 0
                state.isHearingVoice = false
                state.manualThreshold = manual
            }
        }
        
        // All engine work serialized on engineQueue to prevent races
        try engineQueue.sync { [self] in
            // Create engine if none exists (first time or after pause destroyed it)
            if audioEngine == nil {
                let engine = AVAudioEngine()
                configureDevice(on: engine.inputNode)
                audioEngine = engine
            }
            
            guard let engine = audioEngine else { return }
            
            if self.isTapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                self.isTapInstalled = false
            }
            
            let inputNode = engine.inputNode
            let inputFormat = inputNode.inputFormat(forBus: 0)
            guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
                print("Invalid input format, preventing crash.")
                return
            }
            guard let targetFormat = targetFormat else {
                return
            }
            audioConverter = AVAudioConverter(from: inputFormat, to: targetFormat)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] (buffer, time) in
                self?.processAudio(buffer: buffer)
            }
            self.isTapInstalled = true
            engine.prepare()
            if !engine.isRunning {
                do {
                    try engine.start()
                } catch {
                    print("Engine start failed, recovering with new engine: \(error)")
                    // Hardware state likely corrupted by rapid toggling.
                    // Destroy corrupted engine and create a fresh one.
                    if self.isTapInstalled {
                        engine.inputNode.removeTap(onBus: 0)
                        self.isTapInstalled = false
                    }
                    self.audioEngine = nil
                    
                    let newEngine = AVAudioEngine()
                    configureDevice(on: newEngine.inputNode)
                    self.audioEngine = newEngine
                    
                    let newInputNode = newEngine.inputNode
                    let newInputFormat = newInputNode.inputFormat(forBus: 0)
                    self.audioConverter = AVAudioConverter(from: newInputFormat, to: targetFormat)
                    newInputNode.installTap(onBus: 0, bufferSize: 1024, format: newInputFormat) { [weak self] (buffer, time) in
                        self?.processAudio(buffer: buffer)
                    }
                    self.isTapInstalled = true
                    newEngine.prepare()
                    try newEngine.start()
                }
            }
            NotificationCenter.default.addObserver(self, selector: #selector(handleConfigurationChange), name: .AVAudioEngineConfigurationChange, object: self.audioEngine)
        }
        
        DispatchQueue.main.async {
            self.isRecording = true
        }
    }
    
    @objc private func handleConfigurationChange(notification: Notification) {
        engineQueue.async { [weak self] in
            guard let self = self, let engine = self.audioEngine else { return }
            
            let wasTapInstalled = self.isTapInstalled
            if wasTapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                self.isTapInstalled = false
            }
            
            engine.stop()
            
            if wasTapInstalled {
                let inputFormat = engine.inputNode.inputFormat(forBus: 0)
                if let target = self.targetFormat {
                    self.audioConverter = AVAudioConverter(from: inputFormat, to: target)
                    engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] (buffer, time) in
                        self?.processAudio(buffer: buffer)
                    }
                    self.isTapInstalled = true
                    
                    engine.prepare()
                    do {
                        try engine.start()
                    } catch {
                        print("Failed to restart engine after config change: \(error)")
                    }
                }
            } else {
                // If we weren't recording, just re-prepare the engine for the new device
                engine.prepare()
            }
        }
    }
    
    func restartEngineForDeviceChange() {
        Task {
            let wasRecording = self.isRecording
            let oldSamples = wasRecording ? await self.stopRecordingAsync() : []
            
            self.engineQueue.sync {
                if let engine = self.audioEngine {
                    if self.isTapInstalled {
                        engine.inputNode.removeTap(onBus: 0)
                        self.isTapInstalled = false
                    }
                    engine.stop()
                }
                self.audioEngine = nil
            }
            
            if wasRecording {
                do {
                    try self.startRecording(clearSamples: false)
                    self.samplesQueue.async {
                        self.accumulatedSamples.insert(contentsOf: oldSamples, at: 0)
                    }
                } catch {
                    print("Error restarting engine after device change: \(error)")
                }
            }
        }
    }

    /// Number of samples captured so far. The live preview skips a pass when no new audio arrived.
    var capturedSampleCount: Int {
        samplesQueue.sync { accumulatedSamples.count }
    }

    /// Copies the captured audio without stopping the engine, so the live preview can read it
    /// while the recording continues.
    ///
    /// Only the newest `maxSeconds` come back, because one preview pass has to stay short
    /// enough to feel live. Long silences are cut out of that window first. A speaker who
    /// thinks for ten seconds used to push their own opening sentence out of the window, and
    /// the words already on screen then disappeared.
    func snapshotSamples(maxSeconds: Double) -> [Float] {
        let sampleRate = Int(targetFormat?.sampleRate ?? 16000)
        let maxCount = Int(maxSeconds * Double(sampleRate))
        let threshold = levelLock.withLock { $0.threshold }

        // Only the tail is copied, and it is copied into a buffer of its own. Handing back the
        // whole array made the next append copy every sample already recorded, because the two
        // then shared one buffer. That cost grew with every second of the dictation.
        let searchLimit = maxCount * AudioManager.silenceSearchFactor
        let window: [Float] = samplesQueue.sync {
            let start = max(0, accumulatedSamples.count - searchLimit)
            return Array(accumulatedSamples[start...])
        }
        guard window.count > maxCount else { return window }
        return AudioManager.recentSpeech(in: window, maxCount: maxCount, sampleRate: sampleRate, threshold: threshold)
    }

    /// How much audio the silence search may look through, as a multiple of the window.
    /// A bound keeps one preview pass cheap however long the dictation runs.
    static let silenceSearchFactor = 3

    /// Frame length used to look for silence. 100 ms is short enough to sit between words and
    /// long enough to be cheap.
    static let silenceFrameSeconds: Double = 0.1
    /// A gap shorter than this stays in place. Cutting the natural gaps between words would
    /// glue the words together and the model would read them wrong.
    static let keptGapSeconds: Double = 0.6

    /// Returns the newest `maxCount` samples, with long silences taken out.
    static func recentSpeech(in samples: [Float], maxCount: Int, sampleRate: Int, threshold: Float) -> [Float] {
        let frameLength = max(1, Int(silenceFrameSeconds * Double(sampleRate)))
        let keptGapFrames = max(1, Int(keptGapSeconds / silenceFrameSeconds))

        var kept: [Range<Int>] = []
        var collected = 0
        var quietRun = 0
        var end = samples.count

        // The walk runs backwards, because the newest speech is the speech to keep.
        while end > 0 && collected < maxCount {
            let start = max(0, end - frameLength)
            var rms: Float = 0
            samples.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                vDSP_rmsqv(base + start, 1, &rms, vDSP_Length(end - start))
            }

            if rms > threshold {
                quietRun = 0
            } else {
                quietRun += 1
            }
            // Only the opening of a long gap is dropped. The part next to the speech stays,
            // so the model still hears where one sentence ends and the next begins.
            if quietRun <= keptGapFrames {
                kept.append(start..<end)
                collected += end - start
            }
            end = start
        }

        // The threshold can end up above the whole recording, for example when the room grew
        // louder while the user spoke. Cutting on a wrong threshold would hand back a fraction
        // of a second, so the plain newest window wins whenever too little survived.
        guard collected >= maxCount / 2 else {
            return Array(samples.suffix(maxCount))
        }

        var result = [Float]()
        result.reserveCapacity(collected)
        for range in kept.reversed() {
            result.append(contentsOf: samples[range])
        }
        return result
    }

    func stopRecordingAsync() async -> [Float] {
        await withCheckedContinuation { continuation in
            engineQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: [])
                    return
                }
                
                NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: self.audioEngine)
                
                if self.isTapInstalled {
                    self.audioEngine?.inputNode.removeTap(onBus: 0)
                    self.isTapInstalled = false
                }
                self.audioEngine?.stop()
                
                self.levelLock.withLock { state in
                    state.level = 0
                    state.isHearingVoice = false
                    state.isMonitorOnly = false
                }
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.audioLevel = 0.0
                }
                
                let samples = self.samplesQueue.sync {
                    let s = self.accumulatedSamples
                    self.accumulatedSamples = []
                    return s
                }
                
                continuation.resume(returning: samples)
            }
        }
    }
    /// Physically stops the audio engine to release the microphone lock and remove the yellow privacy dot.
    func pauseRecording() {
        let alreadyPaused = levelLock.withLock { state -> Bool in
            if state.isPaused { return true }
            state.isPaused = true
            return false
        }
        guard !alreadyPaused else { return }
        
        engineQueue.sync { [self] in
            NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: audioEngine)
            if isTapInstalled {
                audioEngine?.inputNode.removeTap(onBus: 0)
                isTapInstalled = false
            }
            audioEngine?.stop()
            audioEngine = nil // Destroy to release mic (removes yellow privacy dot)
        }
        
        levelLock.withLock { $0.level = 0 }
        DispatchQueue.main.async {
            self.audioLevel = 0.0
        }
    }
    
    /// Recreates the audio engine and resumes recording, keeping the previously accumulated samples.
    func resumeRecording() throws {
        let wasPaused = levelLock.withLock { state -> Bool in
            guard state.isPaused else { return false }
            state.isPaused = false
            return true
        }
        guard wasPaused else { return }
        try startRecording(clearSamples: false)
    }

    /// Receives raw buffers from the audio engine, calculates UI volume levels,
    /// and performs format conversion into `accumulatedSamples`.
    private func processAudio(buffer: AVAudioPCMBuffer) {
        if levelLock.withLock({ $0.isPaused }) { return }
        autoreleasepool {
            let length = Int(buffer.frameLength)
            if let channelData = buffer.floatChannelData?[0], length > 0 {
                var rms: Float = 0
                vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(length))
                let now = DispatchTime.now().uptimeNanoseconds
                let shouldPublish = levelLock.withLock { state -> Bool in
                    state.level = rms
                    state.peak = max(state.peak, rms)
                    let previousThreshold = VoiceActivity.threshold(manual: state.manualThreshold, noiseFloor: state.noiseFloor)
                    if state.noiseFloor == 0 {
                        state.noiseFloor = rms
                    } else if rms < state.noiseFloor {
                        state.noiseFloor += (rms - state.noiseFloor) * 0.2
                    } else if rms < previousThreshold {
                        // Only a quiet frame raises the floor. Letting every loud frame raise
                        // it made the floor climb toward the speaker during a long dictation,
                        // until the speaker fell below their own threshold and the preview
                        // kept nothing but the last words.
                        state.noiseFloor += (rms - state.noiseFloor) * 0.002
                    }
                    let threshold = VoiceActivity.threshold(manual: state.manualThreshold, noiseFloor: state.noiseFloor)
                    state.threshold = threshold
                    state.isHearingVoice = rms > threshold
                    if state.isHearingVoice {
                        state.lastVoice = now
                    }
                    guard now &- state.lastPublish >= AudioManager.levelPublishInterval else { return false }
                    state.lastPublish = now
                    return true
                }
                if shouldPublish {
                    DispatchQueue.main.async {
                        self.audioLevel = rms
                    }
                }
            }
            // The settings meter needs the level only. Converting and keeping samples for it
            // would waste the processor and grow a buffer that nobody reads.
            if levelLock.withLock({ $0.isMonitorOnly }) { return }
            guard let converter = audioConverter, let targetFormat = targetFormat else { return }
            let ratio = targetFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            pcmBuffer.frameLength = pcmBuffer.frameCapacity // Prevents AVAudioConverter from returning 0 frames
            
            var error: NSError? = nil
            var hasData = false
            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                if !hasData {
                    outStatus.pointee = .haveData
                    hasData = true
                    return buffer
                } else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
            }
            converter.convert(to: pcmBuffer, error: &error, withInputFrom: inputBlock)
            if let floatData = pcmBuffer.floatChannelData?[0] {
                let frameLength = Int(pcmBuffer.frameLength)
                let array = Array<Float>(UnsafeBufferPointer(start: floatData, count: frameLength))
                samplesQueue.async {
                    self.accumulatedSamples.append(contentsOf: array)
                }
            }
        }
    }
    func getAudioInputDevices() -> [AudioDevice] {
        var devices: [AudioDevice] = []
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        if status != noErr { return devices }
        
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs)
        
        for id in deviceIDs {
            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            if AudioObjectGetPropertyDataSize(id, &streamAddress, 0, nil, &streamSize) != noErr || streamSize == 0 {
                continue 
            }
            
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            var coreName: Unmanaged<CFString>? = nil
            AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &coreName)
            let name = (coreName?.takeRetainedValue() as String?) ?? "Unknown Device"
            
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            var coreUID: Unmanaged<CFString>? = nil
            AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, &coreUID)
            let uid = (coreUID?.takeRetainedValue() as String?) ?? UUID().uuidString
            
            devices.append(AudioDevice(id: id, uid: uid, name: name))
        }
        return devices
    }

    func getAudioOutputDevices() -> [AudioDevice] {
        var devices: [AudioDevice] = []
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        if status != noErr { return devices }
        
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs)
        
        for id in deviceIDs {
            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            if AudioObjectGetPropertyDataSize(id, &streamAddress, 0, nil, &streamSize) != noErr || streamSize == 0 {
                continue 
            }
            
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            var coreName: Unmanaged<CFString>? = nil
            AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &coreName)
            let name = (coreName?.takeRetainedValue() as String?) ?? "Unknown Device"
            
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            var coreUID: Unmanaged<CFString>? = nil
            AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, &coreUID)
            let uid = (coreUID?.takeRetainedValue() as String?) ?? UUID().uuidString
            
            devices.append(AudioDevice(id: id, uid: uid, name: name))
        }
        return devices
    }

    func getDefaultAudioOutputDeviceUID() -> String? {
        var defaultOutputDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &defaultOutputDeviceID) == noErr {
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var coreUID: Unmanaged<CFString>? = nil
            if AudioObjectGetPropertyData(defaultOutputDeviceID, &uidAddress, 0, nil, &uidSize, &coreUID) == noErr {
                return coreUID?.takeRetainedValue() as String?
            }
        }
        return nil
    }
}
