import Foundation
import AVFoundation
import SwiftUI
import Combine
import Accelerate
import os

struct MemoryMessage: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let text: String
    let date: Date
    var hasAudio: Bool? = false // Optional for backwards compatibility with existing JSON
    var isError: Bool? = false
    var appName: String? = nil
    var transcriptionModel: String? = nil
    var llmModel: String? = nil
    var modeName: String? = nil
}

@MainActor
class MessageMemoryManager: ObservableObject {
    static let shared = MessageMemoryManager()
    @Published var messages: [MemoryMessage] = []
    @Published var historyStorageType: String = UserDefaults.standard.string(forKey: "historyStorageType") ?? "RAM" {
        didSet {
            UserDefaults.standard.set(historyStorageType, forKey: "historyStorageType")
        }
    }
    
    // RAM storage for audio samples (WAV Data)
    private var ramAudioSamples: [UUID: Data] = [:]

    /// History is encoded and written off the main thread. Encoding a long history on the
    /// main actor stalled the UI on every saved message.
    private let diskQueue = DispatchQueue(label: "com.sonor.historyDisk", qos: .utility)
    private let pendingSnapshot = OSAllocatedUnfairLock<[MemoryMessage]?>(initialState: nil)
    
    var sonorURL: URL {
        let fileManager = FileManager.default
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = appSupportURL.appendingPathComponent("Sonor", isDirectory: true)
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        }
        return url
    }
    
    var historyFileURL: URL {
        return sonorURL.appendingPathComponent("history.json")
    }
    
    var audioDirectoryURL: URL {
        let url = sonorURL.appendingPathComponent("AudioHistory", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        }
        return url
    }
    
    func historyAudioURL(for id: UUID) -> URL {
        return audioDirectoryURL.appendingPathComponent("\(id.uuidString).wav")
    }
    
    private init() {
        loadHistory()
    }
    func loadHistory() {
        guard historyStorageType == "File" else {
            self.messages = []
            return
        }
        let url = historyFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            self.messages = []
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([MemoryMessage].self, from: data)
            self.messages = decoded
            trimHistoryIfNeeded()
        } catch {
            self.messages = []
        }
    }
    private func saveToDisk() {
        guard historyStorageType == "File" else { return }
        let url = historyFileURL
        let snapshot = messages
        pendingSnapshot.withLock { $0 = snapshot }
        diskQueue.async { [pendingSnapshot] in
            // Bursts of updates collapse into one write: the first job claims the newest
            // snapshot and the jobs queued behind it find nothing left to do.
            guard let snapshot = pendingSnapshot.withLock({ value -> [MemoryMessage]? in
                defer { value = nil }
                return value
            }) else { return }
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: [.atomic])
        }
    }
    
    private func deleteDiskFile() {
        let url = historyFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        // Also delete audio directory
        let audioDir = audioDirectoryURL
        if FileManager.default.fileExists(atPath: audioDir.path) {
            try? FileManager.default.removeItem(at: audioDir)
        }
    }
    func switchToFileMode() {
        historyStorageType = "File"
        saveToDisk()
        
        // Move RAM audio to File
        for (id, data) in ramAudioSamples {
            let url = historyAudioURL(for: id)
            try? data.write(to: url)
        }
        ramAudioSamples.removeAll()
    }
    
    func switchToRAMMode() {
        historyStorageType = "RAM"
        // Move File audio to RAM before deleting
        for msg in messages {
            if msg.hasAudio == true {
                let url = historyAudioURL(for: msg.id)
                if let data = try? Data(contentsOf: url) {
                    ramAudioSamples[msg.id] = data
                }
            }
        }
        deleteDiskFile()
    }
    
    @discardableResult
    func saveMessage(_ text: String, samples: [Float]? = nil, isError: Bool = false, appName: String? = nil, transcriptionModel: String? = nil, llmModel: String? = nil, modeName: String? = nil) -> UUID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if UserDefaults.standard.bool(forKey: "isIncognitoMode") {
            return nil
        }
        
        let id = UUID()
        let audioEnabled = UserDefaults.standard.object(forKey: "historySavesAudio") == nil ? true : UserDefaults.standard.bool(forKey: "historySavesAudio")

        // Encode first. `convertToWAVData` returns nil for near-silent input, and marking the
        // record as having audio before that check produced play buttons with nothing to play.
        var wavData: Data? = nil
        if audioEnabled, let samples = samples, !samples.isEmpty {
            wavData = convertToWAVData(samples: samples)
        }
        let hasAudio = wavData != nil

        let msg = MemoryMessage(id: id, text: trimmed, date: Date(), hasAudio: hasAudio, isError: isError, appName: appName, transcriptionModel: transcriptionModel, llmModel: llmModel, modeName: modeName)
        messages.append(msg)
        
        if let wavData = wavData {
            if historyStorageType == "RAM" {
                ramAudioSamples[id] = wavData
            } else if historyStorageType == "File" {
                let url = historyAudioURL(for: id)
                try? wavData.write(to: url)
            }
        }
        
        trimHistoryIfNeeded()
        
        if historyStorageType == "File" {
            saveToDisk()
        }
        return id
    }
    
    func updateMessage(id: UUID, newText: String, isError: Bool = false, appName: String? = nil, transcriptionModel: String? = nil, llmModel: String? = nil, modeName: String? = nil, updateMetadata: Bool = false) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            let msg = messages[index]
            let updated = MemoryMessage(
                id: msg.id, 
                text: newText, 
                date: msg.date, 
                hasAudio: msg.hasAudio, 
                isError: isError, 
                appName: updateMetadata ? (appName ?? msg.appName) : msg.appName, 
                transcriptionModel: updateMetadata ? (transcriptionModel ?? msg.transcriptionModel) : msg.transcriptionModel, 
                llmModel: updateMetadata ? llmModel : msg.llmModel, // llmModel can legitimately become nil if changed to a non-LLM mode
                modeName: updateMetadata ? (modeName ?? msg.modeName) : msg.modeName
            )
            messages[index] = updated
            if historyStorageType == "File" {
                saveToDisk()
            }
        }
    }

    func clearHistory() {
        messages.removeAll()
        ramAudioSamples.removeAll()
        if historyStorageType == "File" {
            deleteDiskFile()
        }
    }
    
    func trimHistoryIfNeeded() {
        let limit = UserDefaults.standard.integer(forKey: "historySaveLimit")
        guard limit > 0, messages.count > limit else { return }
        
        let toRemove = messages.count - limit
        let removedMessages = Array(messages.prefix(toRemove))
        messages.removeFirst(toRemove)
        
        for msg in removedMessages {
            ramAudioSamples.removeValue(forKey: msg.id)
            if historyStorageType == "File" {
                let url = historyAudioURL(for: msg.id)
                if FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        
        if historyStorageType == "File" {
            saveToDisk()
        }
    }
    
    func clearAllAudio() {
        for i in 0..<messages.count {
            messages[i].hasAudio = false
        }
        if historyStorageType == "File" {
            saveToDisk()
        }
        ramAudioSamples.removeAll()
        let audioDir = audioDirectoryURL
        if FileManager.default.fileExists(atPath: audioDir.path) {
            try? FileManager.default.removeItem(at: audioDir)
        }
    }
    
    func deleteMessage(id: UUID) {
        messages.removeAll { $0.id == id }
        ramAudioSamples.removeValue(forKey: id)
        if historyStorageType == "File" {
            let url = historyAudioURL(for: id)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
            saveToDisk()
        }
    }
    
    func getAudioData(for id: UUID) -> Data? {
        if historyStorageType == "RAM" {
            return ramAudioSamples[id]
        } else {
            let url = historyAudioURL(for: id)
            return try? Data(contentsOf: url)
        }
    }
    
    /// Trims silence, normalizes and encodes to 16-bit PCM.
    /// The scalar version appended one `Int16` at a time to a `Data`, which took about 21 ms
    /// for a 60 second clip on the main actor. Accelerate does the same work in under 1 ms.
    private func convertToWAVData(samples: [Float]) -> Data? {
        guard !samples.isEmpty else { return nil }

        let chunkSize = 800
        let chunkCount = samples.count / chunkSize
        guard chunkCount > 0 else { return nil }

        var chunkRms = [Float](repeating: 0, count: chunkCount)
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for chunk in 0..<chunkCount {
                var rms: Float = 0
                vDSP_rmsqv(base + chunk * chunkSize, 1, &rms, vDSP_Length(chunkSize))
                chunkRms[chunk] = rms
            }
        }

        var peakRms: Float = 0
        vDSP_maxv(chunkRms, 1, &peakRms, vDSP_Length(chunkCount))
        let silenceThreshold = max(peakRms, 0.0001) * 0.1 // 10% of peak volume

        var startChunk = 0
        while startChunk < chunkCount && chunkRms[startChunk] < silenceThreshold { startChunk += 1 }
        guard startChunk < chunkCount else { return nil }
        var endChunk = chunkCount
        while endChunk > startChunk && chunkRms[endChunk - 1] < silenceThreshold { endChunk -= 1 }

        // Add 0.2s padding (3200 samples) to avoid cutting too abruptly
        let startIndex = max(0, startChunk * chunkSize - 3200)
        let endIndex = min(samples.count, endChunk * chunkSize + 3200)
        guard startIndex < endIndex else { return nil }
        let count = endIndex - startIndex

        var maxAmplitude: Float = 0
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            vDSP_maxmgv(base + startIndex, 1, &maxAmplitude, vDSP_Length(count))
        }
        var scale = (0.9 / max(maxAmplitude, 0.001)) * 32767.0

        var scaled = [Float](repeating: 0, count: count)
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            vDSP_vsmul(base + startIndex, 1, &scale, &scaled, 1, vDSP_Length(count))
        }
        var lowerBound: Float = -32767.0
        var upperBound: Float = 32767.0
        vDSP_vclip(scaled, 1, &lowerBound, &upperBound, &scaled, 1, vDSP_Length(count))

        var pcm = [Int16](repeating: 0, count: count)
        vDSP_vfix16(scaled, 1, &pcm, 1, vDSP_Length(count))
        let pcmData = pcm.withUnsafeBufferPointer { Data(buffer: $0) }

        return createWAV(from: pcmData, sampleRate: 16000, channels: 1)
    }
    
    private func createWAV(from pcmData: Data, sampleRate: Int32, channels: Int16) -> Data {
        var header = Data()
        let byteRate = sampleRate * Int32(channels) * 2 // 16-bit
        let blockAlign = channels * 2
        
        // RIFF
        header.append(contentsOf: "RIFF".utf8)
        var chunkSize = Int32(36 + pcmData.count).littleEndian
        header.append(Data(bytes: &chunkSize, count: 4))
        header.append(contentsOf: "WAVE".utf8)
        
        // fmt
        header.append(contentsOf: "fmt ".utf8)
        var fmtSize = Int32(16).littleEndian
        header.append(Data(bytes: &fmtSize, count: 4))
        var audioFormat = Int16(1).littleEndian // PCM
        header.append(Data(bytes: &audioFormat, count: 2))
        var numChannels = channels.littleEndian
        header.append(Data(bytes: &numChannels, count: 2))
        var rate = sampleRate.littleEndian
        header.append(Data(bytes: &rate, count: 4))
        var bRate = byteRate.littleEndian
        header.append(Data(bytes: &bRate, count: 4))
        var bAlign = blockAlign.littleEndian
        header.append(Data(bytes: &bAlign, count: 2))
        var bitsPerSample = Int16(16).littleEndian
        header.append(Data(bytes: &bitsPerSample, count: 2))
        
        // data
        header.append(contentsOf: "data".utf8)
        var dataSize = Int32(pcmData.count).littleEndian
        header.append(Data(bytes: &dataSize, count: 4))
        
        var fullData = header
        fullData.append(pcmData)
        return fullData
    }
    
    /// Test seam for the encoder, which is otherwise only reachable through `saveMessage`.
    func testConvertToWAVData(samples: [Float]) -> Data? {
        convertToWAVData(samples: samples)
    }

    func convertWAVToSamples(data: Data) -> [Float]? {
        // Simple WAV parser (assuming 16kHz, 16-bit PCM Mono as we create it)
        guard data.count > 44 else { return nil }
        let pcmData = data.subdata(in: 44..<data.count)
        var samples: [Float] = []
        samples.reserveCapacity(pcmData.count / 2)
        
        pcmData.withUnsafeBytes { buffer in
            let int16Pointer = buffer.bindMemory(to: Int16.self)
            for i in 0..<int16Pointer.count {
                let sample = Float(Int16(littleEndian: int16Pointer[i])) / 32767.0
                samples.append(sample)
            }
        }
        return samples
    }
}

