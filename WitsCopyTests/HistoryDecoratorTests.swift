import AppKit
import SwiftUI
import XCTest
import Defaults
@testable import WitsCopy

@MainActor
class HistoryItemDecoratorTests: XCTestCase {
  let boldFont = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
  let savedHighlightMatch = Defaults[.highlightMatch]
  let savedImageMaxHeight = Defaults[.imageMaxHeight]

  var firstCopiedAt: Date! {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
    return formatter.date(from: "2020/07/10 12:31:34")
  }

  var lastCopiedAt: Date! {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
    return formatter.date(from: "2020/07/10 12:41:34")
  }

  override func setUp() {
    super.setUp()
    Defaults[.highlightMatch] = .bold
    Defaults[.imageMaxHeight] = 40
  }

  override func tearDown() {
    super.tearDown()
    Defaults[.imageMaxHeight] = savedImageMaxHeight
    Defaults[.highlightMatch] = savedHighlightMatch
  }

  func testString() {
    let title = "foo"
    let itemDecorator = historyItemDecorator(title)
    XCTAssertEqual(itemDecorator.title, title)
    XCTAssertNil(itemDecorator.previewImage)
    XCTAssertNil(itemDecorator.thumbnailImage)
  }

  func testRowExcerptUsesBoundedPlainTextWithoutConvertingRichPayloads() {
    let plainItem = HistoryItem(contents: [
      HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue,
                         value: Data((String(repeating: "中", count: 360) + "tail").utf8))
    ])
    plainItem.title = "short alias"
    let plain = HistoryItemDecorator(plainItem)
    XCTAssertEqual(plain.rowExcerpt, String(repeating: "中", count: 180))
    let richItem = HistoryItem(contents: [
      HistoryItemContent(type: NSPasteboard.PasteboardType.html.rawValue,
                         value: Data("<html><body><p>rich-body-must-stay-in-preview</p></body></html>".utf8))
    ])
    richItem.title = "Saved rich title"
    let rich = HistoryItemDecorator(richItem)
    XCTAssertEqual(rich.rowExcerpt, "", "history rows should use the saved title, not run a rich-document converter")
    XCTAssertEqual(rich.title, "Saved rich title")
  }

  func testRTF() {
    let rtf = NSAttributedString(string: "foo").rtf(
      from: NSRange(0...2),
      documentAttributes: [:]
    )
    let itemDecorator = historyItemDecorator(rtf, .rtf)
    XCTAssertEqual(itemDecorator.title, "foo")
    XCTAssertNil(itemDecorator.previewImage)
    XCTAssertNil(itemDecorator.thumbnailImage)
  }

  func testHTML() {
    let html = "<a href='#'>foo</a>".data(using: .utf8)
    let itemDecorator = historyItemDecorator(html, .html)
    XCTAssertEqual(itemDecorator.title, "foo")
    XCTAssertNil(itemDecorator.previewImage)
    XCTAssertNil(itemDecorator.thumbnailImage)
  }

  func testImage() {
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let image = NSImage(size: NSSize(width: 16, height: 16))
    image.addRepresentation(rep)
    let itemDecorator = historyItemDecorator(image)
    XCTAssertEqual(itemDecorator.title, "")
  }

  func testFile() {
    let url = URL(fileURLWithPath: "/tmp/foo.bar")
    let itemDecorator = historyItemDecorator(url)
    XCTAssertEqual(itemDecorator.title, "file:///tmp/foo.bar")
    XCTAssertNil(itemDecorator.previewImage)
    XCTAssertNil(itemDecorator.thumbnailImage)
  }

  func testFileWithEscapedChars() {
    let url = URL(fileURLWithPath: "/tmp/产品培训/产品培训.txt")
    let itemDecorator = historyItemDecorator(url)
    XCTAssertEqual(itemDecorator.title, "file:///tmp/产品培训/产品培训.txt")
    XCTAssertNil(itemDecorator.previewImage)
    XCTAssertNil(itemDecorator.thumbnailImage)
  }

  func testItemWithoutData() {
    let itemDecorator = historyItemDecorator(nil)
    XCTAssertEqual(itemDecorator.title, "")
    XCTAssertNil(itemDecorator.previewImage)
    XCTAssertNil(itemDecorator.thumbnailImage)
  }

  func testUnpinnedByDefault() {
    let itemDecorator = historyItemDecorator("foo")
    XCTAssertNil(itemDecorator.item.pin)
    XCTAssertFalse(itemDecorator.isPinned)
  }

  func testPin() {
    let itemDecorator = historyItemDecorator("foo")
    itemDecorator.togglePin()
    XCTAssertNotNil(itemDecorator.item.pin)
    XCTAssertTrue(itemDecorator.isPinned)
  }

  func testUnpin() {
    let itemDecorator = historyItemDecorator("foo")
    itemDecorator.togglePin()
    itemDecorator.togglePin()
    XCTAssertNil(itemDecorator.item.pin)
    XCTAssertFalse(itemDecorator.isPinned)
  }

  func testHighlight() {
    let itemDecorator = historyItemDecorator("foo bar baz")
    itemDecorator.highlight("random", [
      range(from: 1, to: 2, in: itemDecorator),
      range(from: 8, to: 10, in: itemDecorator)
    ])
    var expectedTitle = AttributedString("foo bar baz")
    expectedTitle[expectedTitle.range(of: "oo")!].font = .bold(.body)()
    expectedTitle[expectedTitle.range(of: "baz")!].font = .bold(.body)()
    XCTAssertEqual(itemDecorator.attributedTitle, expectedTitle)
    itemDecorator.highlight("", [])
    XCTAssertEqual(itemDecorator.attributedTitle, nil)
  }

  func testSetMembershipSurvivesTitleAndTagChanges() {
    let decorator = historyItemDecorator("foo")
    var selected: Set<HistoryItemDecorator> = [decorator]
    decorator.title = "手工标题"
    decorator.attributedTitle = AttributedString("手工标题")
    decorator.noteTagsChanged()
    XCTAssertTrue(selected.contains(decorator))
    XCTAssertEqual(selected.first?.title, "手工标题")
    XCTAssertNotNil(selected.remove(decorator))
  }

  func testThumbnailCommitDropsStaleGeneration() {
    let image = NSImage(named: "NSApplicationIcon")!
    let decorator = historyItemDecorator(image)
    let generation = decorator.beginThumbnailGenerationForTest()
    decorator.invalidateImageGenerationForTest()
    decorator.commitThumbnailForTest(NSImage(size: NSSize(width: 8, height: 8)), generation: generation)
    XCTAssertNil(decorator.thumbnailImage)
    let current = decorator.beginThumbnailGenerationForTest()
    let published = NSImage(size: NSSize(width: 9, height: 9))
    decorator.commitThumbnailForTest(published, generation: current)
    XCTAssertTrue(decorator.thumbnailImage === published)
  }

  func testSwitchingPreviewKeepsASingleHeavySession() {
    let metrics = PreviewMetrics()
    let session = PreviewSession(metrics: metrics)
    var tokens: [UInt64] = []
    for index in 0..<20 {
      let token = session.begin(allowed: true, identity: "item-\(index)")
      XCTAssertNotNil(token)
      tokens.append(token!)
      XCTAssertEqual(session.activeHeavy, 1)
    }
    XCTAssertEqual(metrics.snapshot().previewStarts, 20)
    XCTAssertEqual(metrics.snapshot().visibleSessions, 1)
    XCTAssertEqual(metrics.snapshot().peakJobs, 0)
    XCTAssertEqual(metrics.snapshot().executingJobs, 0)
    XCTAssertTrue(session.isCurrent(tokens.last!))
    XCTAssertFalse(session.isCurrent(tokens.first!))
    session.cancel()
    XCTAssertEqual(session.activeHeavy, 0)
    XCTAssertFalse(session.isCurrent(tokens.last!))
  }

  func testQuickLookHostRebuildsInsteadOfReusingClosedView() throws {
    let pdf = fixtureURL("two-page-selectable.pdf")
    let docx = fixtureURL("sample.docx")
    XCTAssertTrue(FileManager.default.fileExists(atPath: pdf.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: docx.path))
    let host = PreviewQLHost(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
    let urls = [pdf, docx]
    for index in 0..<40 {
      host.install(url: urls[index % urls.count], sessionID: "switch-\(index)")
    }
    XCTAssertEqual(host.illegalNonNilAssignments, 0)
    XCTAssertGreaterThan(host.installations, 1)
    XCTAssertNotNil(host.livePreview)
    host.releaseAll()
    XCTAssertNil(host.livePreview)
    let reopened = PreviewQLHost(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
    reopened.install(url: pdf, sessionID: "reopen")
    reopened.install(url: docx, sessionID: "reopen-other")
    reopened.releaseAll()
    XCTAssertEqual(reopened.illegalNonNilAssignments, 0)
    XCTAssertEqual(host.illegalNonNilAssignments, 0)
  }

  func testMalformedGIFDelaysCannotCreateBusyLoopOrOverflow() {
    XCTAssertEqual(GIFTimeline.resolve(unclamped: .infinity, delay: .nan), PreviewLimits.zeroGIFDelay)
    XCTAssertEqual(GIFTimeline.resolve(unclamped: .nan, delay: 0.64), 0.64)
    XCTAssertEqual(GIFTimeline.resolve(unclamped: 0.01, delay: 0.1), 0.01)
  }

  func testUTF8TextCapDoesNotBlankChineseOrTrapOnShortBOM() {
    let limit = PreviewLimits.maxTextReadBytes
    let prefix = String(repeating: "a", count: limit - 1)
    let capped = Data((prefix + "中文").utf8).prefix(limit)
    XCTAssertNil(PreviewClassifier.decodeUTF8(capped))
    XCTAssertEqual(PreviewClassifier.decodeUTF8(capped, truncated: true), prefix)
    for value in ["a", "中", "中文"] {
      let bom = Data([0xEF, 0xBB, 0xBF]) + Data(value.utf8)
      XCTAssertTrue(PreviewClassifier.isUTF8Text(bom))
      XCTAssertEqual(PreviewClassifier.decodeUTF8(bom), value)
    }
    XCTAssertNil(PreviewClassifier.decodeUTF8(Data([0x61, 0xFF]), truncated: true))
  }

  func testPreviewReadRejectsNonRegularFilesWithoutOpeningThem() throws {
    let directory = FileManager.default.temporaryDirectory
    let value = PreviewFileAccess.readBounded(
      url: directory, limit: 1024, policy: .complete, metrics: nil
    )
    XCTAssertTrue(value.readFailed)
    XCTAssertTrue(value.data.isEmpty)
    XCTAssertFalse(value.missing)
  }

  func testChineseMarkdownStrongSurvivesRendererAndPreviewStorage() throws {
    let source = "正文含**加粗词**、中文与 English。"
    let render = PreviewTextRenderer.render(text: source, filename: "note.md", mode: .markdown)
    XCTAssertEqual(render.full, source)
    XCTAssertFalse(render.attributed.string.contains("**"))
    XCTAssertTrue(render.attributed.string.contains("加粗词"))
    XCTAssertTrue(fontTraits(render.attributed, word: "加粗词").contains(.boldFontMask))
    XCTAssertFalse(fontTraits(render.attributed, word: "正文含").contains(.boldFontMask))
    XCTAssertFalse(fontTraits(render.attributed, word: "中文与").contains(.boldFontMask))
    let renderedBold = font(render.attributed, word: "加粗词")?.pointSize
    let renderedBody = font(render.attributed, word: "正文含")?.pointSize
    XCTAssertEqual(renderedBold, renderedBody)

    let panel = SilentMarkdownPanel(
      contentRect: NSRect(x: -24000, y: -24000, width: 420, height: 80),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isReleasedWhenClosed = false
    defer { panel.close() }
    let host = NSHostingView(rootView: SelectableTextPreview(
      render: render,
      wraps: true,
      showsLineNumbers: false
    ))
    host.frame = NSRect(x: 0, y: 0, width: 420, height: 80)
    panel.contentView = host
    let deadline = Date().addingTimeInterval(1.5)
    var scroll: NSScrollView?
    while Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
      host.layoutSubtreeIfNeeded()
      scroll = findScroll("lab-text-preview", in: host)
      if scroll != nil { break }
    }
    let textView = try XCTUnwrap(scroll?.documentView as? NSTextView)
    let storage = try XCTUnwrap(textView.textStorage)
    XCTAssertTrue(storage.string.contains("加粗词"))
    XCTAssertFalse(storage.string.contains("**"))
    XCTAssertTrue(fontTraits(storage, word: "加粗词").contains(.boldFontMask), "preview storage lost 加粗词 weight")
    XCTAssertFalse(fontTraits(storage, word: "正文含").contains(.boldFontMask))
    XCTAssertFalse(fontTraits(storage, word: "中文与").contains(.boldFontMask))
    XCTAssertEqual(font(storage, word: "加粗词")?.pointSize, font(storage, word: "正文含")?.pointSize)
    XCTAssertFalse(panel.isVisible)
    XCTAssertFalse(panel.isKeyWindow)
    XCTAssertLessThan(panel.frame.maxX, 0)
  }

  func testMarkdownInlineRunsAreStyledNotJustStripped() {
    let source = "See **bold** and *em* and `code` and [safe](https://example.invalid/x) and [bad](javascript:alert(1))."
    let render = PreviewTextRenderer.render(text: source, filename: "note.md", mode: .markdown)
    XCTAssertEqual(render.full, source)
    XCTAssertFalse(render.attributed.string.contains("**"))
    XCTAssertFalse(render.attributed.string.contains("`"))
    XCTAssertFalse(render.attributed.string.contains("javascript:"))
    XCTAssertEqual(render.structure.links, ["https://example.invalid/x", "javascript:alert(1)"])
    XCTAssertTrue(fontTraits(render.attributed, word: "bold").contains(.boldFontMask))
    XCTAssertTrue(fontTraits(render.attributed, word: "em").contains(.italicFontMask))
    let codeFont = font(render.attributed, word: "code")
    XCTAssertTrue(codeFont?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
    XCTAssertEqual(linkURL(render.attributed, word: "safe")?.scheme, "https")
    XCTAssertNil(linkURL(render.attributed, word: "bad"))
    let safeColor = color(render.attributed, word: "safe")
    XCTAssertNotNil(safeColor)
    XCTAssertNotEqual(safeColor, NSColor.labelColor)
  }

  func testMarkdownTableUsesTextBlocksAndKeepsEmptyCells() {
    let source = "| Name | Value |\n| --- | --- |\n| Local | 2026 |\n|  | kept |\n"
    let render = PreviewTextRenderer.render(text: source, filename: "table.md", mode: .markdown)
    XCTAssertEqual(render.full, source)
    XCTAssertEqual(render.structure.tableRows, [["Name", "Value"], ["Local", "2026"], ["", "kept"]])
    XCTAssertFalse(render.attributed.string.contains("Name | Value"))
    let blocks = textBlocks(render.attributed)
    XCTAssertEqual(blocks.count, 6)
    XCTAssertEqual(blocks.first?.table.numberOfColumns, 2)
    XCTAssertTrue(blocks.contains { $0.startingRow == 0 && $0.startingColumn == 0 })
    XCTAssertTrue(blocks.contains { $0.startingRow == 2 && $0.startingColumn == 0 })
    XCTAssertTrue(fontTraits(render.attributed, word: "Name").contains(.boldFontMask))
  }

  func testMarkdownFixtureContractsKeepStructureAndStyles() throws {
    let text = try String(contentsOf: fixtureURL("readme.md"), encoding: .utf8)
    let render = PreviewTextRenderer.render(text: text, filename: "readme.md", mode: nil)
    XCTAssertEqual(render.full, text)
    XCTAssertEqual(render.structure.headings, ["Preview heading"])
    XCTAssertTrue(render.structure.listItems.contains("中文条目"))
    XCTAssertEqual(render.structure.fencedLanguages, ["swift"])
    XCTAssertTrue(render.structure.fencedBodies.joined().contains("WIT"))
    XCTAssertTrue(render.structure.tableRows.contains(["Local", "2026"]))
    XCTAssertTrue(render.structure.links.contains("https://example.invalid/"))
    XCTAssertTrue(render.structure.remoteImagesSkipped.contains("https://example.invalid/no-network.png"))
    XCTAssertFalse(render.attributed.string.contains("https://example.invalid/no-network.png"))
    XCTAssertFalse(render.attributed.string.contains("Name | Value"))
    let heading = font(render.attributed, word: "Preview heading")
    XCTAssertGreaterThan(heading?.pointSize ?? 0, 16)
    XCTAssertTrue(fontTraits(render.attributed, word: "bold").contains(.boldFontMask))
    XCTAssertTrue(fontTraits(render.attributed, word: "emphasis").contains(.italicFontMask))
    XCTAssertEqual(linkURL(render.attributed, word: "Offline link")?.absoluteString, "https://example.invalid/")
    XCTAssertEqual(textBlocks(render.attributed).first?.table.numberOfColumns, 2)
  }

  private func font(_ text: NSAttributedString, word: String) -> NSFont? {
    let range = (text.string as NSString).range(of: word)
    guard range.location != NSNotFound else { return nil }
    return text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
  }

  private func fontTraits(_ text: NSAttributedString, word: String) -> NSFontTraitMask {
    guard let font = font(text, word: word) else { return [] }
    return NSFontManager.shared.traits(of: font)
  }

  private func linkURL(_ text: NSAttributedString, word: String) -> URL? {
    let range = (text.string as NSString).range(of: word)
    guard range.location != NSNotFound else { return nil }
    let value = text.attribute(.link, at: range.location, effectiveRange: nil)
    if let url = value as? URL { return url }
    if let string = value as? String { return URL(string: string) }
    return nil
  }

  private func color(_ text: NSAttributedString, word: String) -> NSColor? {
    let range = (text.string as NSString).range(of: word)
    guard range.location != NSNotFound else { return nil }
    return text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
  }

  private func textBlocks(_ text: NSAttributedString) -> [NSTextTableBlock] {
    var blocks: [NSTextTableBlock] = []
    text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, _ in
      guard let style = value as? NSParagraphStyle else { return }
      blocks.append(contentsOf: style.textBlocks.compactMap { $0 as? NSTextTableBlock })
    }
    return blocks
  }

  private func fixtureURL(_ name: String) -> URL {
    TestFixtures.url(name)
  }

  private func historyItemDecorator(
    _ value: String?,
    application: String? = "com.apple.finder"
  ) -> HistoryItemDecorator {
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
    item.application = application
    item.firstCopiedAt = firstCopiedAt
    item.lastCopiedAt = lastCopiedAt

    return HistoryItemDecorator(item)
  }

  private func historyItemDecorator(
    _ value: Data?,
    _ type: NSPasteboard.PasteboardType
  ) -> HistoryItemDecorator {
    let contents = [
      HistoryItemContent(
        type: type.rawValue,
        value: value
      )
    ]
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = contents
    item.title = item.generateTitle()
    item.application = "com.apple.finder"
    item.firstCopiedAt = firstCopiedAt
    item.lastCopiedAt = lastCopiedAt
    item.numberOfCopies = 2

    return HistoryItemDecorator(item)
  }

  private func historyItemDecorator(_ value: NSImage) -> HistoryItemDecorator {
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
    item.application = "com.apple.finder"
    item.firstCopiedAt = firstCopiedAt
    item.lastCopiedAt = lastCopiedAt
    item.numberOfCopies = 2

    return HistoryItemDecorator(item)
  }

  private func historyItemDecorator(_ value: URL) -> HistoryItemDecorator {
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
    item.application = "com.apple.finder"
    item.firstCopiedAt = firstCopiedAt
    item.lastCopiedAt = lastCopiedAt
    item.numberOfCopies = 2

    return HistoryItemDecorator(item)
  }

  // swiftlint:disable:next identifier_name
  private func range(from: Int, to: Int, in item: HistoryItemDecorator) -> Range<String.Index> {
    let startIndex = item.title.startIndex
    let lowerBound = item.title.index(startIndex, offsetBy: from)
    let upperBound = item.title.index(startIndex, offsetBy: to + 1)

    return lowerBound..<upperBound
  }

  private func findScroll(_ id: String, in root: NSView) -> NSScrollView? {
    if root.accessibilityIdentifier() == id { return root as? NSScrollView }
    for subview in root.subviews {
      if let found = findScroll(id, in: subview) { return found }
    }
    return nil
  }
}

private final class SilentMarkdownPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
  override func orderFront(_ sender: Any?) {}
  override func orderFrontRegardless() {}
  override func orderBack(_ sender: Any?) {}
  override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {}
  override func makeKey() {}
  override func makeKeyAndOrderFront(_ sender: Any?) {}
  override func makeMain() {}
}
