import XCTest
import Defaults
@testable import WitsCopy

// swiftlint:disable force_try
@MainActor
class HistoryItemTests: XCTestCase {
  func testTitleForString() {
    let title = "foo"
    let item = historyItem(title)
    XCTAssertEqual(item.title, title)
  }

  func testTitleWithWhitespaces() {
    let title = "   foo bar   "
    let item = historyItem(title)
    XCTAssertEqual(item.title, "···foo bar···")
  }

  func testTitleWithNewlines() {
    let title = "\nfoo\nbar\n"
    let item = historyItem(title)
    XCTAssertEqual(item.title, "⏎foo⏎bar⏎")
  }

  func testTitleWithTabs() {
    let title = "\tfoo\tbar\t"
    let item = historyItem(title)
    XCTAssertEqual(item.title, "⇥foo⇥bar⇥")
  }

  func testTitleWithRTF() {
    let rtf = NSAttributedString(string: "foo").rtf(
      from: NSRange(0...2),
      documentAttributes: [:]
    )
    let item = historyItem(rtf, .rtf)
    XCTAssertEqual(item.title, "foo")
  }

  func testTitleWithHTML() {
    let html = "<a href='#'>foo</a>".data(using: .utf8)
    let item = historyItem(html, .html)
    XCTAssertEqual(item.title, "foo")
  }

  func testImage() {
    let image = NSImage(named: "NSBluetoothTemplate")!
    let item = historyItem(image)
    XCTAssertEqual(item.title, "")
  }

  func testFile() {
    let url = URL(fileURLWithPath: "/tmp/foo.bar")
    let item = historyItem(url)
    XCTAssertEqual(item.title, "file:///tmp/foo.bar")
  }

  func testFileWithEscapedChars() {
    let url = URL(fileURLWithPath: "/tmp/产品培训/产品培训.txt")
    let item = historyItem(url)
    XCTAssertEqual(item.title, "file:///tmp/产品培训/产品培训.txt")
  }

  func testTextFromUniversalClipboard() {
    let url = URL(fileURLWithPath: "/tmp/foo.bar")
    let fileURLContent = HistoryItemContent(
      type: NSPasteboard.PasteboardType.fileURL.rawValue,
      value: url.dataRepresentation
    )
    let textContent = HistoryItemContent(
      type: NSPasteboard.PasteboardType.string.rawValue,
      value: url.lastPathComponent.data(using: .utf8)
    )
    let universalClipboardContent = HistoryItemContent(
      type: NSPasteboard.PasteboardType.universalClipboard.rawValue,
      value: "".data(using: .utf8)
    )
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = [fileURLContent, textContent, universalClipboardContent]
    item.title = item.generateTitle()
    XCTAssertEqual(item.title, "foo.bar")
  }

  func testImageFromUniversalClipboard() {
    let url = Bundle(for: type(of: self)).url(forResource: "guy", withExtension: "jpeg")!
    let fileURLContent = HistoryItemContent(
      type: NSPasteboard.PasteboardType.fileURL.rawValue,
      value: url.dataRepresentation
    )
    let universalClipboardContent = HistoryItemContent(
      type: NSPasteboard.PasteboardType.universalClipboard.rawValue,
      value: "".data(using: .utf8)
    )
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = [fileURLContent, universalClipboardContent]
    XCTAssertEqual(item.image!.tiffRepresentation, NSImage(data: try! Data(contentsOf: url))!.tiffRepresentation)
  }

  func testFileFromUniversalClipboard() {
    let url = URL(fileURLWithPath: "/tmp/foo.bar")
    let fileURLContent = HistoryItemContent(
      type: NSPasteboard.PasteboardType.fileURL.rawValue,
      value: url.dataRepresentation
    )
    let universalClipboardContent = HistoryItemContent(
      type: NSPasteboard.PasteboardType.universalClipboard.rawValue,
      value: "".data(using: .utf8)
    )
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = [fileURLContent, universalClipboardContent]
    item.title = item.generateTitle()
    XCTAssertEqual(item.title, "file:///tmp/foo.bar")
  }

