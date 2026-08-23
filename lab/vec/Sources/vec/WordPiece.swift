// WordPiece — the BERT tokenizer, in Swift, matching HuggingFace exactly.
//
// 🛑 THIS FILE IS A PARITY EXERCISE, NOT A DESIGN. A tokenizer that splits one
// word differently produces a different vector, and nothing downstream can see
// that it happened. Every rule here mirrors `transformers.BertTokenizer` with
// `do_lower_case=True`, which is what `intfloat/e5-small-v2` ships.
//
// The four rules that are easy to get wrong, and are checked by `vec verify`
// against 238k real chunks already embedded by the Python path:
//
//   1. `strip_accents` is null in the config, and HF reads null as "follow
//      do_lower_case". So accents ARE stripped.
//   2. HF removes category **Mn** only. `CharacterSet.nonBaseCharacters` is
//      Mn+Mc+Me, so using it would strip spacing marks HF keeps.
//   3. Punctuation is split into single-character tokens BEFORE WordPiece.
//   4. A word longer than 100 characters becomes [UNK] whole, without ever
//      being looked up.

import Foundation

struct WordPiece {
    let vocab: [String: Int32]
    let unknown: Int32
    let classify: Int32          // [CLS]
    let separate: Int32          // [SEP]
    let pad: Int32               // [PAD]

    static let maxCharactersPerWord = 100

