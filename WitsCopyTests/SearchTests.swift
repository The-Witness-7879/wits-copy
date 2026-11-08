import XCTest
import Defaults
@testable import WitsCopy

class SearchTests: XCTestCase {
  let savedSearchMode = Defaults[.searchMode]
  var items: [Search.Searchable]!

  override func tearDown() {
    super.tearDown()
    Defaults[.searchMode] = savedSearchMode
  }

  @MainActor
  func testSimpleSearch() { // swiftlint:disable:this function_body_length
    Defaults[.searchMode] = Search.Mode.exact
    items = [
      HistoryItemDecorator(historyItemWithTitle("foo bar baz")),
      HistoryItemDecorator(historyItemWithTitle("foo bar zaz")),
      HistoryItemDecorator(historyItemWithTitle("xxx yyy zzz"))
    ]

    XCTAssertEqual(search(""), [
      Search.SearchResult(score: nil, object: items[0], ranges: []),
      Search.SearchResult(score: nil, object: items[1], ranges: []),
      Search.SearchResult(score: nil, object: items[2], ranges: [])
    ])
    XCTAssertEqual(search("z"), [
      Search.SearchResult(
        score: nil,
        object: items[0],
        ranges: [range(from: 10, to: 10, in: items[0])]
      ),
      Search.SearchResult(
        score: nil,
        object: items[1],
        ranges: [range(from: 8, to: 8, in: items[1])]
      ),
      Search.SearchResult(
        score: nil,
        object: items[2],
        ranges: [range(from: 8, to: 8, in: items[2])]
      )
    ])
    XCTAssertEqual(search("foo"), [
      Search.SearchResult(
        score: nil,
        object: items[0],
        ranges: [range(from: 0, to: 2, in: items[0])]
      ),
      Search.SearchResult(
        score: nil,
        object: items[1],
        ranges: [range(from: 0, to: 2, in: items[1])]
      )
    ])
    XCTAssertEqual(search("za"), [
      Search.SearchResult(
        score: nil,
        object: items[1],
        ranges: [range(from: 8, to: 9, in: items[1])]
      )
    ])
    XCTAssertEqual(search("yyy"), [
      Search.SearchResult(
        score: nil,
        object: items[2],
        ranges: [range(from: 4, to: 6, in: items[2])]
      )
    ])
    XCTAssertEqual(search("fbb"), [])
    XCTAssertEqual(search("m"), [])
  }

  @MainActor
  func testFuzzySearch() { // swiftlint:disable:this function_body_length
    Defaults[.searchMode] = Search.Mode.fuzzy
    items = [
      HistoryItemDecorator(historyItemWithTitle("foo bar baz")),
      HistoryItemDecorator(historyItemWithTitle("foo bar zaz")),
      HistoryItemDecorator(historyItemWithTitle("xxx yyy zzz"))
    ]

    XCTAssertEqual(search(""), [
      Search.SearchResult(score: nil, object: items[0], ranges: []),
      Search.SearchResult(score: nil, object: items[1], ranges: []),
      Search.SearchResult(score: nil, object: items[2], ranges: [])
    ])
    XCTAssertEqual(search("z"), [
      Search.SearchResult(
        score: 0.08,
        object: items[1],
        ranges: [range(from: 8, to: 8, in: items[1]), range(from: 10, to: 10, in: items[1])]
      ),
      Search.SearchResult(
        score: 0.08,
        object: items[2],
        ranges: [range(from: 8, to: 10, in: items[2])]
      ),
      Search.SearchResult(
        score: 0.1,
        object: items[0],
        ranges: [range(from: 10, to: 10, in: items[0])]
      )
    ])
    XCTAssertEqual(search("foo"), [
      Search.SearchResult(
        score: 0.0,
        object: items[0],
        ranges: [range(from: 0, to: 2, in: items[0])]
      ),
      Search.SearchResult(
        score: 0.0,
        object: items[1],
        ranges: [range(from: 0, to: 2, in: items[1])]
      )
    ])
    XCTAssertEqual(search("za"), [
      Search.SearchResult(
        score: 0.08,
        object: items[1],
        ranges: [range(from: 5, to: 5, in: items[1]), range(from: 8, to: 9, in: items[1])]
      ),
      Search.SearchResult(
        score: 0.54,
        object: items[0],
        ranges: [range(from: 5, to: 5, in: items[0]), range(from: 9, to: 10, in: items[0])]
      ),
      Search.SearchResult(
        score: 0.58,
        object: items[2],
        ranges: [range(from: 8, to: 10, in: items[2])]
      )
    ])
    XCTAssertEqual(search("yyy"), [
      Search.SearchResult(
        score: 0.04,
        object: items[2],
        ranges: [range(from: 4, to: 6, in: items[2])]
      )
    ])
    XCTAssertEqual(search("fbb"), [
      Search.SearchResult(
        score: 0.6666666666666666,
        object: items[0],
        ranges: [
          range(from: 0, to: 0, in: items[0]),
          range(from: 4, to: 4, in: items[0]),
          range(from: 8, to: 8, in: items[0])
        ]
      ),
      Search.SearchResult(
        score: 0.6666666666666666,
        object: items[1],
        ranges: [range(from: 0, to: 0, in: items[1]), range(from: 4, to: 4, in: items[1])])
    ])
    XCTAssertEqual(search("m"), [])
  }