  func testItemWithoutData() {
    let item = historyItem(nil)
    XCTAssertEqual(item.title, "")
  }

  func testSeveralItemsCanHaveEmptyPin() {
    let item1 = historyItem("foo")
    item1.pin = ""
    let item2 = historyItem("bar")
    item2.pin = ""
    XCTAssertNoThrow(try Storage.shared.context.save())
    XCTAssertEqual(item1.pin, "")
    XCTAssertEqual(item2.pin, "")
  }

  func testGenerateTitleDoesNotDecodeOrRecognizeImage() async {
    let image = NSImage(named: "NSBluetoothTemplate")!
    let item = historyItem(image)
    let before = item.imageMaterializations
    _ = item.generateTitle()
    try? await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(item.title, "")
    XCTAssertEqual(item.imageMaterializations, before)
    XCTAssertFalse(item.title.contains("NSBluetooth"))
  }

  func testManualImageTitleIsNotReplacedByGenerateTitle() {
    let image = NSImage(named: "NSBluetoothTemplate")!
    let item = historyItem(image)
    item.title = "手工标题"
    XCTAssertEqual(item.generateTitle(), "手工标题")
    XCTAssertEqual(item.title, "手工标题")
  }

  func testHasImagePayloadDoesNotMaterializeBitmap() {
    let image = NSImage(named: "NSBluetoothTemplate")!
    let item = historyItem(image)
    XCTAssertEqual(item.imageMaterializations, 0)
    XCTAssertTrue(item.hasImagePayload)
    XCTAssertEqual(item.contentKind, .image)
    let decorator = HistoryItemDecorator(item)
    XCTAssertTrue(decorator.hasImage)
    XCTAssertEqual(item.imageMaterializations, 0)
  }

  func testMovieFileURLIsVideoAndPDFStaysFile() {
    let movie = historyItem(URL(fileURLWithPath: "/tmp/lab/clip.mp4"))
    XCTAssertEqual(movie.contentKind, .video)
    XCTAssertTrue(HistoryItem.isMovieFile(URL(fileURLWithPath: "/tmp/lab/clip.mov")))
    let pdf = historyItem(URL(fileURLWithPath: "/tmp/lab/notes.pdf"))
    XCTAssertEqual(pdf.contentKind, .file)
    let textFile = historyItem(URL(fileURLWithPath: "/tmp/lab/notes.txt"))
    XCTAssertEqual(textFile.contentKind, .file)
    let png = historyItem(NSImage(named: "NSBluetoothTemplate")!)
    XCTAssertEqual(png.contentKind, .image)
  }

  func testAccurateOCRReturnsBilingualMarker() async throws {
    let data = try fixtureData("ocr-bilingual.png")
    let metrics = PreviewMetrics()
    let text = OCRReadingOrder.plainText(try await PreviewRecognizer.recognize(data: data, metrics: metrics))
    XCTAssertTrue(text.contains("WIT OCR 2026"), text)
    XCTAssertTrue(text.contains("剪贴板预览测试"), text)
    XCTAssertNotEqual(text, "ocr-bilingual.png")
    XCTAssertEqual(metrics.snapshot().recognizerStarts, 1)
  }

  func testStaleOCRTokenDoesNotReplaceCurrentResult() async throws {
    let first = try fixtureData("ocr-bilingual.png")
    let second = try fixtureData("ocr-second.png")
    let metrics = PreviewMetrics()
    let session = PreviewSession(metrics: metrics)
    let token = try XCTUnwrap(session.begin(allowed: true, identity: "first"))
    var shown = ""
    let bilingual = OCRReadingOrder.plainText(try await PreviewRecognizer.recognize(data: first, metrics: metrics))
    XCTAssertTrue(session.deliver(token: token, text: bilingual) { shown = $0 })
    session.cancel()
    let other = OCRReadingOrder.plainText(try await PreviewRecognizer.recognize(data: second, metrics: metrics))
    XCTAssertTrue(other.contains("SECOND IMAGE 482"), other)
    XCTAssertFalse(session.deliver(token: token, text: other) { shown = $0 })
    XCTAssertTrue(shown.contains("WIT OCR 2026"))
    XCTAssertFalse(shown.contains("SECOND IMAGE 482"))
  }

