import Foundation

/// Query parsing.
///
/// A query is a list of terms that must **all** appear — `budget review` finds
/// messages mentioning both words anywhere, not the literal string "budget
/// review". Treating the whole query as one substring meant the most natural
/// way to phrase a search returned nothing: on a real store `budget review`
/// matched 0 messages while `budget` alone matched 1082, more than a third of
/// which also said "review".
///
/// Double quotes group words into a single phrase for when adjacency is
/// actually what you mean: `"boulder lawns"` is one term, `boulder lawns` is
/// two.
public func parseSearchTerms(_ query: String) -> [String] {
  var terms: [String] = []
  var current = ""
  var inQuotes = false

  func flush() {
    let term = current.trimmingCharacters(in: .whitespacesAndNewlines)
    if !term.isEmpty { terms.append(term) }
    current = ""
  }

  for character in query {
    if character == "\"" {
      // A closing quote ends the phrase even if it is empty, so `""` is not a
      // term that matches everything.
      if inQuotes { flush() }
      inQuotes.toggle()
      continue
    }
    if !inQuotes, character.isWhitespace {
      flush()
      continue
    }
    current.append(character)
  }
  // An unterminated quote is a typo, not an error; take the rest as a phrase.
  flush()
  return terms
}

/// Whether every term appears in `haystack`. Callers lowercase both sides once
/// rather than per comparison.
public func containsAllTerms(_ haystack: String, _ lowercasedTerms: [String]) -> Bool {
  guard !lowercasedTerms.isEmpty else { return true }
  let lowered = haystack.lowercased()
  return lowercasedTerms.allSatisfy { lowered.contains($0) }
}
