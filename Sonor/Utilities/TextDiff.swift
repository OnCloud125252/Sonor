import Foundation

/// What the assistant did with one run of words.
public enum TextDiffKind: Equatable, Sendable {
    case kept
    case removed
    case added
}

/// One run of words that share the same kind.
public struct TextDiffSegment: Identifiable, Equatable, Sendable {
    public let id: Int
    public let text: String
    public let kind: TextDiffKind
    /// True when a space came before this run in the source text. Chinese runs together, so
    /// the drawing code cannot just put a space between every two runs.
    public let leadingSpace: Bool

    public init(id: Int, text: String, kind: TextDiffKind, leadingSpace: Bool = false) {
        self.id = id
        self.text = text
        self.kind = kind
        self.leadingSpace = leadingSpace
    }
}

extension Character {
    /// True for a script that writes without spaces, where one character already carries a
    /// meaning. Such a character is its own word for the diff.
    var isStandaloneScriptCharacter: Bool {
        guard unicodeScalars.count == 1, let scalar = unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF,   // Hiragana and Katakana
             0x3400...0x4DBF,   // CJK ideographs, extension A
             0x4E00...0x9FFF,   // CJK ideographs
             0xF900...0xFAFF,   // CJK compatibility ideographs
             0xAC00...0xD7AF:   // Hangul syllables
            return true
        default:
            return false
        }
    }
}

/// Compares the raw transcript with the assistant output, word by word.
public enum TextDiff {

    /// One word, plus the key that decides whether two words are the same word.
    ///
    /// Two words match when only their case or the punctuation around them differs. The
    /// assistant fixes case and punctuation in almost every sentence. A mark on each one of
    /// those would paint the whole panel, and the real edits would drown in the color.
    struct Word: Equatable {
        let text: String
        let key: String
        let hasLeadingSpace: Bool

        init(_ text: String, hasLeadingSpace: Bool) {
            self.text = text
            self.hasLeadingSpace = hasLeadingSpace
            let stripped = text.trimmingCharacters(in: Word.edgeMarks)
            self.key = (stripped.isEmpty ? text : stripped).lowercased()
        }

        static let edgeMarks = CharacterSet.punctuationCharacters.union(.symbols)

        static func == (lhs: Word, rhs: Word) -> Bool {
            lhs.key == rhs.key
        }
    }

    /// Cuts the text into the units that the panel marks one by one.
    ///
    /// English and other spaced scripts split on whitespace, so one word is one unit. Chinese,
    /// Japanese and Korean split per character, because those scripts write without spaces and
    /// one whole sentence as a single unit would mark every edit as a full rewrite.
    /// Punctuation stays glued to the character or word before it, so a new comma alone does
    /// not count as an edit.
    static func words(in text: String) -> [Word] {
        var result: [Word] = []
        var buffer = ""
        var pendingSpace = false

        func flush() {
            guard !buffer.isEmpty else { return }
            result.append(Word(buffer, hasLeadingSpace: pendingSpace))
            buffer = ""
            pendingSpace = false
        }

        for character in text {
            if character.isWhitespace {
                flush()
                pendingSpace = true
            } else if character.isStandaloneScriptCharacter {
                flush()
                buffer.append(character)
            } else {
                // A letter or a digit right after a Chinese character starts a new word.
                // Punctuation does not, so it stays with the character before it.
                if let last = buffer.last,
                   last.isStandaloneScriptCharacter,
                   character.isLetter || character.isNumber {
                    flush()
                }
                buffer.append(character)
            }
        }
        flush()
        return result
    }

    /// Builds the runs to draw. Removed words come before the added words that replace them.
    public static func segments(from oldText: String, to newText: String) -> [TextDiffSegment] {
        segments(from: words(in: oldText), to: words(in: newText))
    }