  func testGIFTimelineUsesSourceDelays() throws {
    let data = try fixtureData("timing-irregular.gif")
    let timeline = try XCTUnwrap(GIFTimeline.read(data: data))
    XCTAssertEqual(timeline.playbackDelays.count, 4)
    XCTAssertEqual(timeline.playbackDelays[0], 0.12, accuracy: 0.001)
    XCTAssertEqual(timeline.playbackDelays[1], 0.64, accuracy: 0.001)
    XCTAssertEqual(timeline.playbackDelays[2], 0.18, accuracy: 0.001)
    XCTAssertEqual(timeline.playbackDelays[3], 0.82, accuracy: 0.001)
    XCTAssertEqual(timeline.duration, 1.76, accuracy: 0.001)
    XCTAssertEqual(timeline.frameIndex(at: 0), 0)
    XCTAssertEqual(timeline.frameIndex(at: 0.11), 0)
    XCTAssertEqual(timeline.frameIndex(at: 0.12), 1)
    XCTAssertEqual(timeline.frameIndex(at: 0.76), 2)
    XCTAssertEqual(timeline.frameIndex(at: 1.0), 3)
    XCTAssertEqual(timeline.frameIndex(at: 1.76), 0)
  }

  func testPositiveUnclampedGIFDelayIsNotRaisedToTenth() {
    XCTAssertEqual(GIFTimeline.resolve(unclamped: 0.01, delay: 0.1), 0.01, accuracy: 0.0001)
    XCTAssertEqual(GIFTimeline.resolve(unclamped: 0, delay: 0.1), 0.1, accuracy: 0.0001)
    XCTAssertEqual(GIFTimeline.resolve(unclamped: 0, delay: 0), 0.1, accuracy: 0.0001)
    XCTAssertEqual(GIFTimeline.resolve(unclamped: nil, delay: nil), 0.1, accuracy: 0.0001)
  }

  func testClassifierRoutesSyntheticFixtures() {
    XCTAssertEqual(PreviewClassifier.kind(filename: "plain.txt"), .plain)
    XCTAssertEqual(PreviewClassifier.kind(filename: "readme.md"), .markdown)
    XCTAssertEqual(PreviewClassifier.kind(filename: "sample.swift"), .code)
    XCTAssertEqual(PreviewClassifier.kind(filename: "sample.py"), .code)
    XCTAssertEqual(PreviewClassifier.kind(filename: "sample.json"), .code)
    XCTAssertEqual(PreviewClassifier.kind(filename: "timing-irregular.gif"), .gif)
    XCTAssertEqual(PreviewClassifier.kind(filename: "ocr-bilingual.png"), .image)
    XCTAssertEqual(PreviewClassifier.kind(filename: "two-page-selectable.pdf"), .pdf)
    XCTAssertEqual(PreviewClassifier.kind(filename: "sample.docx"), .office)
    XCTAssertEqual(PreviewClassifier.kind(filename: "clip"), .fallback)
    XCTAssertEqual(PreviewClassifier.languageLabel(filename: "sample.swift", mode: nil), "Swift")
    XCTAssertEqual(PreviewClassifier.languageLabel(filename: "sample.py", mode: nil), "Python")
    XCTAssertEqual(PreviewClassifier.languageLabel(filename: "sample.json", mode: nil), "JSON")
    let missing = URL(fileURLWithPath: "/tmp/maccy-v03-missing-\(UUID().uuidString).txt")
    let source = PreviewSource(
      identity: "missing",
      title: "quote",
      text: nil,
      image: nil,
      fileURLs: [missing],
      filename: missing.lastPathComponent,
      fileExists: false,
      application: nil,
      firstCopiedAt: .now,
      lastCopiedAt: .now,
      numberOfCopies: 1,
      pixelSize: nil
    )
    XCTAssertEqual(PreviewClassifier.classify(source: source), .missing)
  }

