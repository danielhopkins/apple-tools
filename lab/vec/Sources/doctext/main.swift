import Foundation
import PDFKit

// --------------------------------------------------------------------------
// doctext — text out of the document formats the index cannot read itself
// --------------------------------------------------------------------------
//
// `index.py` reads markdown, text and the Office formats itself, because a
// `.docx` is a zip of XML and `zipfile` is in the standard library. PDF is not
// like that. There is no stdlib route and no route through the system Python:
//
//   textutil          does not read PDF at all
//   mdimport -t -d3   works, and is PDFKit — `mdimport -e` names its importer
//                     com.apple.PDFKit.PDFImporter, inside PDFKit.framework.
//                     Byte-identical output, garbling included, and 3x slower
//   /usr/bin/python3  is 3.9.6 and has no Quartz module. MarkItDown needs 3.10
//
// So PDF is Swift, and this is the binary. It lives in the `vec` package so
// one `swift build` still produces everything the index needs.
//
// ⚠️ BATCH, NEVER ONE PROCESS PER FILE. 159 PDFs cost 5.3s in one process and
// most of that is real work; spawning 159 processes adds more overhead than
// the extraction costs. `doctext -` reads paths from stdin for that reason.

struct Result: Codable {
    var path: String
    var ok: Bool
    var format: String
    var reason: String?
    var pages: Int?
    var chars: Int?
    var stopword_rate: Double?
    var cid_rate: Double?
    // ⚠️ ADVISORY, AND NOTHING IS EVER DROPPED FOR IT. Pages carrying little
    // prose, 1-based. Measured on 159 real PDFs: this names lists, tables and
    // other languages far more often than wreckage, and one page it named was
    // the HOA contact list. See Quality.swift for why dropping was abandoned.
    var low_prose_pages: [Int]?
    var judged: Bool?
    // ⚠️ Only with --no-text. The per-page scores the verdict was made from,
    // so a threshold can be re-derived from a real corpus rather than argued
    // about. `lab/test-doctext.py` reads this.
    var page_rates: [Double?]?
    var text: String?
}

func fail(_ path: String, _ format: String, _ reason: String) -> Result {
    Result(path: path, ok: false, format: format, reason: reason)
}

func extractPDF(_ path: String, includeText: Bool) -> Result {
    guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
        return fail(path, "pdf", "unreadable")
    }
    // ⚠️ An encrypted PDF that is still locked returns an empty string rather
    // than failing, so it would otherwise be reported as a scan.
    if doc.isEncrypted && doc.isLocked {
        return fail(path, "pdf", "encrypted")
    }

    // 🛑 PAGE BY PAGE, NOT `doc.string`. The per-page score is the only one
    // that means anything, and `doc.string` has already blended the pages
    // together by the time anything can look at them.
    var pageTexts: [String] = []
    var rates: [(page: Int, rate: Double?)] = []
    for number in 0..<doc.pageCount {
        let pageText = doc.page(at: number)?.string ?? ""
        pageTexts.append(pageText)
        rates.append((number + 1,
                      stopwordRate(pageText, minimumWords: PAGE_MINIMUM_WORDS)))
    }
    let text = pageTexts.joined(separator: "\n")

    // 🛑 A SCAN IS NOT A FAILURE AND NOT A DOCUMENT. Measured here: 20 of 159
    // PDFs are scans with no text layer. Neither PDFKit nor pdfminer nor
    // MarkItDown reads one, because none of them does OCR. Reporting it as an
    // empty document would put a record in the index that looks indexed and
    // can never match.
    if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 50 {
        var r = fail(path, "pdf", "no-text-layer")
        r.pages = doc.pageCount
        r.chars = text.count
        return r
    }

    let verdict = judgePages(rates)
    return Result(path: path, ok: true, format: "pdf", reason: nil,
                  pages: doc.pageCount, chars: text.count,
                  stopword_rate: stopwordRate(text),
                  cid_rate: cidNoiseRate(text),
                  low_prose_pages: verdict.lowProsePages.isEmpty
                      ? nil : verdict.lowProsePages,
                  judged: verdict.judged,
                  page_rates: includeText ? nil : rates.map { $0.rate },
                  text: includeText ? text : nil)
}

func extract(_ path: String, includeText: Bool) -> Result {
    guard FileManager.default.fileExists(atPath: path) else {
        return fail(path, "", "missing")
    }
    switch (path as NSString).pathExtension.lowercased() {
    case "pdf":
        return extractPDF(path, includeText: includeText)
    default:
        // ⚠️ Deliberately narrow. `index.py` reads markdown, text and Office
        // itself; adding a second route to a format it already reads is how
        // two answers to one question start to drift.
        return fail(path, (path as NSString).pathExtension.lowercased(),
                    "unsupported")
    }
}

// -- arguments -------------------------------------------------------------

var paths: [String] = []
var fromStdin = false
var includeText = true

var args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args.contains("--help") || args.contains("-h") {
    FileHandle.standardError.write("""
    usage: doctext [--no-text] FILE...
           doctext [--no-text] -          read paths from stdin, one per line

    Writes one JSON object per line: path, ok, format, reason, pages, chars,
    stopword_rate, cid_rate, low_prose_pages, judged, text.

    ⚠️ low_prose_pages is ADVISORY and nothing is ever dropped for it. It names
    lists, tables and other languages as readily as broken text. See
    Quality.swift.

    --no-text        report the measurements without the text. For scoring
                     a corpus.

    reason, when ok is false:
      missing        no such file
      unsupported    not a format this binary reads
      unreadable     PDFKit could not open it
      encrypted      locked, so there is nothing to read
      no-text-layer  a scan. Nothing here does OCR

    """.data(using: .utf8)!)
    exit(args.isEmpty ? 64 : 0)
}
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--no-text": includeText = false
    case "-": fromStdin = true
    default: paths.append(arg)
    }
}

if fromStdin {
    while let line = readLine(strippingNewline: true) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { paths.append(trimmed) }
    }
}

// -- run -------------------------------------------------------------------

let encoder = JSONEncoder()
let out = FileHandle.standardOutput
var failures = 0
for path in paths {
    let result = extract(path, includeText: includeText)
    if !result.ok { failures += 1 }
    // ⚠️ One line per file, flushed as it goes, so a long run is streamable
    // and one unreadable file never costs the whole batch.
    if var data = try? encoder.encode(result) {
        data.append(0x0a)
        out.write(data)
    }
}
// 🛑 Exit 0 even with failures. A scan and an unsupported file are ordinary
// results, not errors, and every one of them is already named on its own line.
// A non-zero exit would make the caller discard a whole good batch.
exit(0)
