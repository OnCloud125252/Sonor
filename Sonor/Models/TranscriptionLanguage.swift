import Foundation

/// A language the user can force on the transcription model.
///
/// Sonor keeps one global choice. An assistant may override it. The `auto` entry leaves the
/// detection to the model itself.
///
/// Each engine wants the code in its own shape, so the mapping lives here instead of being
/// repeated in every engine.
public struct TranscriptionLanguage: Identifiable, Hashable, Sendable {
    /// A BCP 47 style code, for example `en`, `zh` or `pt-BR`.
    public let code: String
    /// The name written in the language itself, so the picker stays readable to its speakers.
    public let nativeName: String
    /// The English name. A language model follows an English name more reliably than a code.
    public let englishName: String

    public var id: String { code }

    public var isAutomatic: Bool { code == Self.automaticCode }

    /// Whisper reads a plain ISO 639-1 code and has no entry for a region, so `pt-BR` has to
    /// arrive as `pt`.
    public var whisperCode: String {
        isAutomatic ? Self.automaticCode : String(code.prefix { $0 != "-" })
    }

    /// The MLX models read `nil` as a request to detect the language themselves.
    public var mlxCode: String? {
        isAutomatic ? nil : whisperCode
    }

    /// Apple Speech needs a dictation locale. `Locale` supplies a region when the code omits
    /// one. A script subtag has no dictation locale of its own, so it maps to a region Apple
    /// ships.
    public var appleLocale: Locale? {
        guard !isAutomatic else { return nil }
        let identifier = Self.appleLocaleOverrides[code] ?? code
        return Locale(identifier: identifier.replacingOccurrences(of: "-", with: "_"))
    }

    /// A short line written in the wanted script, or nil when the language has one script.
    ///
    /// Whisper writes Chinese in the simplified script by default, whatever the speaker used.
    /// Seeding `initial_prompt` with the wanted script is the documented way to steer it.
    public var scriptSeedPrompt: String? {
        switch code {
        case "zh-Hant": return "以下是繁體中文的逐字稿。"
        case "zh-Hans": return "以下是简体中文的逐字稿。"
        default: return nil
        }
    }

    private static let appleLocaleOverrides: [String: String] = [
        "zh": "zh-CN",
        "zh-Hant": "zh-TW",
        "zh-Hans": "zh-CN"
    ]
}

// MARK: - Catalog

public extension TranscriptionLanguage {
    static let automaticCode = "auto"

    /// An assistant that stores this code follows the global choice.
    static let followGlobalCode = ""

    /// Key of the global choice in `UserDefaults`.
    static let storageKey = "transcriptionLanguage"

    static let automatic = TranscriptionLanguage(code: automaticCode, nativeName: "Automatic", englishName: "Automatic")

    static let all: [TranscriptionLanguage] = [
        automatic,
        TranscriptionLanguage(code: "ar", nativeName: "العربية", englishName: "Arabic"),
        TranscriptionLanguage(code: "cs", nativeName: "Čeština", englishName: "Czech"),
        TranscriptionLanguage(code: "da", nativeName: "Dansk", englishName: "Danish"),
        TranscriptionLanguage(code: "de", nativeName: "Deutsch", englishName: "German"),
        TranscriptionLanguage(code: "el", nativeName: "Ελληνικά", englishName: "Greek"),
        TranscriptionLanguage(code: "en", nativeName: "English", englishName: "English"),
        TranscriptionLanguage(code: "es", nativeName: "Español", englishName: "Spanish"),
        TranscriptionLanguage(code: "fi", nativeName: "Suomi", englishName: "Finnish"),
        TranscriptionLanguage(code: "fr", nativeName: "Français", englishName: "French"),
        TranscriptionLanguage(code: "he", nativeName: "עברית", englishName: "Hebrew"),
        TranscriptionLanguage(code: "hi", nativeName: "हिन्दी", englishName: "Hindi"),
        TranscriptionLanguage(code: "hu", nativeName: "Magyar", englishName: "Hungarian"),
        TranscriptionLanguage(code: "it", nativeName: "Italiano", englishName: "Italian"),
        TranscriptionLanguage(code: "ja", nativeName: "日本語", englishName: "Japanese"),
        TranscriptionLanguage(code: "ko", nativeName: "한국어", englishName: "Korean"),
        TranscriptionLanguage(code: "nl", nativeName: "Nederlands", englishName: "Dutch"),
        TranscriptionLanguage(code: "no", nativeName: "Norsk", englishName: "Norwegian"),
        TranscriptionLanguage(code: "pl", nativeName: "Polski", englishName: "Polish"),
        TranscriptionLanguage(code: "pt", nativeName: "Português", englishName: "Portuguese"),
        TranscriptionLanguage(code: "pt-BR", nativeName: "Português (Brasil)", englishName: "Brazilian Portuguese"),
        TranscriptionLanguage(code: "ro", nativeName: "Română", englishName: "Romanian"),
        TranscriptionLanguage(code: "ru", nativeName: "Русский", englishName: "Russian"),
        TranscriptionLanguage(code: "sk", nativeName: "Slovenčina", englishName: "Slovak"),
        TranscriptionLanguage(code: "sv", nativeName: "Svenska", englishName: "Swedish"),
        TranscriptionLanguage(code: "th", nativeName: "ไทย", englishName: "Thai"),
        TranscriptionLanguage(code: "tr", nativeName: "Türkçe", englishName: "Turkish"),
        TranscriptionLanguage(code: "uk", nativeName: "Українська", englishName: "Ukrainian"),
        TranscriptionLanguage(code: "vi", nativeName: "Tiếng Việt", englishName: "Vietnamese"),
        TranscriptionLanguage(code: "zh", nativeName: "中文", englishName: "Chinese"),
        // Whisper has one `zh` token, so both entries transcribe the same way. They differ in
        // the script Sonor asks for, which is what the reader actually sees.
        TranscriptionLanguage(code: "zh-Hant", nativeName: "中文（繁體）", englishName: "Traditional Chinese"),
        TranscriptionLanguage(code: "zh-Hans", nativeName: "中文（简体）", englishName: "Simplified Chinese")
    ]

    static func named(_ code: String) -> TranscriptionLanguage {
        all.first { $0.code == code } ?? automatic
    }

    /// The choice every assistant starts from.
    static var global: TranscriptionLanguage {
        named(UserDefaults.standard.string(forKey: storageKey) ?? automaticCode)
    }

    /// The language an assistant really dictates in.
    ///
    /// A missing code and the follow code both mean the assistant never set its own language.
    static func resolved(modeCode: String?) -> TranscriptionLanguage {
        guard let modeCode, modeCode != followGlobalCode else { return global }
        return named(modeCode)
    }
}
