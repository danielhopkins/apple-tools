import Foundation

// --------------------------------------------------------------------------
// How much of this extracted text is prose? And why that is NOT a filter.
// --------------------------------------------------------------------------
//
// 🛑 EVERY PDF TEXT EXTRACTOR FAILS ON A BROKEN ToUnicode MAP, AND EACH ONE
// FAILS DIFFERENTLY. Measured on the same page of one real budget letter,
// whose true first line is "To the Joint Budget Committee and the General
// Assembly:".
//
//   PDFKit       To e o Be ommee e Geer emb
//   pypdf        To WKe -oLQW BXGJeW &ommLWWee DQG WKe GeQerDO $VVembO\
//   MarkItDown   (cid:42)(cid:50)(cid:57)(cid:40)(cid:53)(cid:49)(cid:50)(cid:53)
//
// PDFKit's failure is the hardest to see. The other two announce themselves:
// cid codes are a fixed pattern, and pypdf's output carries control
// characters. PDFKit returns ordinary letters in ordinary words.
//
// 🛑 SO THIS FILE WAS WRITTEN TO DETECT AND DROP THAT WRECKAGE, AND THE
// MEASUREMENT SAYS IT CANNOT BE DONE. The signal tried was the rate of common
// English function words: prose cannot avoid "the", "and", "of", and a broken
// glyph map erases exactly those short words. Three confounds killed it, in
// this order, each found only by looking at real files:
//
//   1. THE GARBLING IS PER PAGE, NOT PER DOCUMENT. That budget letter is 88
//      pages; one letterhead page is wrecked and the rest are clean. The
//      document scores 0.174, inside the ordinary bottom decile and
//      indistinguishable from a resume at 0.196. So the score went per page.
//   2. THE LIST IS ENGLISH, SO ANOTHER LANGUAGE SCORES ZERO. "Join PTA Flyer
//      - Spanish.pdf" scores 0.000 and is a perfectly good document. So pages
//      were judged against the other pages of their OWN document, which
//      cancels the language out.
//   3. 🛑 AND THEN A LIST SCORES ZERO TOO, WHICH IS FATAL. A list has no
//      function words because a list is not sentences. Of the 71 pages this
//      flagged across 159 real PDFs, the ones read by hand were a plant list
//      and a page headed CONTACT LIST holding the HOA's insurer, animal
//      control and the police — phone numbers somebody would search for. That
//      is not wreckage. It is the single most retrievable page in the file.
//
// The true wreckage in this whole corpus is about one page. The cost of
// dropping it is real content, silently. So NOTHING IS EVER DROPPED. The
// measurement is reported and named for what it actually measures — how
// little prose a page has — and no caller should read it as "this is broken".
//
// ⚠️ `low_prose_pages` MEANS "a list, a table, a chart caption, or another
// language" far more often than it means wreckage. It is a hint for a human
// reading the JSON, never a filter.

let STOPWORDS: Set<String> = [
    "the", "of", "and", "to", "a", "in", "is", "it", "you", "that",
    "he", "was", "for", "on", "are", "as", "with", "his", "they", "i",
    "at", "be", "this", "have", "from", "or", "one", "had", "by", "but",
    "not", "what", "all", "were", "we", "when", "your", "can", "said",
    "there", "use", "an", "each", "which", "she", "do", "how", "their",
    "if", "will", "up", "other", "about", "out", "many", "then", "them",
    "these", "so", "some", "her", "would", "make", "like", "him", "into",
    "time", "has", "look", "two", "more", "no", "way", "could", "my",
    "than", "been", "who", "its", "now", "did", "get", "may", "our",
    "any", "also", "should", "must", "shall", "such", "only", "over",
]