  @MainActor
  func testRegexpSearch() { // swiftlint:disable:this function_body_length
    Defaults[.searchMode] = Search.Mode.regexp
    items = [
      HistoryItemDecorator(historyItemWithTitle("foo bar baz")),
      HistoryItemDecorator(historyItemWithTitle("foo bar zaz")),
      HistoryItemDecorator(historyItemWithTitle("xxx yyy zzz"))
    ]

    XCTAssertEqual(search(""), [
      Search.SearchResult(score: nil, object: items[0], ranges: []),
      Search.SearchResult(score: nil, object: items[1], ranges: []),
      Search.SearchResult(score: nil, object: items[2], ranges: [])
    ])
    XCTAssertEqual(search("z+"), [
      Search.SearchResult(
        score: nil,
        object: items[0],
        ranges: [range(from: 10, to: 10, in: items[0])]
      ),
      Search.SearchResult(
        score: nil,
        object: items[1],
        ranges: [range(from: 8, to: 8, in: items[1])]
      ),
      Search.SearchResult(
        score: nil,
        object: items[2],
        ranges: [range(from: 8, to: 10, in: items[2])]
      )
    ])
    XCTAssertEqual(search("z*"), [
      Search.SearchResult(
        score: nil,
        object: items[0],
        ranges: [range(from: 0, to: -1, in: items[0])]
      ),
      Search.SearchResult(
        score: nil,
        object: items[1],
        ranges: [range(from: 0, to: -1, in: items[1])]
      ),
      Search.SearchResult(
        score: nil,
        object: items[2],
        ranges: [range(from: 0, to: -1, in: items[2])]
      )
    ])
    XCTAssertEqual(search("^foo"), [
      Search.SearchResult(
        score: nil,
        object: items[0], ranges: [range(from: 0, to: 2, in: items[0])]
      ),
      Search.SearchResult(
        score: nil,
        object: items[1], ranges: [range(from: 0, to: 2, in: items[1])]
      )
    ])
    XCTAssertEqual(search(" za"), [
      Search.SearchResult(
        score: nil,
        object: items[1],
        ranges: [range(from: 7, to: 9, in: items[1])]
      )
    ])
    XCTAssertEqual(search("[y]+"), [
      Search.SearchResult(
        score: nil,
        object: items[2],
        ranges: [range(from: 4, to: 6, in: items[2])]
      )
    ])
    XCTAssertEqual(search("fbb"), [])
    XCTAssertEqual(search("m"), [])
  }

  @MainActor
  func testHashPrefixStaysTextSearchIncludingRegexp() {
    Defaults[.searchMode] = Search.Mode.regexp
    let hashed = historyItemWithTitle("#foo [x]")
    hashed.tags = ["other"]
    let plain = historyItemWithTitle("foo")
    items = [HistoryItemDecorator(hashed), HistoryItemDecorator(plain)]

    XCTAssertEqual(search("#foo").map(\.object.item.title), ["#foo [x]"])
    XCTAssertEqual(search("^#foo").map(\.object.item.title), ["#foo [x]"])
    XCTAssertEqual(search("foo").map(\.object.item.title).sorted(), ["#foo [x]", "foo"])
  }

  @MainActor
  func testTagFilterCombinesWithTextAndRunsBeforeFuzzy() {
    Defaults[.searchMode] = Search.Mode.fuzzy
    let tagged = historyItemWithTitle("company address")
    tagged.tags = ["addr"]
    let other = historyItemWithTitle("company picnic")
    items = [HistoryItemDecorator(tagged), HistoryItemDecorator(other)]

    XCTAssertEqual(search("company", tag: "addr").map(\.object.item.title), ["company address"])
    XCTAssertEqual(search("company").map(\.object.item.title).sorted(), ["company address", "company picnic"])
    XCTAssertEqual(search("", tag: "addr").map(\.object.item.title), ["company address"])

    Defaults[.searchMode] = Search.Mode.exact
    XCTAssertEqual(search("#addr").map(\.object.item.title), [])
    items.append(HistoryItemDecorator(historyItemWithTitle("#addr note")))
    XCTAssertEqual(search("#addr").map(\.object.item.title), ["#addr note"])
  }

