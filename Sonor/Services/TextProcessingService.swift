import Foundation
import AppKit

class TextProcessingService {
    static let shared = TextProcessingService()
    
    private init() {}
    
    func parseDynamicVariables(in text: String) -> String {
        var result = text
        if result.contains("{{clipboard}}") {
            let clipboardText = NSPasteboard.general.string(forType: .string) ?? ""
            result = result.replacingOccurrences(of: "{{clipboard}}", with: clipboardText)
        }
        if result.contains("{{date}}") {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .none
            result = result.replacingOccurrences(of: "{{date}}", with: formatter.string(from: Date()))
        }
        if result.contains("{{time}}") {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            result = result.replacingOccurrences(of: "{{time}}", with: formatter.string(from: Date()))
        }
        if result.contains("{{active_app}}") {
            let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            result = result.replacingOccurrences(of: "{{active_app}}", with: appName)
        }
        if result.contains("{{day_of_week}}") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: LocalizationManager.shared.appLanguage)
            formatter.dateFormat = "EEEE"
            let dayName = formatter.string(from: Date())
            result = result.replacingOccurrences(of: "{{day_of_week}}", with: dayName)
        }
        return result
    }
    
    func applyCorrections(to text: String) -> String {
        var processedText = text
        let dictionary = UserDefaults.standard.dictionary(forKey: "dictionaryEntries") as? [String: String] ?? [:]
        for (wrong, correct) in Self.orderedEntries(dictionary) {
            processedText = Self.replaceWholeWords(in: processedText, of: wrong, with: correct)
        }
        let snippets = UserDefaults.standard.dictionary(forKey: "snippetsEntries") as? [String: String] ?? [:]
        for (shortcut, expansion) in Self.orderedEntries(snippets) {
            let parsedExpansion = parseDynamicVariables(in: expansion)
            processedText = Self.replaceWholeWords(in: processedText, of: shortcut, with: parsedExpansion)
        }
        return processedText
    }

    /// Swift dictionaries have no defined order, so overlapping entries produced different
    /// output from one run to the next. Longest key first makes the specific entry win.
    static func orderedEntries(_ entries: [String: String]) -> [(key: String, value: String)] {
        entries
            .sorted { lhs, rhs in
                lhs.key.count == rhs.key.count ? lhs.key < rhs.key : lhs.key.count > rhs.key.count
            }
            .map { (key: $0.key, value: $0.value) }
    }

    /// Scripts written without spaces have no usable word boundary: ICU joins neighbouring
    /// ideographs into one word, so an anchored pattern would never match.
    static func supportsWordBoundaries(_ key: String) -> Bool {
        !key.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value) ||   // Hiragana and Katakana
            (0x3400...0x4DBF).contains(scalar.value) ||   // CJK extension A
            (0x4E00...0x9FFF).contains(scalar.value) ||   // CJK unified ideographs
            (0xAC00...0xD7AF).contains(scalar.value)      // Hangul syllables
        }
    }

    /// Replaces whole words only. A plain substring replace let a short entry such as
    /// "is" rewrite the inside of longer words like "this".
    static func replaceWholeWords(in text: String, of key: String, with replacement: String) -> String {
        guard !key.isEmpty else { return text }
        guard supportsWordBoundaries(key) else {
            return text.replacingOccurrences(of: key, with: replacement, options: .caseInsensitive)
        }

        var pattern = NSRegularExpression.escapedPattern(for: key)
        // An anchor only works next to a word character, so keys wrapped in punctuation
        // keep a plain match on that side.
        if key.first.map({ $0.isLetter || $0.isNumber || $0 == "_" }) == true {
            pattern = "\\b" + pattern
        }
        if key.last.map({ $0.isLetter || $0.isNumber || $0 == "_" }) == true {
            pattern += "\\b"
        }

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text.replacingOccurrences(of: key, with: replacement, options: .caseInsensitive)
        }
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(text.startIndex..., in: text),
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
        )
    }
    
    func detectWordCorrections(from initial: String, to current: String) -> [(wrong: String, correct: String)] {
        let initialWords = initial.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let currentWords = current.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard initialWords != currentWords else { return [] }
        let diff = currentWords.difference(from: initialWords)
        var removes: [(index: Int, word: String)] = []
        var inserts: [(index: Int, word: String)] = []
        for change in diff {
            switch change {
            case .remove(let offset, let element, _):
                removes.append((offset, element))
            case .insert(let offset, let element, _):
                inserts.append((offset, element))
            }
        }
        removes.sort { $0.index < $1.index }
        inserts.sort { $0.index < $1.index }
        var corrections: [(wrong: String, correct: String)] = []
        if removes.count <= 2 && inserts.count <= 2 && !removes.isEmpty && !inserts.isEmpty {
            let wrong = removes.map { $0.word }.joined(separator: " ")
            let correct = inserts.map { $0.word }.joined(separator: " ")
            corrections.append((wrong: wrong, correct: correct))
        }
        return corrections
    }
}
