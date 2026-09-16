import Testing
import Foundation
import AppKit
import CoreGraphics
@testable import Sonor

/// Guards the hotkey modifier comparison.
/// The settings screen offers function keys and arrow keys as modifier-free shortcuts, and
/// those events always carry an extra `.function` flag. Caps Lock adds `.capsLock`. Comparing
/// every device-independent flag made such shortcuts impossible to trigger.
struct HotkeyModifierTests {

    private static let functionAndArrowKeys: [CGKeyCode] = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 123, 124, 125, 126
    ]

    private func modifiers(forKey keyCode: CGKeyCode, flags: CGEventFlags) -> NSEvent.ModifierFlags? {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) else { return nil }
        event.flags = flags
        return NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            .intersection(HotkeyManager.recognizedModifiers)
    }

    @Test func recognizedSetHoldsOnlyTheStorableModifiers() {
        #expect(HotkeyManager.recognizedModifiers == [.command, .shift, .option, .control])
        #expect(!HotkeyManager.recognizedModifiers.contains(.function))
        #expect(!HotkeyManager.recognizedModifiers.contains(.capsLock))
        #expect(!HotkeyManager.recognizedModifiers.contains(.numericPad))
    }

    @Test func functionAndArrowKeysMatchAShortcutWithNoModifiers() throws {
        for keyCode in Self.functionAndArrowKeys {
            let resolved = try #require(modifiers(forKey: keyCode, flags: []))
            // A stored shortcut with no modifiers must compare equal.
            #expect(resolved == [], "key \(keyCode) reported \(resolved.rawValue)")
        }
    }

    @Test func capsLockDoesNotBreakAShortcut() throws {
        let stored: NSEvent.ModifierFlags = [.control, .option]
        let resolved = try #require(modifiers(forKey: 49, flags: [.maskAlphaShift, .maskControl, .maskAlternate]))
        #expect(resolved == stored)
    }

    @Test func nonTypingSetHoldsOnlyKeysThatProduceNoCharacter() {
        let safe = HotkeyManager.nonTypingKeyCodes
        // Function keys, arrows and navigation keys are safe to claim at any time.
        for code in [122, 120, 96, 106, 90, 123, 124, 125, 126, 115, 116, 119, 121, 63] {
            #expect(safe.contains(code), "keycode \(code) should be safe to bind bare")
        }
        // These type a character, so claiming one system wide would break the keyboard.
        for code in [0, 1, 2, 49, 36, 48, 51, 53] {
            #expect(!safe.contains(code), "keycode \(code) must not be bindable bare for start")
        }
    }

    @Test func realModifiersAreStillRequired() throws {
        let resolved = try #require(modifiers(forKey: 49, flags: [.maskControl, .maskAlternate]))
        #expect(resolved == [.control, .option])
        #expect(resolved != [.control])

        let bare = try #require(modifiers(forKey: 49, flags: []))
        #expect(bare != [.control, .option])
    }
}

/// Guards the localization cache added to speed up `t()`.
/// The cache must stay in sync with `appLanguage`, or the whole UI shows the wrong language.
@MainActor
struct LocalizationCacheTests {

    @Test func translateFollowsLanguageChanges() async throws {
        let manager = LocalizationManager.shared
        let original = manager.appLanguage
        defer { manager.appLanguage = original }

        manager.appLanguage = "en"
        #expect(manager.translate("Messages") == "Messages")

        manager.appLanguage = "zh"
        #expect(manager.translate("Messages") == "消息")

        manager.appLanguage = "de"
        #expect(manager.translate("Messages") == "Nachrichten")

        manager.appLanguage = "en"
        #expect(manager.translate("Messages") == "Messages")
    }

    @Test func unknownKeyReturnsTheKeyItself() async throws {
        let manager = LocalizationManager.shared
        let original = manager.appLanguage
        defer { manager.appLanguage = original }

        manager.appLanguage = "pl"
        #expect(manager.translate("__no_such_key__") == "__no_such_key__")
    }

    @Test func directDefaultsWriteStillUpdatesTranslation() async throws {
        let manager = LocalizationManager.shared
        let original = manager.appLanguage
        defer { manager.appLanguage = original }

        manager.appLanguage = "en"
        // Some views bind straight to UserDefaults, so the cache must follow that path too.
        UserDefaults.standard.set("ja", forKey: "appLanguage")
        UserDefaults.standard.synchronize()
        #expect(manager.translate("Messages") == "メッセージ")
    }
}

/// Guards assistant enable/disable, the default assistant and ordering.
@MainActor
struct AssistantSelectionTests {

    private func mode(_ name: String, enabled: Bool? = nil, prompt: String = "p") -> VoiceMode {
        VoiceMode(name: name, prompt: prompt, isEnabled: enabled)
    }