  func testMarkdownReadingStructureDoesNotLoadRemoteImage() throws {
    let text = try String(contentsOf: fixtureURL("readme.md"), encoding: .utf8)
    let render = PreviewTextRenderer.render(text: text, filename: "readme.md", mode: nil)
    XCTAssertEqual(render.structure.headings, ["Preview heading"])
    XCTAssertTrue(render.structure.listItems.contains("中文条目"))
    XCTAssertEqual(render.structure.fencedLanguages, ["swift"])
    XCTAssertTrue(render.structure.fencedBodies.joined().contains("WIT"))
    XCTAssertTrue(render.structure.tableRows.contains(["Local", "2026"]))
    XCTAssertTrue(render.structure.links.contains("https://example.invalid/"))
    XCTAssertTrue(render.structure.remoteImagesSkipped.contains("https://example.invalid/no-network.png"))
    XCTAssertTrue(render.structure.hasDistinctHeading)
    XCTAssertFalse(render.attributed.string.contains("https://example.invalid/no-network.png"))
    let heading = (render.attributed.string as NSString).range(of: "Preview heading")
    let font = render.attributed.attribute(.font, at: heading.location, effectiveRange: nil) as? NSFont
    XCTAssertGreaterThan(font?.pointSize ?? 0, 16)
  }

  func testCodePreviewIsMonospacedAndCanFallBackToPlain() throws {
    let text = try String(contentsOf: fixtureURL("sample.swift"), encoding: .utf8)
    let code = PreviewTextRenderer.render(text: text, filename: "sample.swift", mode: nil)
    XCTAssertEqual(code.languageLabel, "Swift")
    XCTAssertTrue(code.monospace)
    XCTAssertTrue(code.structure.keywordColored)
    XCTAssertEqual(code.lineCount, 9)
    XCTAssertTrue(code.lineNumbers.contains("1"))
    XCTAssertTrue(code.attributed.string.contains("Hello, 世界"))
    let keyword = (code.attributed.string as NSString).range(of: "struct")
    let color = code.attributed.attribute(.foregroundColor, at: keyword.location, effectiveRange: nil) as? NSColor
    XCTAssertNotEqual(color, NSColor.labelColor)
    let plain = PreviewTextRenderer.render(text: text, filename: "sample.swift", mode: .plain)
    XCTAssertFalse(plain.monospace)
    XCTAssertEqual(plain.languageLabel, "Plain")
  }

  func testLargeTextPreviewTruncatesWithoutChangingSource() throws {
    let url = fixtureURL("large.txt")
    let metrics = PreviewMetrics()
    let session = PreviewSession(metrics: metrics)
    let token = try XCTUnwrap(session.begin(allowed: true, identity: "large"))
    let read = try XCTUnwrap(PreviewFileAccess.readIfCurrent(
      url: url,
      limit: PreviewLimits.maxTextReadBytes,
      metrics: metrics,
      isCurrent: { session.isCurrent(token) }
    ))
    XCTAssertEqual(metrics.snapshot().fileReads, 1)
    XCTAssertEqual(read.totalBytes, 1_320_000)
    XCTAssertFalse(read.truncated)
    let full = try XCTUnwrap(String(data: read.data, encoding: .utf8))
    let render = PreviewTextRenderer.render(text: full, filename: "large.txt", mode: nil)
    XCTAssertTrue(render.truncated)
    XCTAssertLessThan(render.display.count, full.count)
    XCTAssertEqual(render.full, full)
    XCTAssertTrue(render.full.hasPrefix("Line 000000"))
    session.cancel()
    let blocked = PreviewFileAccess.readIfCurrent(
      url: url,
      limit: 32,
      metrics: metrics,
      isCurrent: { session.isCurrent(token) }
    )
    XCTAssertNil(blocked)
    XCTAssertEqual(metrics.snapshot().fileReads, 1)
  }

