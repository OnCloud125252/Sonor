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

    @Test func resetRestoresTheBaseline() async throws {
        let store = AudioLevelStore()
        store.append(9.0)
        store.reset()
        #expect(store.levels.count == AudioLevelStore.barCapacity)
        #expect(store.levels.allSatisfy { $0 == 0.01 })
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