    private func withCleanDefault(_ body: () -> Void) {
        let original = UserDefaults.standard.string(forKey: VoiceMode.defaultModeIDKey)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: VoiceMode.defaultModeIDKey) }
            else { UserDefaults.standard.removeObject(forKey: VoiceMode.defaultModeIDKey) }
        }
        body()
    }

    @Test func assistantsSavedBeforeTheFlagStayEnabled() {
        #expect(mode("old", enabled: nil).isActive)
        #expect(mode("on", enabled: true).isActive)
        #expect(!mode("off", enabled: false).isActive)
    }

    @Test func disabledAssistantsAreHiddenButKeepTheirOrder() {
        let modes = [mode("a"), mode("b", enabled: false), mode("c")]
        #expect(VoiceMode.active(in: modes).map(\.name) == ["a", "c"])
    }

    @Test func defaultResolvesToTheChosenAssistant() {
        withCleanDefault {
            let modes = [mode("a"), mode("b"), mode("c")]
            VoiceMode.setDefaultModeID(modes[1].id)
            #expect(VoiceMode.resolveDefault(in: modes)?.name == "b")
            #expect(VoiceMode.isDefaultMode(modes[1].id))
            #expect(!VoiceMode.isDefaultMode(modes[0].id))
        }
    }

    @Test func aDisabledDefaultFallsBackToAnEnabledOne() {
        withCleanDefault {
            let modes = [mode("a", enabled: false), mode("b", enabled: false), mode("c")]
            VoiceMode.setDefaultModeID(modes[0].id)
            // Recording must never start on an assistant the user switched off.
            #expect(VoiceMode.resolveDefault(in: modes)?.name == "c")
        }
    }

    @Test func anUnknownDefaultFallsBackToTheFirstEnabledOne() {
        withCleanDefault {
            let modes = [mode("a"), mode("b")]
            UserDefaults.standard.set(UUID().uuidString, forKey: VoiceMode.defaultModeIDKey)
            #expect(VoiceMode.resolveDefault(in: modes)?.name == "a")
        }
    }

    @Test func noEnabledAssistantResolvesToNothing() {
        withCleanDefault {
            #expect(VoiceMode.resolveDefault(in: [mode("a", enabled: false)]) == nil)
            #expect(VoiceMode.resolveDefault(in: []) == nil)
        }
    }

    @Test func loadKeepsTheStoredOrder() {
        let original = UserDefaults.standard.data(forKey: "voiceModes")
        defer {
            if let original { UserDefaults.standard.set(original, forKey: "voiceModes") }
            else { UserDefaults.standard.removeObject(forKey: "voiceModes") }
        }
        // Reversed built-ins plus a custom assistant in the middle.
        var arranged = VoiceMode.defaults.reversed().map { $0 }
        arranged.insert(mode("My Assistant"), at: 2)
        UserDefaults.standard.set(try! JSONEncoder().encode(arranged), forKey: "voiceModes")

        let loaded = VoiceMode.loadAndMigrateModes()
        // Re-sorting on load would have thrown away the arrangement made in the dashboard.
        #expect(loaded.map(\.name) == arranged.map(\.name))
    }
}

/// Guards the per-assistant language model choice.
@MainActor
struct AssistantLLMTests {

    @Test func anAssistantWithoutAnOverrideFollowsTheGlobalChoice() {
        let settings = LLMSettings.shared
        let original = settings.provider
        defer { settings.provider = original }

        settings.provider = .remoteAPI
        let plain = VoiceMode(name: "a", prompt: "p")
        #expect(settings.resolved(for: plain).provider == .remoteAPI)
        #expect(settings.resolved(for: nil).provider == .remoteAPI)
    }

    @Test func anAssistantCanPinItsOwnProvider() {
        let settings = LLMSettings.shared
        let original = settings.provider
        defer { settings.provider = original }

        settings.provider = .remoteAPI
        let onDevice = VoiceMode(name: "a", prompt: "p", llmProviderOverride: LLMProvider.local.rawValue)
        #expect(settings.resolved(for: onDevice).provider == .local)
        #expect(settings.resolved(for: onDevice).label == "Gemma 3")
    }

    @Test func anAssistantCanPinItsOwnCloudModel() {
        let settings = LLMSettings.shared
        let originalModel = settings.modelName
        defer { settings.modelName = originalModel }
        settings.modelName = "global-model"

        let pinned = VoiceMode(name: "a", prompt: "p", llmProviderOverride: LLMProvider.remoteAPI.rawValue, llmModelOverride: "fast-model")
        #expect(settings.resolved(for: pinned).configuration.modelName == "fast-model")
        #expect(settings.resolved(for: pinned).label == "fast-model")

        let blank = VoiceMode(name: "b", prompt: "p", llmProviderOverride: LLMProvider.remoteAPI.rawValue, llmModelOverride: "   ")
        // Whitespace is not a model name, so the global one applies.
        #expect(settings.resolved(for: blank).configuration.modelName == "global-model")
    }

    @Test func anAssistantCanPinItsOwnTemperature() {
        let settings = LLMSettings.shared
        let original = settings.temperature
        defer { settings.temperature = original }
        settings.temperature = 0.7

        let cold = VoiceMode(name: "a", prompt: "p", llmTemperatureOverride: 0.1)
        #expect(settings.resolved(for: cold).configuration.temperature == 0.1)
        #expect(settings.resolved(for: VoiceMode(name: "b", prompt: "p")).configuration.temperature == 0.7)
    }