    /// Builds the runs for an assistant that is still writing.
    ///
    /// Only the part of the transcript that the assistant already passed takes part in the
    /// comparison. The words after that point are not deleted, the assistant simply has not
    /// reached them yet, and marking them red would paint the whole tail.
    public static func partialSegments(from oldText: String, to newText: String) -> [TextDiffSegment] {
        let newWords = words(in: newText)
        // One word of headroom lets the word being written right now match its source, so it
        // does not flash green and then settle back to plain.
        let reached = Array(words(in: oldText).prefix(newWords.count + 1))
        return trimmingTrailingRemovals(segments(from: reached, to: newWords))
    }

    /// Drops the removed words at the end of a run list.
    public static func trimmingTrailingRemovals(_ segments: [TextDiffSegment]) -> [TextDiffSegment] {
        var result = segments
        while result.last?.kind == .removed {
            result.removeLast()
        }
        return result
    }

    /// The opening part that two preview passes agree on.
    ///
    /// The engine reads the whole window again on every pass, so the end of the text keeps
    /// moving. The part that did not move is safe to show as settled.
    ///
    /// The test ignores case and punctuation. The engine moves a comma on almost every pass,
    /// and a strict test would call the whole sentence unsettled because of one comma.
    public static func stablePrefix(_ first: String, _ second: String) -> String {
        let firstWords = words(in: first)
        let secondWords = words(in: second)
        var shared = 0
        while shared < firstWords.count, shared < secondWords.count,
              firstWords[shared] == secondWords[shared] {
            shared += 1
        }
        return joined(Array(secondWords.prefix(shared)))
    }

    private static func segments(from oldWords: [Word], to newWords: [Word]) -> [TextDiffSegment] {
        if oldWords == newWords {
            // The assistant spelling wins, so a fixed case shows up in the text itself.
            guard !newWords.isEmpty else { return [] }
            return [TextDiffSegment(id: 0, text: joined(newWords), kind: .kept, leadingSpace: newWords[0].hasLeadingSpace)]
        }

        var removedAt: [Int: Word] = [:]
        var addedAt: [Int: Word] = [:]
        for change in newWords.difference(from: oldWords) {
            switch change {
            case let .remove(offset, element, _):
                removedAt[offset] = element
            case let .insert(offset, element, _):
                addedAt[offset] = element
            }
        }

        var runs: [(kind: TextDiffKind, words: [Word])] = []
        func append(_ kind: TextDiffKind, _ word: Word) {
            if runs.last?.kind == kind {
                runs[runs.count - 1].words.append(word)
            } else {
                runs.append((kind, [word]))
            }
        }

        // `CollectionDifference` counts removals against the old text and insertions against
        // the new one, so the merge walks both indexes at the same time.
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldWords.count || newIndex < newWords.count {
            if let removed = removedAt[oldIndex] {
                append(.removed, removed)
                oldIndex += 1
            } else if let added = addedAt[newIndex] {
                append(.added, added)
                newIndex += 1
            } else if oldIndex < oldWords.count && newIndex < newWords.count {
                append(.kept, newWords[newIndex])
                oldIndex += 1
                newIndex += 1
            } else {
                break
            }
        }

        return runs.enumerated().map { index, run in
            let text = joined(run.words)
            var leadingSpace = run.words[0].hasLeadingSpace
            // An edit can drop the space that stood between two words. English still needs
            // the gap, or a removed run and the word after it run together on screen.
            if !leadingSpace, index > 0,
               let previous = runs[index - 1].words.last?.text.last,
               let first = text.first,
               previous.isLetter || previous.isNumber,
               first.isLetter || first.isNumber,
               !previous.isStandaloneScriptCharacter,
               !first.isStandaloneScriptCharacter {
                leadingSpace = true
            }
            return TextDiffSegment(id: index, text: text, kind: run.kind, leadingSpace: leadingSpace)
        }
    }

    /// Puts a run back together with the spacing that the source text had.
    private static func joined(_ words: [Word]) -> String {
        var result = ""
        for (index, word) in words.enumerated() {
            if index > 0 && word.hasLeadingSpace {
                result.append(" ")
            }
            result.append(word.text)
        }
        return result
    }
}