  func testDocxExtractionIsRealBodyNotFilename() throws {
    let data = try fixtureData("sample.docx")
    let text = try XCTUnwrap(OfficeTextExtractor.extractDocx(data))
    XCTAssertTrue(text.contains("WIT WORD DOCUMENT"), text)
    XCTAssertTrue(text.contains("中文内容：这是真实的合成 DOCX 文件。"), text)
    XCTAssertFalse(text.contains("sample.docx"))
  }

  func testHiddenPreviewSessionDoesNotReadOrRecognize() {
    let metrics = PreviewMetrics()
    let session = PreviewSession(metrics: metrics)
    let before = metrics.snapshot()
    for index in 0..<100 {
      XCTAssertNil(session.begin(allowed: false, identity: "hidden-\(index)"))
    }
    let after = metrics.snapshot()
    XCTAssertEqual(after.previewStarts, before.previewStarts)
    XCTAssertEqual(after.recognizerStarts, before.recognizerStarts)
    XCTAssertEqual(after.fileReads, before.fileReads)
    XCTAssertEqual(session.activeHeavy, 0)
    XCTAssertEqual(after.peakHeavy, 0)
  }

  func testBeginDoesNotPretendAJobRan() {
    let metrics = PreviewMetrics()
    let session = PreviewSession(metrics: metrics)
    XCTAssertNotNil(session.begin(allowed: true, identity: "visible"))
    XCTAssertEqual(session.activeHeavy, 1)
    XCTAssertEqual(metrics.snapshot().visibleSessions, 1)
    XCTAssertEqual(metrics.snapshot().peakJobs, 0)
    XCTAssertEqual(metrics.snapshot().peakHeavy, 0)
    XCTAssertEqual(metrics.snapshot().executingJobs, 0)
  }

  func testDocumentReadHonorsThirtyTwoMegabyteLimit() async throws {
    let size = 5 * 1024 * 1024
    let url = try writeTemp(count: size, prefix: 0x61, suffix: 0x62)
    defer { try? FileManager.default.removeItem(at: url) }
    let metrics = PreviewMetrics()
    let session = PreviewSession(metrics: metrics)
    let token = try XCTUnwrap(session.begin(allowed: true, identity: "five"))
    let read = await PreviewFileAccess.read(
      url: url,
      limit: PreviewLimits.maxDocumentBytes,
      policy: .complete,
      metrics: metrics,
      permit: session.currentReadPermit
    )
    let value = try XCTUnwrap(read)
    XCTAssertEqual(value.data.count, size)
    XCTAssertEqual(value.data.first, 0x61)
    XCTAssertEqual(value.data.last, 0x62)
    XCTAssertFalse(value.truncated)
    XCTAssertFalse(value.refusedPartial)
    XCTAssertEqual(value.totalBytes, size)
    XCTAssertTrue(session.isCurrent(token))
    let sync = try XCTUnwrap(PreviewFileAccess.readIfCurrent(
      url: url,
      limit: PreviewLimits.maxDocumentBytes,
      metrics: metrics,
      isCurrent: { session.isCurrent(token) }
    ))
    XCTAssertEqual(sync.data.count, size)
    XCTAssertFalse(sync.truncated)
  }

