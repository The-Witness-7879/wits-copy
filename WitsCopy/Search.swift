import AppKit
import Defaults
import Fuse

class Search {
  enum Mode: String, CaseIterable, Identifiable, CustomStringConvertible, Defaults.Serializable {
    case exact
    case fuzzy
    case regexp
    case mixed

    var id: Self { self }

    var description: String {
      switch self {
      case .exact:
        return NSLocalizedString("Exact", tableName: "GeneralSettings", comment: "")
      case .fuzzy:
        return NSLocalizedString("Fuzzy", tableName: "GeneralSettings", comment: "")
      case .regexp:
        return NSLocalizedString("Regex", tableName: "GeneralSettings", comment: "")
      case .mixed:
        return NSLocalizedString("Mixed", tableName: "GeneralSettings", comment: "")
      }
    }
  }

  struct SearchResult: Equatable {
    var score: Double?
    var object: Searchable
    var ranges: [Range<String.Index>] = []
  }

  typealias Searchable = HistoryItemDecorator

  private let fuse = Fuse(threshold: 0.7) // threshold found by trial-and-error
  private let fuzzySearchLimit = 5_000

  private struct BodySample {
    var revision: Int
    var text: String
  }
  private var bodyCache: [UUID: BodySample] = [:]

  /// Reuse the decorator's 10k-character preview, never read file bodies or invoke OCR.
  /// Rich conversion can decode the stored representation once before truncation.
  /// Body saves call noteContentChanged(); re-copy creates a new decorator id. Cache
  /// only that identity + revision and bounded text, never snapshot/compare payloads.
  /// Fuzzy has the existing tighter 5k limit. Removed/out-of-pool samples are released.
  private func bodyText(of item: Searchable) -> String {
    if let cached = bodyCache[item.id], cached.revision == item.contentRevision {
      return cached.text
    }
    let text = item.text
    bodyCache[item.id] = BodySample(revision: item.contentRevision, text: text)
    return text
  }

  private func secondaryStrings(of item: Searchable) -> [String] {
    var values = item.item.tags
    if item.item.title != item.title { values.append(item.item.title) }
    let body = bodyText(of: item)
    if !body.isEmpty, body != item.title { values.append(body) }
    return values
  }

  /// `tag` is an explicit filter, never parsed out of `string`.
  /// Nil skips the tag scan entirely so ordinary search does no extra work.
  /// When set, matching items are selected before exact/regexp/fuzzy.
  func search(string: String, within: [Searchable], tag: String? = nil) -> [SearchResult] {
    let live = within.filter { !$0.isRemoved }
    let ids = Set(live.map(\.id))
    bodyCache = bodyCache.filter { ids.contains($0.key) }
    let scoped = scoped(live, tag: tag)
    guard !string.isEmpty else {
      return scoped.map { SearchResult(object: $0) }
    }

    switch Defaults[.searchMode] {
    case .mixed:
      return mixedSearch(string: string, within: scoped)
    case .regexp:
      return simpleSearch(string: string, within: scoped, options: .regularExpression)
    case .fuzzy:
      return fuzzySearch(string: string, within: scoped)
    default:
      return simpleSearch(string: string, within: scoped, options: .caseInsensitive)
    }
  }

  private func scoped(_ within: [Searchable], tag: String?) -> [Searchable] {
    guard let tag else { return within }
    return within.filter { item in
      item.item.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }
  }

  private func fuzzySearch(string: String, within: [Searchable]) -> [SearchResult] {
    let pattern = fuse.createPattern(from: string)
    let searchResults: [SearchResult] = within.compactMap { item in
      var best = fuzzySearch(for: pattern, in: item.title, of: item)
      for text in secondaryStrings(of: item) {
        guard let candidate = fuzzySearch(for: pattern, in: text, of: item, highlightsTitle: false) else { continue }
        // Equal scores keep the title result (and only its valid title indices).
        if best == nil || (candidate.score ?? 0) < (best?.score ?? 0) {
          best = candidate
        }
      }
      return best
    }
    let sortedResults = searchResults.sorted(by: { ($0.score ?? 0) < ($1.score ?? 0) })
    return sortedResults
  }

  private func fuzzySearch(
    for pattern: Fuse.Pattern?,
    in searchString: String,
    of item: Searchable,
    highlightsTitle: Bool = true
  ) -> SearchResult? {
    let searchString = String(searchString.prefix(fuzzySearchLimit))

    if let fuzzyResult = fuse.search(pattern, in: searchString) {
      return SearchResult(
        score: fuzzyResult.score,
        object: item,
        ranges: highlightsTitle ? fuzzyResult.ranges.map {
          let title = item.title
          let lowerBound = title.index(title.startIndex, offsetBy: $0.lowerBound)
          let upperBound = title.index(title.startIndex, offsetBy: $0.upperBound + 1)

          return lowerBound..<upperBound
        } : []
      )
    } else {
      return nil
    }
  }

  private func simpleSearch(
    string: String,
    within: [Searchable],
    options: NSString.CompareOptions
  ) -> [SearchResult] {
    return within.compactMap { item in
      if let title = simpleSearch(for: string, in: item.title, of: item, options: options) { return title }
      if secondaryStrings(of: item).contains(where: {
        $0.range(of: string, options: options, range: nil, locale: nil) != nil
      }) {
        return SearchResult(object: item)
      }
      return nil
    }
  }

  private func simpleSearch(
    for string: String,
    in searchString: String,
    of item: Searchable,
    options: NSString.CompareOptions
  ) -> SearchResult? {
    if let range = searchString.range(of: string, options: options, range: nil, locale: nil) {
      return SearchResult(object: item, ranges: [range])
    } else {
      return nil
    }
  }

  private func mixedSearch(string: String, within: [Searchable]) -> [SearchResult] {
    var results = simpleSearch(string: string, within: within, options: .caseInsensitive)
    guard results.isEmpty else {
      return results
    }

    results = simpleSearch(string: string, within: within, options: .regularExpression)
    guard results.isEmpty else {
      return results
    }

    results = fuzzySearch(string: string, within: within)
    guard results.isEmpty else {
      return results
    }

    return []
  }
}
