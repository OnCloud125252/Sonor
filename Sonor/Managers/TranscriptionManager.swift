import Foundation
import Combine
import SwiftUI

public enum EngineType: String, Equatable, Codable {
    case whisper
    case appleSpeech
    case mlx
}

@MainActor
public class TranscriptionManager: ObservableObject {
    public static let shared = TranscriptionManager()
    
    @Published public private(set) var activeEngine: TranscriptionEngine?
    @Published public var currentEngineType: EngineType = .whisper
    @Published public var isLoaded: Bool = false
    private var unloadTimer: Timer?
    /// Callers race to warm the engine (hotkey press, mode change, app launch). Without a
    /// shared task each caller loads its own multi-GB model copy and the app runs out of memory.
    private var loadTask: Task<Void, Error>?
    /// Bumped whenever a load starts or the engine is reset, so a stale load cannot clear the
    /// task handle belonging to a newer one.
    private var loadGeneration = 0
    public var modelOverrideId: String? = nil

    /// A whisper or MLX context decodes one request at a time, so each call on the main engine
    /// waits for the call before it.
    private var engineGate: Task<Void, Never> = Task {}

    /// The live preview runs on its own small model and its own context.
    ///
    /// A shared context would make the final transcription wait for the preview pass that is
    /// running, and that pass can take seconds with a large model.
    private var previewEngine: WhisperEngine?
    private var previewEngineModelId: String?
    private var previewLoadTask: Task<Void, Never>?
    /// True only while a preview pass holds the main engine. `cancelPreview()` reads it so
    /// that it can never stop the final transcription.
    private var isSharedPreviewRunning = false

    /// Key of the model the preview uses. Empty means the preview is switched off.
    public static let previewModelKey = "previewWhisperModelId"
    public static let defaultPreviewModelId = "base"

    public static var selectedPreviewModelId: String {
        UserDefaults.standard.string(forKey: previewModelKey) ?? defaultPreviewModelId
    }
    
    public var activeModelName: String {
        if let override = modelOverrideId, override != "default" {
            if let w = ModelManager.shared.availableWhisperModels.first(where: { $0.id == override }) {
                return w.name
            } else if let m = ModelManager.shared.availableMLXModels.first(where: { $0.id == override }) {
                return m.name
            } else if override == "appleSpeech" {
                return "Apple Speech"
            }
        }
        
        switch currentEngineType {
        case .whisper:
            let id = ModelManager.shared.selectedWhisperModelId
            return ModelManager.shared.availableWhisperModels.first(where: { $0.id == id })?.name ?? id
        case .mlx:
            let id = ModelManager.shared.selectedMLXModelId
            return ModelManager.shared.availableMLXModels.first(where: { $0.id == id })?.name ?? id ?? "MLX Model"
        case .appleSpeech:
            return "Apple Speech"
        }
    }
    
    private init() {
        // Load preference from UserDefaults if exists
        if let savedTypeStr = UserDefaults.standard.string(forKey: "selectedEngineType"),
           let savedType = EngineType(rawValue: savedTypeStr) {
            self.currentEngineType = savedType
        }
    }
    
    public func setEngineType(_ type: EngineType) {
        self.currentEngineType = type
        UserDefaults.standard.set(type.rawValue, forKey: "selectedEngineType")
        resetEngine() // Force unload the old engine to free memory
    }
    
    public func applyModelOverride(_ overrideId: String?) {
        if self.modelOverrideId != overrideId {
            self.modelOverrideId = overrideId
            resetEngine()
        }
    }
    
    public func resetEngine() {
        // Stop current operations and free resources
        activeEngine?.cancelCurrent()
        releasePreviewEngine()
        loadGeneration += 1
        loadTask?.cancel()
        loadTask = nil
        activeEngine?.unload()
        activeEngine = nil
        isLoaded = false
        ModelManager.shared.isTranscriptionLoaded = false
        unloadTimer?.invalidate()
        unloadTimer = nil
    }
    
    public func cancelUnloadTimer() {
        unloadTimer?.invalidate()
        unloadTimer = nil
    }
    
