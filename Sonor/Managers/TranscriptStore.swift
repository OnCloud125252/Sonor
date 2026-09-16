import Foundation
import Combine
import SwiftUI

/// Holds the text that the HUD transcript panel draws.
///
/// It stands apart from `AppController` for the same reason as `AudioLevelStore`: live text
/// arrives many times per second, and only the panel may redraw when it does.
@MainActor
final class TranscriptStore: ObservableObject {

    enum Stage: Equatable {
        case hidden
        /// The user still speaks. `liveText` holds the words from the preview pass.
        case listening
        /// The transcript is final. `segments` hold the assistant edit on top of it.
        case edited
    }

    /// How long a finished edit stays on screen, so the user can read what changed.
    static let lingerSeconds: Double = 3.0
    /// How long a plain transcript stays. There is no edit to read, so it goes sooner.
    static let shortLingerSeconds: Double = 1.0

    /// How long the panel waits before it empties itself. Read after `markFinished()`.
    private(set) var activeLingerSeconds: Double = 0

    @Published private(set) var stage: Stage = .hidden
    /// The opening part of the live text that two preview passes agreed on.
    @Published private(set) var liveSettledText: String = ""
    /// The end of the live text, which the next pass can still change.
    @Published private(set) var liveMovingText: String = ""
    @Published private(set) var segments: [TextDiffSegment] = []

    /// Reports when the panel switches between empty and not empty.
    ///
    /// The HUD needs this one fact to hold itself open. It listens through this callback
    /// instead of observing the store, because a store update arrives with every new word and
    /// would redraw the whole HUD each time.
    var onVisibilityChange: ((Bool) -> Void)?

    private var rawText: String = ""
    private var previousLiveText: String = ""
    private var lingerTask: Task<Void, Never>?
    private var lastReportedVisibility = false
    /// The recording stopped, so a preview pass that lands late must not open the panel.
    private var acceptsLiveText = false
    /// The assistant reports its text from a stream, so a late partial update can arrive after
    /// the finished one. Such an update must not paint over the finished diff.
    private var isAssistantFinished = false

    var hasContent: Bool {
        switch stage {
        case .hidden:
            return false
        case .listening:
            return !liveSettledText.isEmpty || !liveMovingText.isEmpty
        case .edited:
            return !segments.isEmpty
        }
    }

    /// True while the assistant rewrote at least one word.
    var hasEdit: Bool {
        segments.contains { $0.kind != .kept }
    }

    func startListening() {
        lingerTask?.cancel()
        lingerTask = nil
        stage = .listening
        liveSettledText = ""
        liveMovingText = ""
        previousLiveText = ""
        segments = []
        rawText = ""
        isAssistantFinished = false
        acceptsLiveText = true
        reportVisibility()
    }

    /// The user stopped talking. Words already on screen stay while the big model runs.
    ///
    /// A short sentence can end before the first preview pass returns. Without this the panel
    /// would open after the recording stopped, which reads as a glitch.
    func stopListening() {
        acceptsLiveText = false
        // The dim tail means "the next pass can still change these words". No pass runs after
        // the recording stops, so the whole preview is as settled as it will ever be.
        liveSettledText += liveMovingText
        liveMovingText = ""
    }

    func updateLive(_ text: String) {
        guard stage == .listening, acceptsLiveText else { return }
        // The engine reads the whole window again on every pass, so the last words keep
        // moving. The part that two passes agree on is drawn solid, the rest is drawn dim.
        let settled = TextDiff.stablePrefix(previousLiveText, text)
        previousLiveText = text
        liveSettledText = settled
        liveMovingText = String(text.dropFirst(settled.count))
        reportVisibility()
    }

    /// The engine returned the final words. The panel shows them plain until the assistant edits.
    func showTranscript(_ text: String) {
        lingerTask?.cancel()
        lingerTask = nil
        rawText = text
        stage = .edited
        acceptsLiveText = false
        liveSettledText = ""
        liveMovingText = ""
        previousLiveText = ""
        isAssistantFinished = false
        segments = text.isEmpty ? [] : [TextDiffSegment(id: 0, text: text, kind: .kept)]
        reportVisibility()
    }

    /// Redraws the diff from the assistant output so far.
    func updateAssistant(_ text: String, isFinal: Bool) {
        guard stage == .edited, !isAssistantFinished else { return }
        // An empty first chunk would blank the panel. Keep the transcript on screen instead.
        guard isFinal || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isAssistantFinished = isFinal
        segments = isFinal
            ? TextDiff.segments(from: rawText, to: text)
            : TextDiff.partialSegments(from: rawText, to: text)
        reportVisibility()
    }

    /// Starts the countdown that empties the panel.
    func markFinished() {
        guard hasContent else {
            activeLingerSeconds = 0
            clear()
            return
        }
        // A plain transcript holds nothing to read, so it must not keep the overlay up.
        let seconds = hasEdit ? TranscriptStore.lingerSeconds : TranscriptStore.shortLingerSeconds
        activeLingerSeconds = seconds
        lingerTask?.cancel()
        lingerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.clear()
        }
    }

    func clear() {
        lingerTask?.cancel()
        lingerTask = nil
        stage = .hidden
        acceptsLiveText = false
        activeLingerSeconds = 0
        liveSettledText = ""
        liveMovingText = ""
        previousLiveText = ""
        segments = []
        rawText = ""
        isAssistantFinished = false
        reportVisibility()
    }

    private func reportVisibility() {
        let visible = hasContent
        guard visible != lastReportedVisibility else { return }
        lastReportedVisibility = visible
        onVisibilityChange?(visible)
    }
}