    @Test func cloudChoiceNeedsAUsableEndpointAndModel() {
        let settings = LLMSettings.shared
        let originalURL = settings.baseURL
        let originalModel = settings.modelName
        defer {
            settings.baseURL = originalURL
            settings.modelName = originalModel
        }

        let cloud = VoiceMode(name: "a", prompt: "p", llmProviderOverride: LLMProvider.remoteAPI.rawValue)

        settings.baseURL = "https://api.example.com/v1"
        settings.modelName = "some-model"
        #expect(settings.resolved(for: cloud).isUsable)

        settings.modelName = ""
        #expect(!settings.resolved(for: cloud).isUsable)

        settings.modelName = "some-model"
        settings.baseURL = "not a url"
        #expect(!settings.resolved(for: cloud).isUsable)
    }
}

/// Guards dictionary and snippet replacement.
/// A plain substring replace let a short entry rewrite the inside of longer words, and Swift
/// dictionary order made the result differ between runs.
struct TextCorrectionTests {

    private func replace(_ text: String, _ key: String, _ value: String) -> String {
        TextProcessingService.replaceWholeWords(in: text, of: key, with: value)
    }

    @Test func shortEntryDoesNotRewriteLongerWords() {
        #expect(replace("this is a test", "is", "IS") == "this IS a test")
        #expect(replace("classic assistant", "as", "AS") == "classic assistant")
        #expect(replace("a cat scattered", "cat", "dog") == "a dog scattered")
    }

    @Test func matchingStaysCaseInsensitive() {
        #expect(replace("Hello world", "hello", "Goodbye") == "Goodbye world")
        #expect(replace("SONOR rules", "sonor", "Sonor") == "Sonor rules")
    }

    @Test func punctuationAndBoundariesAreHandled() {
        #expect(replace("call me, ok?", "ok", "okay") == "call me, okay?")
        #expect(replace("end of line", "line", "row") == "end of row")
        #expect(replace("line first", "line", "row") == "row first")
    }

    @Test func replacementTextIsTakenLiterally() {
        // A naive regex template would treat "$1" as a capture group reference.
        #expect(replace("pay now", "pay", "$1 cost") == "$1 cost now")
        #expect(replace("a path", "path", "C:\\temp") == "a C:\\temp")
    }

    @Test func scriptsWithoutSpacesStillMatch() {
        // Chinese and Japanese have no word boundaries, so those entries must still apply.
        #expect(!TextProcessingService.supportsWordBoundaries("你好"))
        #expect(!TextProcessingService.supportsWordBoundaries("こんにちは"))
        #expect(TextProcessingService.supportsWordBoundaries("hello"))
        #expect(replace("我說你好世界", "你好", "再見") == "我說再見世界")
    }

    @Test func entriesApplyLongestFirstAndInAStableOrder() {
        let entries = ["new": "NEW", "new york": "NYC", "a": "A"]
        let ordered = TextProcessingService.orderedEntries(entries).map(\.key)
        #expect(ordered == ["new york", "new", "a"])
        // Repeating the call must give the same order every time.
        #expect(TextProcessingService.orderedEntries(entries).map(\.key) == ordered)
    }

    @Test func longerEntryWinsOverItsPrefix() {
        var text = "i love new york"
        for (key, value) in TextProcessingService.orderedEntries(["new": "NEW", "new york": "NYC"]) {
            text = TextProcessingService.replaceWholeWords(in: text, of: key, with: value)
        }
        #expect(text == "i love NYC")
    }
}

/// Guards the vectorized WAV encoder. It replaced a scalar loop that ran on the main actor.
@MainActor
struct AudioHistoryEncodingTests {

    private func tone(seconds: Double, amplitude: Float = 0.5) -> [Float] {
        let count = Int(16000 * seconds)
        return (0..<count).map { amplitude * sin(Float($0) * 0.01) }
    }

    @Test func encodesAudibleAudioToAWavContainer() async throws {
        let manager = MessageMemoryManager.shared
        let data = manager.testConvertToWAVData(samples: tone(seconds: 1.0))
        let wav = try #require(data)

        #expect(wav.count > 44)
        #expect(wav.prefix(4) == Data("RIFF".utf8))
        #expect(wav[8..<12] == Data("WAVE".utf8))

        let declaredSize = wav[40..<44].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        #expect(Int(Int32(littleEndian: declaredSize)) == wav.count - 44)
    }

    @Test func roundTripKeepsSampleCountAndShape() async throws {
        let manager = MessageMemoryManager.shared
        let wav = try #require(manager.testConvertToWAVData(samples: tone(seconds: 0.5)))
        let decoded = try #require(manager.convertWAVToSamples(data: wav))

        #expect(decoded.count == (wav.count - 44) / 2)
        // The encoder normalizes to 0.9 of full scale.
        let peak = decoded.map { abs($0) }.max() ?? 0
        #expect(peak > 0.85 && peak <= 1.0)
        #expect(decoded.allSatisfy { $0.isFinite })
    }

    @Test func silenceProducesNoRecording() async throws {
        let manager = MessageMemoryManager.shared
        // A run of pure digital silence has no audible chunk, so there is nothing to store.
        #expect(manager.testConvertToWAVData(samples: [Float](repeating: 0, count: 16000)) == nil)
    }

    @Test func inputShorterThanOneChunkIsRejected() async throws {
        let manager = MessageMemoryManager.shared
        #expect(manager.testConvertToWAVData(samples: [Float](repeating: 0.5, count: 100)) == nil)
        #expect(manager.testConvertToWAVData(samples: []) == nil)
    }
}