  func testCompleteOverLimitRefusesPartialAndUnknownSizeStopsEarly() {
    var calls = 0
    let refused = PreviewFileAccess.applyLimit(
      knownSize: 5 * 1024 * 1024,
      limit: 1024,
      policy: .complete
    ) { _ in
      calls += 1
      return Data(repeating: 1, count: 1024)
    }
    XCTAssertEqual(calls, 0)
    XCTAssertTrue(refused.refusedPartial)
    XCTAssertTrue(refused.data.isEmpty)
    XCTAssertEqual(refused.totalBytes, 5 * 1024 * 1024)
    let text = PreviewFileAccess.applyLimit(knownSize: 5_000, limit: 1_024, policy: .text) { count in
      XCTAssertEqual(count, 1_024)
      return Data(repeating: 0x41, count: count)
    }
    XCTAssertEqual(text.data.count, 1_024)
    XCTAssertTrue(text.truncated)
    XCTAssertFalse(text.refusedPartial)
    let unknown = PreviewFileAccess.applyLimit(knownSize: nil, limit: 1_024, policy: .complete) { count in
      XCTAssertEqual(count, 1_025)
      return Data(repeating: 9, count: count)
    }
    XCTAssertTrue(unknown.refusedPartial)
    XCTAssertTrue(unknown.data.isEmpty)
    XCTAssertEqual(unknown.totalBytes, 1_025)
    let short = PreviewFileAccess.applyLimit(
      knownSize: nil,
      limit: PreviewLimits.maxDocumentBytes,
      policy: .complete
    ) { count in
      Data(repeating: 2, count: min(count, 5 * 1024 * 1024))
    }
    XCTAssertEqual(short.data.count, 5 * 1024 * 1024)
    XCTAssertFalse(short.truncated)
    XCTAssertFalse(short.refusedPartial)
  }

  func testCancelledPermitDoesNotStartReadOrCommit() async throws {
    let metrics = PreviewMetrics()
    let session = PreviewSession(metrics: metrics)
    let token = try XCTUnwrap(session.begin(allowed: true, identity: "old"))
    let permit = session.currentReadPermit
    session.cancel()
    let read = await PreviewFileAccess.read(
      url: fixtureURL("large.txt"),
      limit: PreviewLimits.maxDocumentBytes,
      policy: .complete,
      metrics: metrics,
      permit: permit
    )
    XCTAssertNil(read)
    XCTAssertFalse(session.isCurrent(token))
    XCTAssertEqual(metrics.snapshot().fileReads, 0)
    XCTAssertEqual(metrics.snapshot().peakJobs, 0)
    XCTAssertEqual(metrics.snapshot().executingJobs, 0)
    XCTAssertFalse(session.deliver(token: token, text: "late") { _ in })
  }

  func testSmallGIFStreamsInsideDecodedBudget() async throws {
    let data = try fixtureData("timing-irregular.gif")
    let opened = GIFFrameProvider.open(data: data, maxEdge: 256)
    guard case .stream(let provider) = opened else {
      return XCTFail("ordinary gif was refused")
    }
    XCTAssertEqual(provider.frameCount, 4)
    XCTAssertEqual(provider.timeline.playbackDelays[0], 0.12, accuracy: 0.001)
    let first = await provider.frame(at: 0)
    let cached = await provider.frame(at: 0)
    XCTAssertNotNil(first)
    XCTAssertNotNil(cached)
    XCTAssertEqual(provider.decodeCount, 1)
    XCTAssertGreaterThanOrEqual(provider.cacheHits, 1)
    for index in 0..<4 {
      let frame = await provider.frame(at: index)
      XCTAssertNotNil(frame)
    }
    XCTAssertLessThanOrEqual(provider.cachedFrameCount, PreviewLimits.maxCachedGIFFrames)
    XCTAssertLessThanOrEqual(provider.peakCachedBytes, PreviewLimits.maxDecodedFrameBytes)
    provider.release()
    let afterRelease = await provider.frame(at: 1)
    XCTAssertNil(afterRelease)
    XCTAssertEqual(provider.cachedFrameCount, 0)
  }