/// The fraction of alphabetic words that are common English function words.
///
/// ⚠️ Returns nil when there are too few words to say anything. A 40-word
/// cover page is not evidence of anything, and scoring it would make the
/// threshold fire on real documents that simply have little text.
func stopwordRate(_ text: String, minimumWords: Int = 100) -> Double? {
    var total = 0
    var hits = 0
    // ⚠️ Split on anything that is not a letter, so "don't" and "end-of-year"
    // become plain words and punctuation never enters a token.
    for raw in text.lowercased().split(whereSeparator: { !$0.isLetter }) {
        // A one-character token is noise in both directions: "a" and "i" are
        // stopwords, and wreckage produces them by the hundred.
        guard raw.count > 1 else { continue }
        total += 1
        if STOPWORDS.contains(String(raw)) { hits += 1 }
    }
    guard total >= minimumWords else { return nil }
    return Double(hits) / Double(total)
}

/// `(cid:42)` runs, which pdfminer emits and PDFKit never does. Kept because
/// `doctext` may one day read text this process did not extract.
func cidNoiseRate(_ text: String) -> Double {
    guard !text.isEmpty else { return 0 }
    var noise = 0
    var search = text.startIndex..<text.endIndex
    while let found = text.range(of: "(cid:", range: search) {
        guard let close = text.range(of: ")", range: found.upperBound..<text.endIndex)
        else { break }
        noise += text.distance(from: found.lowerBound, to: close.upperBound)
        search = close.upperBound..<text.endIndex
    }
    return Double(noise) / Double(text.count)
}

// --------------------------------------------------------------------------
// Which pages of THIS document carry little prose
// --------------------------------------------------------------------------
//
// ⚠️ ADVISORY ONLY. Read the header: this flags lists and other languages as
// readily as it flags wreckage, so nothing acts on it.

/// A page must carry this many words before its score means anything. Lower
/// than the document minimum, because pages are small. ⚠️ A title page of six
/// words is not evidence and must never be dropped.
let PAGE_MINIMUM_WORDS = 30

/// The document needs at least this much healthy text to judge anything by.
/// 🛑 Below it, the document is assumed to be a language this list does not
/// cover, or to be tables and numbers, and NOTHING is called suspect. Set from
/// the corpus: the healthy median is 0.368 and the 5th percentile 0.196.
let DOCUMENT_FLOOR = 0.15

/// A page is reported when it scores below this share of its own document's
/// healthy level. The wrecked letterhead measured 0.00 against pages of 0.41.
let PAGE_OUTLIER_SHARE = 0.4

struct PageVerdict {
    var lowProsePages: [Int] = []      // 1-based, as a person counts pages
    var healthy: Double?               // the document's own healthy level
    var judged: Bool = false           // false when there was nothing to judge by
}

/// ⚠️ Takes the pages that HAVE a score. A page too short to score is never
/// reported and never contributes to the reference level.
func judgePages(_ rates: [(page: Int, rate: Double?)]) -> PageVerdict {
    var verdict = PageVerdict()
    let scored = rates.compactMap { item in item.rate.map { (item.page, $0) } }
    // 🛑 One page cannot be an outlier among its own siblings, because it has
    // none. A single-page flyer is never judged, which is the right answer:
    // there is no evidence either way.
    guard scored.count >= 2 else { return verdict }

    let values = scored.map { $0.1 }.sorted()
    // 🛑 THE UPPER QUARTILE, NOT THE MEDIAN, and this was measured. A budget
    // book is mostly tables: only 3 of its 88 pages carry enough words to
    // score at all, and their median of 0.097 sat below any usable floor, so
    // the document was never judged and the one wrecked page went unreported.
    // The upper quartile asks "what does this document score WHEN IT WORKS",
    // which is the question, and it survives a document that is mostly tables.
    let healthy = values[min(values.count - 1, (values.count * 3) / 4)]
    verdict.healthy = healthy
    guard healthy >= DOCUMENT_FLOOR else { return verdict }

    verdict.judged = true
    verdict.lowProsePages = scored
        .filter { $0.1 < healthy * PAGE_OUTLIER_SHARE }
        .map { $0.0 }
        .sorted()
    return verdict
}