    init(vocabularyAt url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        var table: [String: Int32] = [:]
        table.reserveCapacity(32000)
        // ⚠️ Split on "\n" keeping empty lines, so every id matches its line
        // number, and drop only a trailing empty line from the final newline.
        // Never trim a token: the vocab holds tokens that are punctuation.
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        for (index, line) in lines.enumerated() {
            table[String(line)] = Int32(index)
        }
        vocab = table
        guard let unk = table["[UNK]"], let cls = table["[CLS]"],
              let sep = table["[SEP]"], let padding = table["[PAD]"] else {
            throw Failure("vocab.txt is missing [UNK], [CLS], [SEP] or [PAD]")
        }
        unknown = unk
        classify = cls
        separate = sep
        pad = padding
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ message: String) { description = message }
    }

    // MARK: - character classes, exactly as HF defines them

    /// 🛑 Cc, Cf, Co and Cs — but NOT Cn.
    ///
    /// `AutoTokenizer` returns the **fast** tokenizer, which is Rust, not the
    /// Python `BertTokenizer`. The two disagree here: Python's `_is_control`
    /// tests `category.startswith("C")`, which drops unassigned code points,
    /// and the Rust one keeps them. Measured on a real chunk holding U+FFFF
    /// (category Cn): the fast tokenizer emitted `[UNK]` and this port emitted
    /// nothing. The stored vectors came from the fast tokenizer, so the fast
    /// tokenizer is what this has to match.
    ///
    /// ⚠️ **Private use (Co) IS dropped**, and that is not a guess either: Word
    /// and Outlook emit U+F0B7 and U+F04A for Symbol-font bullets, and three
    /// real chunks held them. Keeping them added a spurious `[UNK]` per bullet.
    /// So the rule is "every assigned C* category", which is exactly what a
    /// table of assigned categories can express — and why Cn falls outside it.
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\t" || scalar == "\n" || scalar == "\r" { return false }
        switch scalar.properties.generalCategory {
        case .control, .format, .privateUse, .surrogate: return true
        default: return false
        }
    }

    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" { return true }
        return scalar.properties.generalCategory == .spaceSeparator
    }

    private static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        let cp = scalar.value
        // HF treats the ASCII symbol ranges as punctuation even though Unicode
        // calls several of them Sc/Sk/Sm. Dropping this made "$" a word piece.
        if (cp >= 33 && cp <= 47) || (cp >= 58 && cp <= 64)
            || (cp >= 91 && cp <= 96) || (cp >= 123 && cp <= 126) { return true }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation,
             .closePunctuation, .initialPunctuation, .finalPunctuation,
             .otherPunctuation:
            return true
        default:
            return false
        }
    }

    private static func isChinese(_ cp: UInt32) -> Bool {
        return (cp >= 0x4E00 && cp <= 0x9FFF) || (cp >= 0x3400 && cp <= 0x4DBF)
            || (cp >= 0x20000 && cp <= 0x2A6DF) || (cp >= 0x2A700 && cp <= 0x2B73F)
            || (cp >= 0x2B740 && cp <= 0x2B81F) || (cp >= 0x2B820 && cp <= 0x2CEAF)
            || (cp >= 0xF900 && cp <= 0xFAFF) || (cp >= 0x2F800 && cp <= 0x2FA1F)
    }

    // MARK: - basic tokenizer

    /// Clean, space out CJK, split on whitespace, lowercase, strip accents,
    /// then split off punctuation. The output feeds WordPiece.
    private func basicTokens(_ text: String) -> [String] {
        // 🛑 EVERY STEP HERE WORKS ON UNICODE SCALARS, NEVER ON `Character`.
        //
        // Swift's `String.split(separator: " ")` splits on grapheme CLUSTERS,
        // and a combining mark binds to the space in front of it. So a run of
        // "SPACE U+034F" — which mail preheaders use as invisible padding —
        // contains no Character equal to " ", the split does not fire, and each
        // cluster survives as a word that WordPiece then reports as [UNK].
        // Measured: one real chunk produced 82 spurious [UNK] tokens that way,
        // and Python produced none. Python splits on scalars.
        var cleaned: [Unicode.Scalar] = []
        cleaned.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            if scalar.value == 0 || scalar.value == 0xFFFD || Self.isControl(scalar) { continue }
            if Self.isWhitespace(scalar) {
                cleaned.append(" ")
            } else if Self.isChinese(scalar.value) {
                cleaned.append(" ")
                cleaned.append(scalar)
                cleaned.append(" ")
            } else {
                cleaned.append(scalar)
            }
        }

        var out: [String] = []
        var word: [Unicode.Scalar] = []

        func flush() {
            guard !word.isEmpty else { return }
            var view = String.UnicodeScalarView()
            for scalar in word { view.append(scalar) }
            // Lowercase, then NFD and drop every nonspacing mark.
            //
            // ⚠️ HF removes category Mn ONLY. `CharacterSet.nonBaseCharacters`
            // is Mn+Mc+Me, so it would also strip spacing marks HF keeps.
            let lowered = String(view).lowercased().decomposedStringWithCanonicalMapping
            var current: [Unicode.Scalar] = []
            for scalar in lowered.unicodeScalars {
                if scalar.properties.generalCategory == .nonspacingMark { continue }
                if Self.isPunctuation(scalar) {
                    if !current.isEmpty { out.append(Self.join(current)); current = [] }
                    out.append(String(scalar))
                } else {
                    current.append(scalar)
                }
            }
            if !current.isEmpty { out.append(Self.join(current)) }
            word = []
        }

        for scalar in cleaned {
            if scalar == " " { flush() } else { word.append(scalar) }
        }
        flush()
        return out
    }

    private static func join(_ scalars: [Unicode.Scalar]) -> String {
        var view = String.UnicodeScalarView()
        for scalar in scalars { view.append(scalar) }
        return String(view)
    }

    // MARK: - wordpiece

    /// Greedy longest-match-first. Pieces after the first carry "##".
    private func pieces(of word: String, into ids: inout [Int32]) {
        let characters = Array(word)
        if characters.count > Self.maxCharactersPerWord {
            ids.append(unknown)
            return
        }
        var start = 0
        var found: [Int32] = []
        while start < characters.count {
            var end = characters.count
            var match: Int32? = nil
            while start < end {
                var candidate = String(characters[start..<end])
                if start > 0 { candidate = "##" + candidate }
                if let id = vocab[candidate] { match = id; break }
                end -= 1
            }
            guard let id = match else {
                // 🛑 One unmatched piece makes the WHOLE word [UNK]. Emitting
                // the pieces found so far is the obvious wrong implementation.
                ids.append(unknown)
                return
            }
            found.append(id)
            start = end
        }
        ids.append(contentsOf: found)
    }

    /// `[CLS] … [SEP]`, truncated to `maxLength` in total.
    func encode(_ text: String, maxLength: Int) -> [Int32] {
        var body: [Int32] = []
        body.reserveCapacity(maxLength)
        for word in basicTokens(text) {
            pieces(of: word, into: &body)
            if body.count >= maxLength - 2 { break }
        }
        if body.count > maxLength - 2 { body = Array(body.prefix(maxLength - 2)) }
        return [classify] + body + [separate]
    }

    /// Token count without truncation, for choosing a bucket.
    func length(_ text: String, cap: Int) -> Int {
        return encode(text, maxLength: cap).count
    }
}
