import Foundation
import os

/// Stores minimal usage statistics locally in UserDefaults.
///
/// Every dictation used to decode the whole history, append one record and re-encode it on the
/// calling thread, which is the main actor. That cost grows with every dictation ever made.
/// The records are now held in memory and written on a background queue, and consecutive
/// writes collapse into one. The stored key and format are unchanged, so existing data loads
/// exactly as before.
final class UsageTrackingService {
    static let shared = UsageTrackingService()

    private static let storageKey = "usageStats"
    private let writeQueue = DispatchQueue(label: "com.sonor.usageStats", qos: .utility)
    private let pendingSnapshot = OSAllocatedUnfairLock<[UsageStat]?>(initialState: nil)
    private let cache: OSAllocatedUnfairLock<[UsageStat]?>

    private init() {
        cache = OSAllocatedUnfairLock(initialState: nil)
    }

    func recordUsage(duration: Double, text: String) {
        let isStatsEnabled = UserDefaults.standard.object(forKey: "saveStatsEnabled") == nil ? true : UserDefaults.standard.bool(forKey: "saveStatsEnabled")

        if UserDefaults.standard.bool(forKey: "isIncognitoMode") || !isStatsEnabled {
            return
        }
        let wordCount = text.split(separator: " ").count
        let stat = UsageStat(id: UUID(), date: Date(), duration: duration, wordCount: wordCount)

        var stats = loadedStats()
        stats.append(stat)
        cache.withLock { $0 = stats }
        scheduleWrite(stats)
        NotificationCenter.default.post(name: Notification.Name("UsageStatsUpdated"), object: nil)
    }

    func getStats() -> [UsageStat] {
        loadedStats()
    }

    /// Used by the backup importer, which replaces the whole history at once.
    /// Writing the key straight to UserDefaults would leave this cache stale, and the next
    /// dictation would then overwrite the imported data.
    func replaceAll(_ stats: [UsageStat]) {
        cache.withLock { $0 = stats }
        scheduleWrite(stats)
        NotificationCenter.default.post(name: Notification.Name("UsageStatsUpdated"), object: nil)
    }

    func clearStats() {
        cache.withLock { $0 = [] }
        pendingSnapshot.withLock { $0 = nil }
        writeQueue.async {
            UserDefaults.standard.removeObject(forKey: UsageTrackingService.storageKey)
        }
        NotificationCenter.default.post(name: Notification.Name("UsageStatsUpdated"), object: nil)
    }

    private func loadedStats() -> [UsageStat] {
        if let cached = cache.withLock({ $0 }) { return cached }
        let decoded: [UsageStat]
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let stats = try? JSONDecoder().decode([UsageStat].self, from: data) {
            decoded = stats
        } else {
            decoded = []
        }
        cache.withLock { $0 = decoded }
        return decoded
    }

    private func scheduleWrite(_ stats: [UsageStat]) {
        pendingSnapshot.withLock { $0 = stats }
        writeQueue.async { [pendingSnapshot] in
            // A burst of dictations collapses into one write: the first job takes the newest
            // snapshot and the jobs behind it find nothing left to do.
            guard let snapshot = pendingSnapshot.withLock({ value -> [UsageStat]? in
                defer { value = nil }
                return value
            }) else { return }
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            UserDefaults.standard.set(data, forKey: UsageTrackingService.storageKey)
        }
    }
}