/// Guards the waveform buffer that the HUD renders at 20 Hz.
@MainActor
struct AudioLevelStoreTests {

    @Test func bufferStaysAtFixedCapacity() async throws {
        let store = AudioLevelStore()
        #expect(store.levels.count == AudioLevelStore.barCapacity)

        for value in 0..<500 {
            store.append(Float(value))
        }
        #expect(store.levels.count == AudioLevelStore.barCapacity)
        #expect(store.levels.last == 499)
    }

    @Test func aBarRisesAtOnce() {
        // A syllable starts fast. The bar has to be there on the very next draw.
        #expect(AudioLevelStore.nextValue(previous: 0, target: 1) == 1)
        #expect(AudioLevelStore.nextValue(previous: 0.2, target: 0.9) == 0.9)
    }

    @Test func aBarFallsSlowly() {
        let next = AudioLevelStore.nextValue(previous: 1, target: 0)
        #expect(next < 1)
        #expect(next > 0.7)
    }

    @Test func aBarReachesTheFloorInTheReleaseTime() {
        var value: Float = 1
        let ticks = Int((AudioLevelStore.releaseSeconds / AudioLevelStore.tickSeconds).rounded(.up))
        for _ in 0..<ticks {
            value = AudioLevelStore.nextValue(previous: value, target: 0)
        }
        #expect(value == 0)
    }

    @Test func aShortGapDoesNotDropTheBarToTheFloor() {
        // One quiet reading between two syllables used to cut the waveform into separate
        // spikes. After 50 milliseconds of quiet the bar still stands.
        let value = AudioLevelStore.nextValue(previous: 0.8, target: 0)
        #expect(value > 0.5)
    }

    @Test func resetRestoresTheBaseline() async throws {
        let store = AudioLevelStore()
        store.append(9.0)
        store.reset()
        #expect(store.levels.count == AudioLevelStore.barCapacity)
        // The store holds bar values from 0 to 1, so an empty waveform is a flat line.
        #expect(store.levels.allSatisfy { $0 == 0 })
    }
}

/// Guards the on-demand media listener.
/// The MediaRemote adapter is a resident perl child process. It used to start at launch for
/// every user and stay alive for the whole session, even when no assistant ever paused media.
struct MediaListenerTests {

    private func mode(_ name: String, behavior: AudioBehavior?, enabled: Bool? = nil) -> VoiceMode {
        VoiceMode(name: name, prompt: "", audioBehavior: behavior, isEnabled: enabled)
    }

    @Test func noAssistantPausesMediaSoTheHelperStaysOff() {
        let modes = [mode("a", behavior: .keep), mode("b", behavior: .mute), mode("c", behavior: nil)]
        #expect(!MediaControlService.needsMediaListener(for: modes))
        #expect(!MediaControlService.needsMediaListener(for: []))
    }

    @Test func aPausingAssistantTurnsTheHelperOn() {
        #expect(MediaControlService.needsMediaListener(for: [mode("a", behavior: .keep), mode("b", behavior: .pause)]))
        #expect(MediaControlService.needsMediaListener(for: [mode("a", behavior: .muteAndPause)]))
    }

    @Test func aDisabledPausingAssistantDoesNotCount() {
        let modes = [mode("a", behavior: .keep), mode("b", behavior: .muteAndPause, enabled: false)]
        #expect(!MediaControlService.needsMediaListener(for: modes))
    }
}

/// Guards the word diff that the HUD transcript panel draws.
/// The panel must show exactly what the assistant changed, so a wrong merge would tell the
/// user that untouched words were rewritten.
struct TextDiffTests {

    private func rendered(_ segments: [TextDiffSegment]) -> String {
        segments.map { segment in
            switch segment.kind {
            case .kept: return segment.text
            case .added: return "+[\(segment.text)]"
            case .removed: return "-[\(segment.text)]"
            }
        }.joined(separator: " ")
    }

    @Test func identicalTextIsOneKeptRun() {
        let segments = TextDiff.segments(from: "hello there world", to: "hello there world")
        #expect(segments.count == 1)
        #expect(segments[0].kind == .kept)
        #expect(segments[0].text == "hello there world")
    }

    @Test func emptyTextMakesNoSegments() {
        #expect(TextDiff.segments(from: "", to: "").isEmpty)
    }

    @Test func aReplacedWordShowsTheOldWordBeforeTheNewOne() {
        let segments = TextDiff.segments(from: "send it fast", to: "send it quickly")
        #expect(rendered(segments) == "send it -[fast] +[quickly]")
    }

    @Test func addedWordsAreMarkedAdded() {
        let segments = TextDiff.segments(from: "please call me", to: "please call me back today")
        #expect(rendered(segments) == "please call me +[back today]")
    }

    @Test func removedWordsAreMarkedRemoved() {
        let segments = TextDiff.segments(from: "um so I think um yes", to: "so I think yes")
        #expect(rendered(segments) == "-[um] so I think -[um] yes")
    }

    @Test func neighborWordsOfTheSameKindMergeIntoOneRun() {
        let segments = TextDiff.segments(from: "a b c d", to: "a x y d")
        #expect(rendered(segments) == "a -[b c] +[x y] d")
        #expect(segments.count == 4)
    }