  func testUnclampedHundredthDelayIsNotRaised() {
    let timeline = GIFTimeline(
      rawDelays: [0.01, 0.01],
      playbackDelays: [0.01, 0.01],
      duration: 0.02
    )
    XCTAssertEqual(timeline.secondsUntilNextBoundary(after: 0), 0.01, accuracy: 0.0000001)
    let nanos = UInt64((timeline.secondsUntilNextBoundary(after: 0) * 1_000_000_000).rounded())
    XCTAssertEqual(nanos, 10_000_000)
    XCTAssertNotEqual(nanos, 100_000_000)
    let irregular = GIFTimeline(
      rawDelays: [0.12, 0.64, 0.18, 0.82],
      playbackDelays: [0.12, 0.64, 0.18, 0.82],
      duration: 1.76
    )
    XCTAssertEqual(irregular.secondsUntilNextBoundary(after: 0.11), 0.01, accuracy: 0.0001)
  }

  func testDecodedFrameBudgetRejectsUnboundedMath() {
    let one = GIFFrameBudget.estimatedBytes(width: 2_048, height: 2_048, maxEdge: 2_048)
    XCTAssertLessThanOrEqual(one, PreviewLimits.maxDecodedFrameBytes)
    XCTAssertGreaterThan(one * 3, PreviewLimits.maxDecodedFrameBytes)
    XCTAssertEqual(GIFFrameBudget.fittingEdge(width: 20_000, height: 20_000, budget: 1_024, preferred: 2_048), 16)
    XCTAssertNil(GIFFrameBudget.fittingEdge(width: 20_000, height: 20_000, budget: 1_024 - 1, preferred: 2_048))
    let edge = GIFFrameBudget.fittingEdge(
      width: 8_000,
      height: 8_000,
      budget: PreviewLimits.maxDecodedFrameBytes,
      preferred: 2_048
    )
    XCTAssertNotNil(edge)
    XCTAssertLessThanOrEqual(edge ?? Int.max, 2_048)
  }

  func testExtensionlessUTF8IsPlainAndBinaryIsNotDecodable() async throws {
    XCTAssertEqual(PreviewClassifier.kind(filename: "clip"), .fallback)
    XCTAssertEqual(PreviewClassifier.kind(filename: "plain.txt"), .plain)
    XCTAssertEqual(PreviewClassifier.kind(filename: "readme.md"), .markdown)
    XCTAssertEqual(PreviewClassifier.kind(filename: "sample.swift"), .code)
    let bom = Data([0xEF, 0xBB, 0xBF]) + Data("WIT 无扩展名".utf8)
    let text = PreviewClassifier.sniffExtensionless(bom)
    XCTAssertEqual(text.kind, .plain)
    XCTAssertFalse(text.textRejected)
    XCTAssertNil(text.notice)
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    let binary = PreviewClassifier.sniffExtensionless(png)
    XCTAssertEqual(binary.kind, .fallback)
    XCTAssertEqual(binary.notice, .cannotDecode)
    XCTAssertTrue(binary.textRejected)
    let notes = FileManager.default.temporaryDirectory
      .appendingPathComponent("maccy-v03-notes-\(UUID().uuidString)")
    let blob = FileManager.default.temporaryDirectory
      .appendingPathComponent("maccy-v03-blob-\(UUID().uuidString)")
    try Data("hello\n中文\n".utf8).write(to: notes)
    try Data("%PDF-1.4\nnot text".utf8).write(to: blob)
    defer {
      try? FileManager.default.removeItem(at: notes)
      try? FileManager.default.removeItem(at: blob)
    }
    let metrics = PreviewMetrics()
    let session = PreviewSession(metrics: metrics)
    _ = session.begin(allowed: true, identity: "extless")
    let notesRoute = await PreviewClassifier.resolve(
      source: fileSource(notes),
      metrics: metrics,
      permit: session.currentReadPermit
    )
    let notesValue = try XCTUnwrap(notesRoute)
    XCTAssertEqual(notesValue.kind, .plain)
    XCTAssertFalse(notesValue.textRejected)
    let blobRoute = await PreviewClassifier.resolve(
      source: fileSource(blob),
      metrics: metrics,
      permit: session.currentReadPermit
    )
    let blobValue = try XCTUnwrap(blobRoute)
    XCTAssertEqual(blobValue.kind, .fallback)
    XCTAssertTrue(blobValue.textRejected)
    XCTAssertEqual(blobValue.notice, .cannotDecode)
  }

