import Foundation

/// The languages a transcription model was trained to read.
///
/// This describes the model itself. It does not say whether Sonor can force one of those
/// languages on the model. `ModelMetadata.canSelectLanguage` answers that separately, because
/// a model can be multilingual and still offer no way to pin the language.
enum ModelLanguageSupport: Equatable, Hashable, Sendable {
    case englishOnly
    /// Every language Whisper covers.
    case multilingual
    /// A named group of languages, for a model that reads more than English but not everything.
    case subset(label: String, names: [String])

    /// The short text on the model card.
    var label: String {
        switch self {
        case .englishOnly:
            return "English"
        case .multilingual:
            return "Multilingual"
        case .subset(let label, _):
            return label
        }
    }

    /// The full list behind the model card tag.
    var names: [String] {
        switch self {
        case .englishOnly:
            return ["English (English)"]
        case .multilingual:
            return ModelManager.whisperLanguageList
        case .subset(_, let names):
            return names
        }
    }
}

extension ModelLanguageSupport {
    /// The five languages SenseVoice was trained on.
    static let senseVoice = ModelLanguageSupport.subset(
        label: "Multilingual (EN, ZH, JA, KO, YUE)",
        names: ["English (English)", "Chinese (中文)", "Japanese (日本語)", "Korean (한국어)", "Cantonese (粵語)"]
    )

    /// The four languages Canary was trained on.
    static let canary = ModelLanguageSupport.subset(
        label: "Multilingual (EN, DE, ES, FR)",
        names: ["English (English)", "German (Deutsch)", "Spanish (Español)", "French (Français)"]
    )

    /// The 25 European languages NVIDIA lists for Parakeet TDT v3.
    static let parakeetV3 = ModelLanguageSupport.subset(
        label: "Multilingual (25 EU)",
        names: [
            "Bulgarian (Български)", "Croatian (Hrvatski)", "Czech (Čeština)", "Danish (Dansk)",
            "Dutch (Nederlands)", "English (English)", "Estonian (Eesti)", "Finnish (Suomi)",
            "French (Français)", "German (Deutsch)", "Greek (Ελληνικά)", "Hungarian (Magyar)",
            "Italian (Italiano)", "Latvian (Latviešu)", "Lithuanian (Lietuvių)", "Maltese (Malti)",
            "Polish (Polski)", "Portuguese (Português)", "Romanian (Română)", "Russian (Русский)",
            "Slovak (Slovenčina)", "Slovenian (Slovenščina)", "Spanish (Español)",
            "Swedish (Svenska)", "Ukrainian (Українська)"
        ]
    )
}