    @Test func segmentIdentifiersAreUniqueAndOrdered() {
        let segments = TextDiff.segments(from: "one two three", to: "one four three")
        #expect(segments.map(\.id) == Array(0..<segments.count))
    }

    @Test func writingTextDropsTheRedTailThatTheAssistantHasNotReached() {
        // The assistant wrote two words of nine so far. The rest of the transcript is not
        // deleted, it is simply not written yet, so it must stay plain.
        let partial = TextDiff.partialSegments(from: "um so send it to mark tomorrow morning please", to: "Please send")
        #expect(rendered(partial) == "-[um so] +[Please] send")

        let more = TextDiff.partialSegments(from: "um so send it to mark tomorrow morning please", to: "Please send it to Mark")
        #expect(rendered(more) == "-[um so] +[Please] send it to Mark")
    }

    @Test func theFinishedDiffStillShowsEveryRemovedWord() {
        let final = TextDiff.segments(from: "um so send it to mark please", to: "Please send it to Mark.")
        #expect(rendered(final) == "-[um so] +[Please] send it to Mark. -[please]")
    }

    @Test func trimmingKeepsTextThatEndsWithKeptOrAddedWords() {
        let segments = TextDiff.segments(from: "one two", to: "one three")
        #expect(TextDiff.trimmingTrailingRemovals(segments).count == segments.count)
    }

    @Test func aFixedCaseOrFixedPunctuationIsNotAnEdit() {
        // The assistant capitalizes and adds a period in almost every sentence. Marking each
        // one would paint the whole panel and hide the real changes.
        let segments = TextDiff.segments(from: "send it to mark", to: "Send it to Mark.")
        #expect(rendered(segments) == "Send it to Mark.")
        #expect(segments.count == 1)
        #expect(segments[0].kind == .kept)
    }

    @Test func theAssistantSpellingIsTheOneOnScreen() {
        let segments = TextDiff.segments(from: "call mark now", to: "Call Mark now")
        #expect(segments.map(\.text) == ["Call Mark now"])
    }

    // Chinese writes without spaces. One whole sentence as a single unit would mark every
    // edit as a full rewrite, which is what the first version did.

    @Test func chineseSplitsPerCharacter() {
        let segments = TextDiff.segments(from: "這是我做的一個诶語音輸入法", to: "這是我做的一個語音輸入法")
        #expect(rendered(segments) == "這是我做的一個 -[诶] 語音輸入法")
    }

    @Test func chineseKeepsMostOfTheSentencePlain() {
        let segments = TextDiff.segments(from: "你好這是我做的軟體", to: "你好，這是我做的軟體。")
        // Only punctuation moved, so nothing carries a mark.
        #expect(segments.count == 1)
        #expect(segments[0].kind == .kept)
    }

    @Test func chineseRunsJoinWithoutSpaces() {
        let segments = TextDiff.segments(from: "我喜歡貓", to: "我喜歡狗")
        #expect(rendered(segments) == "我喜歡 -[貓] +[狗]")
        #expect(segments.allSatisfy { !$0.leadingSpace })
    }

    @Test func englishInsideChineseStaysOneWord() {
        let words = TextDiff.words(in: "用 Swift 寫的")
        #expect(words.map(\.text) == ["用", "Swift", "寫", "的"])
        #expect(words[1].hasLeadingSpace)
        #expect(words[2].hasLeadingSpace)
        #expect(!words[3].hasLeadingSpace)
    }

    @Test func englishKeepsItsSpaces() {
        let segments = TextDiff.segments(from: "send it fast", to: "send it now")
        #expect(segments[0].text == "send it")
        #expect(!segments[0].leadingSpace)
        #expect(segments[1].leadingSpace)
    }

    @Test func englishRunsNeverTouchEachOther() {
        // "Please" opens the new text, so it carries no space of its own. It still needs a
        // gap after the removed words, or the two runs read as one word.
        let segments = TextDiff.segments(from: "um so send it", to: "Please send it")
        #expect(rendered(segments) == "-[um so] +[Please] send it")
        #expect(segments[1].kind == .added)
        #expect(segments[1].leadingSpace)
    }

    @Test func chineseRunsStillTouchEachOther() {
        let segments = TextDiff.segments(from: "嗯這是軟體", to: "這是軟體")
        #expect(segments.allSatisfy { !$0.leadingSpace })
    }
}

/// Guards the settled part of the live preview text.
/// The engine reads the whole window again on every pass, so the end of the text keeps moving.
/// Only the part that two passes agree on may look final.
struct LivePreviewStabilityTests {

    @Test func theFirstPassSettlesNothing() {
        #expect(TextDiff.stablePrefix("", "你好這是") == "")
    }

    @Test func twoEqualPassesSettleEverything() {
        #expect(TextDiff.stablePrefix("你好這是", "你好這是") == "你好這是")
    }

    @Test func onlyTheAgreedOpeningSettles() {
        #expect(TextDiff.stablePrefix("你好這是我做", "你好這是我想") == "你好這是我")
    }

    @Test func aGrowingPassSettlesTheOldPart() {
        #expect(TextDiff.stablePrefix("hello there", "hello there world") == "hello there")
    }

    @Test func aHalfWrittenWordDoesNotSettle() {
        // "wor" is not "world", so the last word stays unsettled instead of being cut in half.
        #expect(TextDiff.stablePrefix("hello wor", "hello world") == "hello")
    }