  @MainActor
  func testSearchMicrobenchWritesReport() throws {
    let itemCount = 1_500
    let taggedCount = 80
    var decorators: [HistoryItemDecorator] = []
    decorators.reserveCapacity(itemCount)
    for index in 0..<itemCount {
      let title = index.isMultiple(of: 17) ? "invoice \(index) vendor" : "note \(index) scratch"
      let item = HistoryItem()
      item.title = title
      if index < taggedCount {
        item.tags = ["addr"]
      }
      decorators.append(HistoryItemDecorator(item))
    }

    let searcher = Search()
    Defaults[.searchMode] = Search.Mode.exact
    let baselineExact = medianMilliseconds(repeats: 5) {
      _ = baselineExactSearch("invoice", within: decorators)
    }
    let modifiedExact = medianMilliseconds(repeats: 5) {
      _ = searcher.search(string: "invoice", within: decorators)
    }

    Defaults[.searchMode] = Search.Mode.fuzzy
    let filterThenFuzzy = medianMilliseconds(repeats: 5) {
      _ = searcher.search(string: "invoice", within: decorators, tag: "addr")
    }
    let fuzzyThenFilter = medianMilliseconds(repeats: 5) {
      _ = searcher.search(string: "invoice", within: decorators).filter {
        $0.object.item.tags.contains("addr")
      }
    }

    let filtered = searcher.search(string: "invoice", within: decorators, tag: "addr")
    XCTAssertFalse(filtered.isEmpty)
    XCTAssertTrue(filtered.allSatisfy { $0.object.item.tags == ["addr"] })

    let report: [String: Any] = [
      "scope": "In-memory microbenchmark of Search.search on synthetic titles. Not end-to-end, not UI, not SwiftData fetch, not clipboard.",
      "items": itemCount,
      "tagged": taggedCount,
      "repeats": 5,
      "metric": "median milliseconds",
      "baseline_exact_no_tag_parse_ms": baselineExact,
      "modified_exact_no_filter_ms": modifiedExact,
      "modified_filter_then_fuzzy_ms": filterThenFuzzy,
      "naive_fuzzy_then_filter_ms": fuzzyThenFilter
    ]
    // The test host runs inside the app sandbox, so a repo-relative path is not writable.
    // WITSCOPY_PERF_DIR lets a human collect the report on purpose; otherwise it lands in the
    // container's temporary directory and only the benchmark invariants are asserted.
    let directory: URL
    if let override = ProcessInfo.processInfo.environment["WITSCOPY_PERF_DIR"], !override.isEmpty {
      directory = URL(fileURLWithPath: override, isDirectory: true)
    } else {
      directory = FileManager.default.temporaryDirectory.appendingPathComponent("maccy-perf", isDirectory: true)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "search-microbench.json")
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    XCTAssertGreaterThan(baselineExact, 0)
    XCTAssertGreaterThan(fuzzyThenFilter, 0)
  }

  private func search(_ string: String, tag: String? = nil) -> [Search.SearchResult] {
    return Search().search(string: string, within: items, tag: tag)
  }

  private func baselineExactSearch(_ string: String, within: [HistoryItemDecorator]) -> [HistoryItemDecorator] {
    within.filter { $0.title.range(of: string, options: .caseInsensitive) != nil }
  }

  private func medianMilliseconds(repeats: Int, _ body: () -> Void) -> Double {
    var samples: [Double] = []
    for _ in 0..<repeats {
      let start = DispatchTime.now().uptimeNanoseconds
      body()
      let end = DispatchTime.now().uptimeNanoseconds
      samples.append(Double(end - start) / 1_000_000)
    }
    return samples.sorted()[samples.count / 2]
  }

  // swiftlint:disable:next identifier_name
  private func range(from: Int, to: Int, in item: HistoryItemDecorator) -> Range<String.Index> {
    let startIndex = item.title.startIndex
    let lowerBound = item.title.index(startIndex, offsetBy: from)
    let upperBound = item.title.index(startIndex, offsetBy: to + 1)

    return lowerBound..<upperBound
  }

  @MainActor
  private func historyItemWithTitle(_ value: String?) -> HistoryItem {
    let contents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: value?.data(using: .utf8)
      )
    ]
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = contents
    item.title = item.generateTitle()

    return item
  }
}
