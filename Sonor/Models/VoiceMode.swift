import Foundation
import CoreGraphics

enum AudioBehavior: String, Codable, CaseIterable {
    case keep
    case mute
    case pause
    case muteAndPause
}


struct VoiceMode: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var prompt: String
    var boundAppBundleIDs: [String]
    var audioBehavior: AudioBehavior?
    var assistantType: String? 
    var passAppName: Bool?
    var passCopiedText: Bool?
    /// nil or `TranscriptionLanguage.followGlobalCode` follows the global language.
    /// Any other value is a `TranscriptionLanguage` code this assistant pins for itself.
    var language: String?
    var isBuiltIn: Bool? 
    var fallbackToClipboard: Bool? // Deprecated
    var fallbackBehavior: String? // "none", "overlay", "clipboard"
    var postPasteAction: String?
    var modelOverride: String?
    /// Optional so that assistants saved before this flag existed stay enabled.
    var isEnabled: Bool?
    /// nil follows the global choice. Otherwise an `LLMProvider` raw value.
    var llmProviderOverride: String?
    /// Cloud model for this assistant only. nil uses the model from the global settings.
    var llmModelOverride: String?
    /// Sampling temperature for this assistant only. nil uses the global value.
    var llmTemperatureOverride: Double?
    init(id: UUID = UUID(), name: String, prompt: String, boundAppBundleIDs: [String] = [], audioBehavior: AudioBehavior? = .keep, assistantType: String? = "dictation", passAppName: Bool? = true, passCopiedText: Bool? = true, language: String? = nil, isBuiltIn: Bool? = false, fallbackBehavior: String? = "overlay", postPasteAction: String? = "none", modelOverride: String? = nil, fallbackToClipboard: Bool? = nil, isEnabled: Bool? = nil, llmProviderOverride: String? = nil, llmModelOverride: String? = nil, llmTemperatureOverride: Double? = nil) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.boundAppBundleIDs = boundAppBundleIDs
        self.audioBehavior = audioBehavior
        self.assistantType = assistantType
        self.passAppName = passAppName
        self.passCopiedText = passCopiedText
        self.language = language
        self.isBuiltIn = isBuiltIn
        self.fallbackBehavior = fallbackBehavior
        self.postPasteAction = postPasteAction
        self.modelOverride = modelOverride
        self.fallbackToClipboard = fallbackToClipboard
        self.isEnabled = isEnabled
        self.llmProviderOverride = llmProviderOverride
        self.llmModelOverride = llmModelOverride
        self.llmTemperatureOverride = llmTemperatureOverride
    }
    /// An assistant the user switched off stays saved but never appears in the picker.
    var isActive: Bool {
        isEnabled ?? true
    }
    var isBuiltInMode: Bool {
        if isBuiltIn == true {
            return true
        }
        let builtInNames = ["Pure Text", "Text Smoothing", "Formal Style", "Casual Style", "Edit & Create"]
        return builtInNames.contains(name)
    }
    static let defaults: [VoiceMode] = [
        VoiceMode(name: "Pure Text", prompt: "", boundAppBundleIDs: [], audioBehavior: .keep, assistantType: "dictation", isBuiltIn: true),
        VoiceMode(name: "Text Smoothing", prompt: "Your task is to clean up, smooth, and format the provided voice transcript. \n\n1. REMOVE NOISE: Fix grammar, remove filler words, and COMPLETELY DELETE abandoned ideas (only keep the final decision).\n2. FORMATTING: If the text naturally contains multiple tasks, steps, or items, format them as a clear vertical list. Otherwise, use highly readable paragraphs.\n\nCRITICAL RULE: NEVER add new information, IT solutions, or AI filler. Output EXACTLY and ONLY the final polished text.", boundAppBundleIDs: [], audioBehavior: .keep, assistantType: "dictation", isBuiltIn: true),
        VoiceMode(name: "Formal Style", prompt: "Rewrite the following text into a professional, elegant, and formal style.\nCRITICAL RULE: Do NOT transform regular text into an email. Intelligently detect if the provided text is already formatted as an email. If it is NOT an email, strictly preserve its original format without adding any email-specific elements like greetings or farewells. If it IS an email, simply elevate its tone to be more formal while keeping its existing structure.", boundAppBundleIDs: [], audioBehavior: .keep, assistantType: "dictation", isBuiltIn: true),
        VoiceMode(name: "Casual Style", prompt: "Rewrite the raw text into a casual, relaxed, and conversational style. \nYou may use common colloquialisms, but do not exaggerate or make it sound unnatural. Keep it friendly and laid-back.\n\nCRITICAL RULES:\n1. FORMAT INTEGRITY: \n   - IF the input text includes a subject, greeting, or sign-off, maintain an e-mail/message structure. However, make these elements casual too (e.g., change \"Dear Team\" to \"Hey everyone\", or \"Sincerely\" to \"Cheers\" / \"Best\").\n   - IF the input text is a note or general statement without greetings, do NOT add a subject, greeting, or sign-off.\n2. CONCISENESS: Return ONLY the rewritten text. No introductions, no explanations, and no filler text.", boundAppBundleIDs: [], audioBehavior: .keep, assistantType: "dictation", isBuiltIn: true),
        VoiceMode(name: "Edit & Create", prompt: "Act as an expert copywriter. Execute the user's command to create new content or edit existing context, ensuring a highly professional and appropriate tone.", boundAppBundleIDs: [], audioBehavior: .keep, assistantType: "edit", isBuiltIn: true)
    ]
    static func loadAndMigrateModes() -> [VoiceMode] {
        guard let voiceModesData = UserDefaults.standard.data(forKey: "voiceModes") else {
            save(defaults)
            return defaults
        }
        var modes = [VoiceMode]()
        if let decoded = try? JSONDecoder().decode([VoiceMode].self, from: voiceModesData) {
            modes = decoded
        } else {
            struct OldVoiceMode: Codable {
                var id: UUID
                var name: String
                var prompt: String
                var boundAppBundleIDs: [String]
                var pauseMusic: Bool
                var assistantType: String?
                var passAppName: Bool?
                var passCopiedText: Bool?
                var language: String?
                var isBuiltIn: Bool?
                var modelOverride: String?
            }
            if let oldModes = try? JSONDecoder().decode([OldVoiceMode].self, from: voiceModesData) {
                modes = oldModes.map { old in
                    VoiceMode(
                        id: old.id,
                        name: old.name,
                        prompt: old.prompt,
                        boundAppBundleIDs: old.boundAppBundleIDs,
                        audioBehavior: old.pauseMusic ? .mute : .keep,
                        assistantType: old.assistantType,
                        passAppName: old.passAppName,
                        passCopiedText: old.passCopiedText,
                        language: old.language,
                        isBuiltIn: old.isBuiltIn,
                        fallbackBehavior: "overlay",
                        postPasteAction: "none",
                        modelOverride: old.modelOverride
                    )
                }
            } else {
                save(defaults)
                return defaults
            }
        }
        
        for i in 0..<modes.count {
            if modes[i].fallbackBehavior == nil {
                if modes[i].fallbackToClipboard == true {
                    modes[i].fallbackBehavior = "clipboard"
                } else {
                    modes[i].fallbackBehavior = "overlay"
                }
            }
            // Every assistant used to be born with `auto`, so that value cannot be read as a
            // deliberate choice. Clearing it lets the global language reach an assistant the
            // user never edited. The picker can still pin `auto` afterwards.
            if modes[i].language == TranscriptionLanguage.automaticCode {
                modes[i].language = TranscriptionLanguage.followGlobalCode
            }
        }
        let deprecatedNames = ["Poprawianie", "Formalny", "Strukturyzowana notatka", "Structured Note", "Notatka markdown", "Notatka Markdown", "Markdown Note"]
        modes.removeAll(where: { deprecatedNames.contains($0.name) })
        
        let aliases: [String: [String]] = [
            "Pure Text": ["Raw Output", "Zwykły output", "Czysty tekst"],
            "Text Smoothing": ["Wygładzanie tekstu"],
            "Formal Style": ["Formalny e-mail", "Formal Email", "Styl formalny"],
            "Casual Style": ["Luźny styl"],
            "Edit & Create": ["Edycja i tworzenie"]
        ]
        
        for (defaultIndex, defaultMode) in defaults.enumerated() {
            let targetName = defaultMode.name
            var namesToMatch = aliases[targetName] ?? []
            namesToMatch.append(targetName)
            
            let matchingIndices = modes.indices.filter { namesToMatch.contains(modes[$0].name) }
            
            if let firstIndex = matchingIndices.first {
                modes[firstIndex].name = targetName
                modes[firstIndex].isBuiltIn = true
                modes[firstIndex].prompt = defaultMode.prompt
                
                // Remove all subsequent duplicates
                for duplicateIndex in matchingIndices.dropFirst().reversed() {
                    modes.remove(at: duplicateIndex)
                }
            } else {
                let insertIndex = min(modes.count, defaultIndex)
                modes.insert(defaultMode, at: insertIndex)
            }
        }

        // The list is deliberately left in its stored order. Re-sorting here would throw away
        // the order the user arranged in the dashboard on every single load.
        save(modes)
        return modes
    }
    private static func save(_ modes: [VoiceMode]) {
        if let data = try? JSONEncoder().encode(modes) {
            UserDefaults.standard.set(data, forKey: "voiceModes")
        }
    }
}

// MARK: - Selection

extension VoiceMode {
    static let defaultModeIDKey = "defaultModeID"

    /// Assistants the user left switched on, in the order they arranged them.
    static func active(in modes: [VoiceMode]) -> [VoiceMode] {
        modes.filter { $0.isActive }
    }

    /// The assistant a new recording starts with.
    /// Falls back to the first enabled assistant when the chosen default was disabled or
    /// deleted, so recording never starts with an assistant the user switched off.
    static func resolveDefault(in modes: [VoiceMode]) -> VoiceMode? {
        let enabled = active(in: modes)
        let storedID = UserDefaults.standard.string(forKey: defaultModeIDKey) ?? ""
        return enabled.first(where: { $0.id.uuidString == storedID }) ?? enabled.first
    }

    static func setDefaultModeID(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: defaultModeIDKey)
    }

    static func isDefaultMode(_ id: UUID) -> Bool {
        UserDefaults.standard.string(forKey: defaultModeIDKey) == id.uuidString
    }
}