    @Test func aMovedCommaDoesNotUnsettleTheWholeSentence() {
        // The engine puts the comma in a new place on almost every pass. A strict test would
        // then draw the whole sentence dim, which is what the first version did.
        #expect(TextDiff.stablePrefix("你好這是我做的", "你好，這是我做的") == "你好，這是我做的")
        #expect(TextDiff.stablePrefix("hello there", "Hello, there") == "Hello, there")
    }
}

/// Guards the store behind the HUD transcript panel.
/// The HUD holds itself open from the visibility callback, so a missed report would leave the
/// overlay on screen forever, or hide the assistant edit before the user can read it.
@MainActor
struct TranscriptStoreTests {

    @Test func aFreshStoreShowsNothing() {
        let store = TranscriptStore()
        #expect(store.stage == .hidden)
        #expect(!store.hasContent)
        #expect(!store.hasEdit)
    }

    @Test func listeningStaysEmptyUntilTheFirstWordsArrive() {
        let store = TranscriptStore()
        store.startListening()
        #expect(store.stage == .listening)
        #expect(!store.hasContent)

        store.updateLive("hello there")
        #expect(store.hasContent)
        // The first pass has nothing to agree with, so every word is still moving.
        #expect(store.liveSettledText.isEmpty)
        #expect(store.liveMovingText == "hello there")

        store.updateLive("hello there world")
        #expect(store.liveSettledText == "hello there")
        #expect(store.liveMovingText == " world")
    }

    @Test func stoppingSettlesEveryWordOnScreen() {
        let store = TranscriptStore()
        store.startListening()
        store.updateLive("hello there")
        store.updateLive("hello there world")
        #expect(store.liveSettledText == "hello there")
        #expect(store.liveMovingText == " world")

        store.stopListening()
        // No pass runs after the recording stops, so no word is still moving.
        #expect(store.liveSettledText == "hello there world")
        #expect(store.liveMovingText.isEmpty)
        #expect(store.hasContent)
    }

    @Test func livePreviewCannotOverwriteTheFinalTranscript() {
        let store = TranscriptStore()
        store.startListening()
        store.showTranscript("the final words")
        store.updateLive("a late preview pass")

        #expect(store.stage == .edited)
        #expect(store.liveSettledText.isEmpty)
        #expect(store.liveMovingText.isEmpty)
        #expect(store.segments.map(\.text) == ["the final words"])
    }

    @Test func theTranscriptAloneCountsAsNoEdit() {
        let store = TranscriptStore()
        store.showTranscript("send it fast")
        #expect(store.hasContent)
        #expect(!store.hasEdit)
    }

    @Test func theAssistantOutputBecomesADiff() {
        let store = TranscriptStore()
        store.showTranscript("send it fast")
        store.updateAssistant("Send it quickly.", isFinal: true)

        #expect(store.hasEdit)
        // "Send" only changed case, so it stays plain. Only the real word swap carries a mark.
        #expect(store.segments.contains { $0.kind == .kept && $0.text == "Send it" })
        #expect(store.segments.contains { $0.kind == .removed && $0.text == "fast" })
        #expect(store.segments.contains { $0.kind == .added && $0.text == "quickly." })
    }

    @Test func partialAssistantOutputHidesTheWordsItHasNotReached() {
        let store = TranscriptStore()
        store.showTranscript("please call me back")
        store.updateAssistant("please call", isFinal: false)
        #expect(!store.segments.contains { $0.kind == .removed })

        store.updateAssistant("please call", isFinal: true)
        #expect(store.segments.contains { $0.kind == .removed && $0.text == "me back" })
    }

    @Test func theAssistantOutputIsIgnoredWhileTheUserStillSpeaks() {
        let store = TranscriptStore()
        store.startListening()
        store.updateAssistant("anything", isFinal: true)
        #expect(store.stage == .listening)
        #expect(store.segments.isEmpty)
    }

    @Test func visibilityIsReportedOncePerChange() {
        let store = TranscriptStore()
        var reports: [Bool] = []
        store.onVisibilityChange = { reports.append($0) }

        store.startListening()
        store.updateLive("one")
        store.updateLive("one two")
        store.showTranscript("one two")
        store.updateAssistant("One two.", isFinal: true)
        store.clear()

        #expect(reports == [true, false])
    }

    @Test func clearingEmptiesEveryField() {
        let store = TranscriptStore()
        store.showTranscript("some words")
        store.updateAssistant("Some words.", isFinal: true)
        store.clear()

        #expect(store.stage == .hidden)
        #expect(store.segments.isEmpty)
        #expect(store.liveSettledText.isEmpty)
        #expect(store.liveMovingText.isEmpty)
        #expect(!store.hasContent)
    }

    @Test func aFinishedPanelWithNoTextHidesAtOnce() {
        let store = TranscriptStore()
        store.startListening()
        store.markFinished()
        #expect(store.stage == .hidden)
    }

    @Test func aFinishedPanelWithTextWaitsForTheReader() async throws {
        let store = TranscriptStore()
        store.showTranscript("some words")
        store.markFinished()
        // The countdown runs for `lingerSeconds`, so the text is still there right after.
        try await Task.sleep(for: .milliseconds(120))
        #expect(store.hasContent)
    }
}