  func testSessionCancelCancelsRecognitionTicket() {
    let session = PreviewSession()
    _ = session.begin(allowed: true, identity: "ocr")
    let ticket = PreviewRecognitionTicket()
    session.trackRecognition(ticket)
    session.cancel()
    XCTAssertGreaterThanOrEqual(ticket.cancellationCount(), 1)
    XCTAssertEqual(session.visibleSessions, 0)
    XCTAssertEqual(session.activeHeavy, 0)
  }

  func testAlreadyCancelledRecognizerDoesNotStartVision() async {
    let ticket = PreviewRecognitionTicket()
    let metrics = PreviewMetrics()
    let task = Task { @MainActor in
      try await PreviewRecognizer.recognize(data: Data(), metrics: metrics, ticket: ticket)
    }
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("unexpected \(error)")
    }
    XCTAssertGreaterThanOrEqual(ticket.cancellationCount(), 1)
    XCTAssertEqual(metrics.snapshot().recognizerStarts, 0)
    XCTAssertEqual(metrics.snapshot().peakJobs, 0)
  }

  private func fixtureURL(_ name: String) -> URL {
    TestFixtures.url(name)
  }

  private func fixtureData(_ name: String) throws -> Data {
    try TestFixtures.data(name)
  }

  private func fileSource(_ url: URL) -> PreviewSource {
    PreviewSource(
      identity: url.lastPathComponent,
      title: url.lastPathComponent,
      text: nil,
      image: nil,
      fileURLs: [url],
      filename: url.lastPathComponent,
      fileExists: nil,
      application: nil,
      firstCopiedAt: .now,
      lastCopiedAt: .now,
      numberOfCopies: 1,
      pixelSize: nil
    )
  }

  private func writeTemp(count: Int, prefix: UInt8, suffix: UInt8) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("maccy-v03-\(UUID().uuidString).bin")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    let chunk = Data(repeating: prefix, count: 1024 * 1024)
    var remaining = count
    while remaining > 0 {
      let slice = min(remaining, chunk.count)
      if slice == chunk.count {
        try handle.write(contentsOf: chunk)
      } else {
        try handle.write(contentsOf: chunk.prefix(slice))
      }
      remaining -= slice
    }
    if count > 0 {
      try handle.seek(toOffset: UInt64(count - 1))
      try handle.write(contentsOf: Data([suffix]))
    }
    return url
  }

  private func historyItem(_ value: String?) -> HistoryItem {
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

  private func historyItem(_ data: Data?, _ type: NSPasteboard.PasteboardType) -> HistoryItem {
    let contents = [
      HistoryItemContent(
        type: type.rawValue,
        value: data
      )
    ]
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = contents
    item.title = item.generateTitle()

    return item
  }

  private func historyItem(_ value: NSImage) -> HistoryItem {
    let contents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.tiff.rawValue,
        value: value.tiffRepresentation!
      )
    ]
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = contents
    item.title = item.generateTitle()

    return item
  }

  private func historyItem(_ value: URL) -> HistoryItem {
    let contents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.fileURL.rawValue,
        value: value.dataRepresentation
      ),
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: value.lastPathComponent.data(using: .utf8)
      )
    ]
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = contents
    item.title = item.generateTitle()

    return item
  }
}
// swiftlint:enable force_try