    public func resetUnloadTimer() {
        unloadTimer?.invalidate()
        let timeout = UserDefaults.standard.integer(forKey: "transcriptionUnloadTimeout")
        guard timeout > 0 else { return }
        
        unloadTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(timeout * 60), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resetEngine()
            }
        }
    }
    
    public func ensureEngineReady() async throws {
        if let engine = activeEngine, engine.isReady {
            return
        }
        if let existing = loadTask {
            return try await existing.value
        }
        loadGeneration += 1
        let generation = loadGeneration
        let task = Task { try await self.loadEngine() }
        loadTask = task
        do {
            try await task.value
        } catch {
            if loadGeneration == generation { loadTask = nil }
            throw error
        }
        if loadGeneration == generation { loadTask = nil }
    }

    private func loadEngine() async throws {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        let targetEngineType: EngineType
        var targetModelId: String? = nil
        
        if let override = modelOverrideId, override != "default" {
            if ModelManager.shared.availableWhisperModels.contains(where: { $0.id == override }) {
                targetEngineType = .whisper
                targetModelId = override
            } else if ModelManager.shared.availableMLXModels.contains(where: { $0.id == override }) {
                targetEngineType = .mlx
                targetModelId = override
            } else if override == "appleSpeech" {
                targetEngineType = .appleSpeech
                targetModelId = nil
            } else {
                targetEngineType = currentEngineType
            }
        } else {
            targetEngineType = currentEngineType
        }
        
        switch targetEngineType {
        case .whisper:
            let selectedId = targetModelId ?? ModelManager.shared.selectedWhisperModelId
            guard let modelURL = ModelManager.shared.urlForWhisperModel(id: selectedId) else {
                throw NSError(domain: "TranscriptionManager", code: 10, userInfo: [NSLocalizedDescriptionKey: "Whisper model URL not found."])
            }
            let modelPath = modelURL.path
            if FileManager.default.fileExists(atPath: modelPath) {
                let engine = WhisperEngine(modelPath: modelPath)
                try await engine.prepare()
                self.activeEngine = engine
            } else {
                throw NSError(domain: "TranscriptionManager", code: 10, userInfo: [NSLocalizedDescriptionKey: "Whisper model file not found at path: \(modelPath)"])
            }
        case .appleSpeech:
            let engine = AppleSpeechEngine()
            try await engine.prepare()
            self.activeEngine = engine
        case .mlx:
            let selectedMLXId = targetModelId ?? ModelManager.shared.selectedMLXModelId ?? "sensevoice-small"
            guard let config = ModelManager.shared.availableMLXModels.first(where: { $0.id == selectedMLXId }) else {
                throw NSError(domain: "TranscriptionManager", code: 12, userInfo: [NSLocalizedDescriptionKey: "Selected MLX model not found in config."])
            }
            let engine = MLXEngine(modelId: config.id, repoId: config.repoId)
            try await engine.prepare()
            self.activeEngine = engine
        }
        
        self.isLoaded = true
        let timeTaken = CFAbsoluteTimeGetCurrent() - startTime
        ModelManager.shared.transcriptionInitializeTime = timeTaken
        ModelManager.shared.isTranscriptionLoaded = true
        ModelManager.shared.lastTranscriptionUsageTime = Date()
    }
    
    public func transcribe(audioSamples: [Float], language: TranscriptionLanguage, vocabularyHints: [String]) async throws -> String {
        try await ensureEngineReady()
        ModelManager.shared.lastTranscriptionUsageTime = Date()
        
        guard let engine = activeEngine else {
            throw NSError(domain: "TranscriptionManager", code: 11, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize active engine."])
        }
        
        return try await serialized {
            try await engine.transcribe(audioSamples: audioSamples, language: language, vocabularyHints: vocabularyHints)
        }
    }

    /// The whisper model the final transcription will use, or nil when it uses another engine.
    private var mainWhisperModelId: String? {
        if let override = modelOverrideId, override != "default" {
            return ModelManager.shared.availableWhisperModels.contains { $0.id == override } ? override : nil
        }
        return currentEngineType == .whisper ? ModelManager.shared.selectedWhisperModelId : nil
    }

    /// Loads the small preview model, if the user picked one and it sits on disk.
    /// This runs beside the main model and never blocks it.
    public func warmPreviewEngine() {
        let modelId = Self.selectedPreviewModelId
        guard !modelId.isEmpty else {
            releasePreviewEngine()
            return
        }
        // A second copy of the model the final transcription already holds would double its
        // memory, and with a large model that is over a gigabyte. The preview shares that one
        // instead, and takes its turn behind the final transcription.
        guard modelId != mainWhisperModelId else {
            releasePreviewEngine()
            return
        }
        if previewEngineModelId == modelId, previewEngine?.isReady == true { return }
        guard let url = ModelManager.shared.urlForWhisperModel(id: modelId),
              FileManager.default.fileExists(atPath: url.path) else {
            releasePreviewEngine()
            return
        }

        releasePreviewEngine()
        previewEngineModelId = modelId
        let engine = WhisperEngine(modelPath: url.path)
        previewEngine = engine
        previewLoadTask = Task { [weak self] in
            try? await engine.prepare()
            if self?.previewEngineModelId != modelId {
                engine.unload()
            }
        }
    }

    /// Reads the words captured so far, for the HUD preview.
    ///
    /// It returns nil until the preview model finished loading. A preview must never make the
    /// user wait for anything.
    public func transcribePreview(audioSamples: [Float]) async -> String? {
        // The preview has no assistant, so it reads the global choice. A forced language makes
        // the small model guess far less on short fragments.
        if let engine = previewEngine, engine.isReady {
            return try? await engine.transcribe(audioSamples: audioSamples, language: .global, vocabularyHints: [])
        }

        // The user picked the model the final transcription already uses, so there is one
        // context and the two have to take turns on it.
        guard Self.selectedPreviewModelId == mainWhisperModelId,
              let engine = activeEngine, engine.isReady else { return nil }
        return try? await serialized {
            // The flag is raised inside the gate. Outside it the preview only waits for its
            // turn, and a stop request then must not reach the final transcription.
            self.isSharedPreviewRunning = true
            defer { self.isSharedPreviewRunning = false }
            return try await engine.transcribe(audioSamples: audioSamples, language: .global, vocabularyHints: [])
        }
    }

    /// Stops the running preview pass.
    ///
    /// With its own model the preview runs on another context, so this only frees the graphics
    /// processor sooner. With a shared model it also hands the context back to the final
    /// transcription instead of making it wait.
    public func cancelPreview() {
        if previewEngine != nil {
            previewEngine?.cancelCurrent()
        } else if isSharedPreviewRunning {
            activeEngine?.cancelCurrent()
        }
    }

    public func releasePreviewEngine() {
        previewLoadTask?.cancel()
        previewLoadTask = nil
        previewEngine?.cancelCurrent()
        previewEngine?.unload()
        previewEngine = nil
        previewEngineModelId = nil
    }

    /// Runs `work` after every call that started before it.
    private func serialized<T: Sendable>(_ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = engineGate
        let current = Task { @MainActor () -> Result<T, Error> in
            await previous.value
            do {
                return .success(try await work())
            } catch {
                return .failure(error)
            }
        }
        engineGate = Task { _ = await current.value }
        return try await current.value.get()
    }
}