/// Guards the order of the assistant stream reports.
/// The stream reports from background tasks, so a partial report can arrive after the final
/// one. The finished diff must win.
@MainActor
struct TranscriptStoreOrderTests {

    @Test func aLatePartialReportCannotOverwriteTheFinishedDiff() {
        let store = TranscriptStore()
        store.showTranscript("please call me back")
        store.updateAssistant("Please call me back.", isFinal: true)
        let finished = store.segments

        store.updateAssistant("Please call", isFinal: false)
        #expect(store.segments == finished)
    }

    @Test func aNewDictationAcceptsTheAssistantAgain() {
        let store = TranscriptStore()
        store.showTranscript("one")
        store.updateAssistant("One.", isFinal: true)

        store.showTranscript("two words")
        store.updateAssistant("Two sentences", isFinal: false)
        #expect(store.segments.contains { $0.kind == .added && $0.text == "sentences" })
    }
}

/// Guards the microphone sensitivity math.
/// The meter maps a level to a bar position. A wrong map puts every normal voice in the first
/// tenth of the bar, and the mark becomes impossible to set.
struct VoiceActivityTests {

    @Test func silenceSitsAtTheLeftEdge() {
        #expect(VoiceActivity.meterValue(forLevel: 0) == 0)
    }

    @Test func fullScaleSitsAtTheRightEdge() {
        #expect(VoiceActivity.meterValue(forLevel: 1.0) == 1.0)
    }

    @Test func aNormalVoiceSitsNearTheMiddle() {
        // A speaking voice reads about 0.02. It has to land where a mark is easy to place.
        let value = VoiceActivity.meterValue(forLevel: 0.02)
        #expect(value > 0.3)
        #expect(value < 0.6)
    }

    @Test func roomNoiseSitsWellLeftOfAVoice() {
        #expect(VoiceActivity.meterValue(forLevel: 0.002) < VoiceActivity.meterValue(forLevel: 0.02))
    }

    @Test func theMapRunsBothWays() {
        for value in [0.0, 0.25, 0.35, 0.5, 0.9, 1.0] {
            let level = VoiceActivity.level(forMeterValue: value)
            #expect(abs(VoiceActivity.meterValue(forLevel: level) - value) < 0.0001)
        }
    }

    @Test func aMarkOutsideTheBarIsPulledBack() {
        #expect(VoiceActivity.level(forMeterValue: -2) == VoiceActivity.level(forMeterValue: 0))
        #expect(VoiceActivity.level(forMeterValue: 5) == VoiceActivity.level(forMeterValue: 1))
    }

    @Test func aManualMarkWinsOverTheRoom() {
        let manual: Float = 0.05
        #expect(VoiceActivity.threshold(manual: manual, noiseFloor: 0.2) == manual)
    }

    @Test func automaticModeFollowsTheRoom() {
        let quiet = VoiceActivity.threshold(manual: nil, noiseFloor: 0.0001)
        #expect(quiet == VoiceActivity.minimumLevel)

        let loud = VoiceActivity.threshold(manual: nil, noiseFloor: 0.01)
        #expect(loud == 0.01 * VoiceActivity.voiceOverNoise)
    }

    @Test func theSavedSettingReadsBackAsWritten() {
        let defaults = UserDefaults(suiteName: "VoiceActivityTests")!
        defaults.removePersistentDomain(forName: "VoiceActivityTests")
        defer { defaults.removePersistentDomain(forName: "VoiceActivityTests") }

        #expect(VoiceActivity.savedManualLevel(in: defaults) == nil)

        defaults.set(VoiceActivity.Mode.manual.rawValue, forKey: VoiceActivity.modeKey)
        defaults.set(0.5, forKey: VoiceActivity.levelKey)
        let level = VoiceActivity.savedManualLevel(in: defaults)
        #expect(level != nil)
        #expect(abs(VoiceActivity.meterValue(forLevel: level ?? 0) - 0.5) < 0.0001)

        defaults.set(VoiceActivity.Mode.automatic.rawValue, forKey: VoiceActivity.modeKey)
        #expect(VoiceActivity.savedManualLevel(in: defaults) == nil)
    }
}

/// Guards the waveform bar height.
/// A straight line from level to height reached the top at about 0.11, which a normal speaking
/// voice passes on every syllable. The waveform then stayed pinned for the whole sentence.
struct WaveformBarTests {

    @Test func anEmptyValueDrawsTheShortestBar() {
        #expect(AudioWavesView.barHeight(for: 0) == AudioWavesView.minimumBarHeight)
    }

    @Test func aBarNeverTouchesTheGlass() {
        for value in [Float(-1), 0, 0.5, 1.0, 4.0] {
            let height = AudioWavesView.barHeight(for: value)
            #expect(height >= AudioWavesView.minimumBarHeight)
            #expect(height <= AudioWavesView.maximumBarHeight)
        }
        // The control line is 40 points tall. The tallest bar has to leave a margin.
        #expect(AudioWavesView.maximumBarHeight < 40)
    }
}

/// Guards the curve that turns a microphone reading into a bar height.
/// A plain logarithm spent most of the bar on room noise, so the bars never fell to the floor
/// between words, and it spent the rest on shouting, so one loud syllable spiked far above the
/// others. Speech lives in the middle, and that is where the bar has to move.
struct WaveformCurveTests {

    private func level(decibels: Double) -> Float {
        Float(pow(10, decibels / 20))
    }

    @Test func silenceIsFlat() {
        #expect(VoiceActivity.waveformValue(forLevel: 0) == 0)
    }

    @Test func aQuietRoomStaysOnTheFloor() {
        // Room noise reads about 0.001 to 0.003. It has to draw a line, not a bar.
        #expect(VoiceActivity.waveformValue(forLevel: 0.001) < 0.02)
        #expect(VoiceActivity.waveformValue(forLevel: 0.003) < 0.02)
    }

    @Test func aShoutDoesNotSpikeAboveTheRest() {
        let loud = VoiceActivity.waveformValue(forLevel: 0.3)
        let louder = VoiceActivity.waveformValue(forLevel: 0.9)
        #expect(loud > 0.97)
        #expect(louder - loud < 0.03)
    }

    @Test func normalSpeechUsesTheMovingPartOfTheBar() {
        for reading in [Float(0.02), 0.04, 0.07] {
            let value = VoiceActivity.waveformValue(forLevel: reading)
            #expect(value > 0.15)
            #expect(value < 0.95)
        }
    }

    @Test func theCurveMovesMostInTheSpeechRange() {
        func step(from start: Double, to end: Double) -> Double {
            VoiceActivity.waveformValue(forLevel: level(decibels: end))
                - VoiceActivity.waveformValue(forLevel: level(decibels: start))
        }
        // The same five decibels, measured low, in the middle, and high.
        let quiet = step(from: -44, to: -39)
        let middle = step(from: -31, to: -26)
        let loud = step(from: -17, to: -12)

        #expect(middle > quiet * 2)
        #expect(middle > loud * 2)
    }

    @Test func louderNeverDrawsShorter() {
        var previous: Double = -1
        for reading in [Float(0), 0.001, 0.005, 0.02, 0.08, 0.3, 1.0] {
            let value = VoiceActivity.waveformValue(forLevel: reading)
            #expect(value >= previous)
            previous = value
        }
    }
}

/// Guards the window the live preview reads.
/// A speaker who stops to think used to push their own opening sentence out of the window,
/// because the silence filled it. The words already on screen then disappeared.
struct PreviewWindowTests {

    private static let sampleRate = 16_000
    private static let threshold: Float = 0.01

    /// A run of loud samples. The value alternates so the RMS is the value itself.
    private func speech(seconds: Double, level: Float = 0.2) -> [Float] {
        let count = Int(seconds * Double(Self.sampleRate))
        return (0..<count).map { $0.isMultiple(of: 2) ? level : -level }
    }

    private func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(Self.sampleRate)))
    }

    private func loudCount(_ samples: [Float]) -> Int {
        samples.filter { abs($0) > Self.threshold }.count
    }

    private func recent(_ samples: [Float], seconds: Double) -> [Float] {
        AudioManager.recentSpeech(
            in: samples,
            maxCount: Int(seconds * Double(Self.sampleRate)),
            sampleRate: Self.sampleRate,
            threshold: Self.threshold
        )
    }

    @Test func plainSpeechComesBackNewestFirstAndInOrder() {
        // Ten seconds of speech, a four second window. Only the newest four seconds fit.
        let result = recent(speech(seconds: 10), seconds: 4)
        #expect(result.count <= 4 * Self.sampleRate)
        #expect(result.count > 3 * Self.sampleRate)
        #expect(loudCount(result) == result.count)
    }

    @Test func aLongPauseDoesNotPushOutTheOpeningWords() {
        // Three seconds of speech, twelve seconds of thinking, three more seconds of speech.
        // A plain "last ten seconds" window would hold the pause and one sentence only.
        let samples = speech(seconds: 3) + silence(seconds: 12) + speech(seconds: 3)
        let result = recent(samples, seconds: 10)

        // Both sentences survive. Six seconds of speech is 96000 samples.
        #expect(loudCount(result) > 5 * Self.sampleRate)
        #expect(result.count < samples.count)
    }

    @Test func theGapNextToTheSpeechStays() {
        // The model still has to hear where one sentence ends and the next begins.
        let samples = speech(seconds: 1) + silence(seconds: 10) + speech(seconds: 1)
        let result = recent(samples, seconds: 20)
        let quiet = result.count - loudCount(result)

        #expect(quiet > 0)
        #expect(Double(quiet) < AudioManager.keptGapSeconds * 2 * Double(Self.sampleRate))
    }

    @Test func aShortGapIsLeftAlone() {
        // A natural gap between two words is shorter than the kept length, so nothing is cut.
        let samples = speech(seconds: 1) + silence(seconds: 0.3) + speech(seconds: 1)
        let result = recent(samples, seconds: 20)
        #expect(result.count == samples.count)
    }

    @Test func audioShorterThanTheWindowComesBackWhole() {
        let samples = speech(seconds: 2)
        let result = recent(samples, seconds: 30)
        #expect(result.count == samples.count)
    }

    @Test func silenceAloneReturnsOnlyTheKeptGap() {
        let result = recent(silence(seconds: 20), seconds: 10)
        #expect(loudCount(result) == 0)
        #expect(Double(result.count) <= AudioManager.keptGapSeconds * 2 * Double(Self.sampleRate))
    }
}
