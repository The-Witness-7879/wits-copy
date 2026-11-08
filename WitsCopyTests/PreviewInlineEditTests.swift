import AppKit
import SwiftUI
import XCTest
@testable import WitsCopy

/// Synthetic Chinese/English/emoji decode and in-place edit keys.
/// Does not order a window, activate the app, read user history, or touch the system pasteboard.
@MainActor
final class PreviewInlineEditTests: XCTestCase {
  private let sample = "中文 English 😀\n第二行"
  private var panel: NSPanel?
  private var richIdentity: String?
  private var savedPresented = false
  private var inserted: HistoryItemDecorator?

  override func setUp() {
    super.setUp()
    savedPresented = AppState.shared.panelPresented
  }

  override func tearDown() {
    (panel as? SealedInlinePanel)?.detachForTeardown()
    panel?.close()
    panel = nil
    if let richIdentity {
      RichTextDraftStore.shared.discard(identity: richIdentity)
    }
    richIdentity = nil
    Storage.shared.saveImplementation = nil
    Clipboard.shared.copyProbe = nil
    Clipboard.shared.explicitHideProbe = nil
    AppState.shared.storageError = nil
    AppState.shared.discardAllTextDrafts()
    if let inserted {
      History.shared.delete(inserted)
    }
    inserted = nil
    AppState.shared.panelPresented = savedPresented
    super.tearDown()
  }

  func testPlainUTF8AndBOMKeepChineseEnglishEmoji() {
    let utf8 = Data(sample.utf8)
    XCTAssertEqual(PreviewTextCodec.decodePlain(utf8), sample)
    let bom = Data([0xEF, 0xBB, 0xBF]) + utf8
    XCTAssertEqual(PreviewTextCodec.decodePlain(bom), sample)
    XCTAssertFalse(PreviewTextCodec.decodePlain(bom)?.hasPrefix("\u{FEFF}") ?? true)
  }

  func testUTF16WithBOMDecodesAndLittleEndianWithoutBOMIsRefused() {
    let withBOM = sample.data(using: .utf16)!
    XCTAssertEqual(PreviewTextCodec.decodePlain(withBOM), sample)
    let littleEndian = sample.data(using: .utf16LittleEndian)!
    let garbled = String(data: littleEndian, encoding: .utf16)
    XCTAssertNotEqual(garbled, sample)
    XCTAssertNil(PreviewTextCodec.decodePlain(littleEndian), "no-BOM UTF-16 must not be shown as mojibake")
  }

  func testHTMLCharsetAndFragmentKeepChineseEnglishEmoji() {
    let meta = Data("<html><head><meta charset=\"utf-8\"></head><body><b>\(sample)</b></body></html>".utf8)
    let fragment = Data("<span>\(sample)</span>".utf8)
    let utf16 = "<html><body>\(sample)</body></html>".data(using: .utf16)!
    for data in [meta, fragment, utf16] {
      let parsed = RichTextHTML.parse(data)
      XCTAssertTrue(parsed.readable.contains("中文"), parsed.readable)
      XCTAssertTrue(parsed.readable.contains("English"), parsed.readable)
      XCTAssertTrue(parsed.readable.contains("😀"), parsed.readable)
      XCTAssertTrue(parsed.readable.contains("第二行"), parsed.readable)
      XCTAssertFalse(parsed.readable.contains("ä¸­"), parsed.readable)
      XCTAssertFalse(parsed.readable.contains("涓"), parsed.readable)
    }
  }

  func testListTitleAndPreviewShareDecodedCharactersWithoutRewritingBytes() {
    let inner = "中文 English 😀"
    let html = Data("<p>\(inner)</p>".utf8)
    let stored = html
    let item = HistoryItem(contents: [
      HistoryItemContent(type: NSPasteboard.PasteboardType.html.rawValue, value: stored)
    ])
    let parsed = RichTextHTML.parse(stored)
    let list = item.previewableText
    XCTAssertTrue(parsed.readable.contains(inner), parsed.readable)
    XCTAssertTrue(parsed.readable.hasSuffix("\n"), "tidy block break is structural, not a missing character: \(parsed.readable.debugDescription)")
    XCTAssertNotEqual(parsed.readable, inner, "do not treat the structural newline as mojibake by requiring an exact trim")
    XCTAssertTrue(list.contains("中文"), list)
    XCTAssertTrue(list.contains("English"), list)
    XCTAssertTrue(list.contains("😀"), list)
    XCTAssertFalse(list.contains("涓"), list)
    XCTAssertFalse(list.contains("ä¸­"), list)
    XCTAssertFalse(parsed.readable.contains("涓"), parsed.readable)
    XCTAssertFalse(parsed.readable.contains("ä¸­"), parsed.readable)
    XCTAssertEqual(item.htmlData, stored, "display decode rewrote stored HTML")
    let significant = String(parsed.readable.dropLast())
    XCTAssertTrue(significant.contains(inner) || list == significant || list.contains(inner))
  }

  func testNoBOMUTF16HTMLIsEmptyRatherThanMojibake() {
    let little = "<p>中文 English 😀</p>".data(using: .utf16LittleEndian)!
    XCTAssertNil(PreviewTextCodec.decodePlain(little))
    XCTAssertEqual(HTMLTextStrip.plainText(little), "")
    let item = HistoryItem(contents: [
      HistoryItemContent(type: NSPasteboard.PasteboardType.html.rawValue, value: little)
    ])
    XCTAssertNil(item.html)
    XCTAssertEqual(item.htmlData, little)
  }

  func testPlainBOMDoesNotStickToDisplayedTextOrStoredBytes() {
    let body = Data("中文 English 😀".utf8)
    let stored = Data([0xEF, 0xBB, 0xBF]) + body
    let item = HistoryItem(contents: [
      HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: stored)
    ])
    XCTAssertEqual(item.text, "中文 English 😀")
    XCTAssertFalse(item.text?.hasPrefix("\u{FEFF}") ?? true)
    XCTAssertEqual(item.contents.first?.value, stored)
  }

  func testGenericUTF16WithoutBOMIsRefusedEvenWhenBothEndiannessesRoundTrip() {
    // Parent-verified bytes: UTF-16 LE of 中文 is 2d 4e 87 65.
    // LE reads 中文 and BE reads a different string; each re-encodes to the same bytes.
    // Round-trip therefore cannot choose an endianness. Do not guess from the characters.
    let bytes = Data([0x2D, 0x4E, 0x87, 0x65])
    let asLE = String(data: bytes, encoding: .utf16LittleEndian)
    let asBE = String(data: bytes, encoding: .utf16BigEndian)
    XCTAssertNotEqual(asLE, asBE)
    XCTAssertEqual(asLE?.data(using: .utf16LittleEndian), bytes)
    XCTAssertEqual(asBE?.data(using: .utf16BigEndian), bytes)
    XCTAssertNil(PreviewTextCodec.decodePlain(bytes), "generic no-BOM UTF-16 stays refused")
    let typed = HistoryItem(contents: [
      HistoryItemContent(type: "public.utf16-plain-text", value: bytes)
    ])
    XCTAssertNil(typed.text)
    XCTAssertEqual(typed.contents.first?.value, bytes, "refusal rewrote stored bytes")
    // UTF-16 BE of 你 is also valid ASCII UTF-8 (O`). The declared generic
    // UTF-16 representation must not fall back to interpreting it as UTF-8.
    let ambiguous = Data([0x4F, 0x60])
    XCTAssertNotNil(String(data: ambiguous, encoding: .utf8))
    let ambiguousTyped = HistoryItem(contents: [
      HistoryItemContent(type: "public.utf16-plain-text", value: ambiguous)
    ])
    XCTAssertNil(ambiguousTyped.text)
    XCTAssertEqual(ambiguousTyped.contents.first?.value, ambiguous)
    let utf8 = Data("中文 English".utf8)
    let late = HistoryItem(contents: [
      HistoryItemContent(type: "public.utf16-plain-text", value: bytes),
      HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: utf8)
    ])
    let early = HistoryItem(contents: [
      HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: utf8),
      HistoryItemContent(type: "public.utf16-plain-text", value: bytes)
    ])
    XCTAssertEqual(late.text, "中文 English")
    XCTAssertEqual(early.text, late.text, "reliable plain must not follow contents order")
    XCTAssertEqual(late.contents.first?.value, bytes)
    XCTAssertEqual(early.contents.last?.value, bytes)
  }

  func testHTMLAndTypedUTF16KeepCharactersWithoutRewritingOrGuessing() {
    let sample = "中文 English 😀"
    let utf8 = Data("<p>\(sample)</p>".utf8)
    let bom16 = "<p>\(sample)</p>".data(using: .utf16)!
    let naked16 = "<p>\(sample)</p>".data(using: .utf16LittleEndian)!
    for data in [utf8, bom16] {
      let parsed = RichTextHTML.parse(data)
      XCTAssertTrue(parsed.readable.contains("中文"), parsed.readable)
      XCTAssertFalse(parsed.readable.contains("ä¸"), parsed.readable)
      XCTAssertFalse(parsed.readable.contains("涓"), parsed.readable)
    }
    let refused = RichTextHTML.parse(naked16)
    XCTAssertFalse(refused.readable.contains("中文"))
    XCTAssertFalse(refused.readable.contains("ä¸"))
    XCTAssertEqual(naked16, "<p>\(sample)</p>".data(using: .utf16LittleEndian)!)
    let storedUTF16 = sample.data(using: .utf16LittleEndian)!
    let typed = HistoryItem(contents: [
      HistoryItemContent(type: "public.utf16-plain-text", value: storedUTF16)
    ])
    XCTAssertNil(typed.text, "a generic utf16 type without a BOM is not an endianness")
    XCTAssertEqual(typed.contents.first?.value, storedUTF16)
    let plain = OriginalTextBodyView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
    let rich = RichTextBodyView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
    XCTAssertTrue(plain.usesAdaptiveColorMappingForDarkAppearance)
    XCTAssertTrue(rich.usesAdaptiveColorMappingForDarkAppearance)
    for name in [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua] {
      let appearance = NSAppearance(named: name)!
      appearance.performAsCurrentDrawingAppearance {
        let color = NSColor.labelColor.usingColorSpace(.sRGB)
        XCTAssertNotNil(color, "\(name.rawValue) label color did not resolve")
      }
    }
  }

  func testEnterShiftEnterEscapeAndMarkedText() {
    XCTAssertEqual(PreviewEditKeys.command(keyCode: 36, flags: [], markedText: false), .submit)
    XCTAssertEqual(PreviewEditKeys.command(keyCode: 76, flags: [], markedText: false), .submit)
    XCTAssertEqual(PreviewEditKeys.command(keyCode: 36, flags: .shift, markedText: false), .newline)
    XCTAssertEqual(PreviewEditKeys.command(keyCode: 53, flags: [], markedText: false), .cancel)
    XCTAssertEqual(PreviewEditKeys.command(keyCode: 36, flags: [], markedText: true), .ignore)
    XCTAssertEqual(PreviewEditKeys.command(keyCode: 53, flags: [], markedText: true), .ignore)
    XCTAssertEqual(PreviewEditKeys.command(keyCode: 36, flags: .command, markedText: false), .ignore)
  }

  func testMarkedReturnDoesNotSaveAndBareReturnDoes() throws {
    let view = OriginalTextBodyView(usingTextLayoutManager: false)
    view.isEditable = true
    view.string = sample
    var saves = 0
    view.onSave = {
      saves += 1
      return true
    }
    let host = try mount(view)
    XCTAssertTrue(host.window?.makeFirstResponder(view) ?? false)
    view.setMarkedText("候", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: 0, length: 0))
    XCTAssertTrue(view.hasMarkedText())
    view.keyDown(with: try key("\r", code: 36, flags: []))
    XCTAssertEqual(saves, 0)
    view.unmarkText()
    XCTAssertFalse(view.hasMarkedText())
    view.keyDown(with: try key("\r", code: 36, flags: [.shift]))
    XCTAssertEqual(saves, 0)
    XCTAssertTrue(view.string.contains("\n"))
    view.keyDown(with: try key("\r", code: 36, flags: []))
    XCTAssertEqual(saves, 1)
    XCTAssertFalse(panel?.isVisible ?? true)
    XCTAssertFalse(panel?.isKeyWindow ?? true)
  }

  func testUpdateDoesNotStealFirstResponder() throws {
    let holder = InlineFieldHolder()
    let window = SealedInlinePanel(
      contentRect: NSRect(x: -24000, y: -24000, width: 320, height: 180),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    let shell = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
    let host = NSHostingView(rootView: InlineFieldHarness(holder: holder))
    host.sizingOptions = []
    host.frame = NSRect(x: 0, y: 24, width: 320, height: 156)
    shell.addSubview(host)
    let other = NSTextView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
    other.isEditable = true
    shell.addSubview(other)
    window.contentView = shell
    panel = window
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    XCTAssertFalse(other.isDescendant(of: host), "NSTextView must not be added to NSHostingView")
    XCTAssertTrue(window.makeFirstResponder(other))
    holder.text = sample + "x"
    holder.token += 1
    holder.editing = true
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    XCTAssertTrue(window.firstResponder === other)
    XCTAssertFalse(window.isVisible)
    XCTAssertFalse(window.isKeyWindow)
    XCTAssertLessThan(window.frame.maxX, 0)
    XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, front)
  }

  func testTitleOnlyTransactionDoesNotStripAndBodyEditDoes() {
    let rtf = Data("{\\rtf1 keep}".utf8)
    let html = Data("<b>中文 English 😀</b>".utf8)
    let plain = Data("中文 English 😀".utf8)
    let source = RichTextSource(representations: [
      RichTextRepresentation(type: RichTextTypes.plainUTF8, value: plain),
      RichTextRepresentation(type: RichTextTypes.rtf, value: rtf),
      RichTextRepresentation(type: NSPasteboard.PasteboardType.html.rawValue, value: html)
    ], title: "旧标题")
    let session = RichTextSession(store: RichTextDraftStore())
    session.load(identity: "inline", source: source)
    XCTAssertEqual(source.representations[1].value, rtf)
    XCTAssertEqual(source.representations[2].value, html)

    session.noteBody("中文 English 😀\n改过")
    let body = session.save(current: source)
    XCTAssertTrue(body.applyColumnChanges)
    XCTAssertTrue(body.columnChanges.contains { $0.type == RichTextTypes.rtf && $0.action == .delete })
    XCTAssertTrue(body.columnChanges.contains { $0.type == NSPasteboard.PasteboardType.html.rawValue && $0.action == .delete })
    let replaced = body.columnChanges.first { $0.type == RichTextTypes.plainUTF8 }
    if case .replace(let data) = replaced?.action {
      XCTAssertEqual(String(data: data, encoding: .utf8), "中文 English 😀\n改过")
    } else {
      XCTFail("plain column was not replaced")
    }
  }

  func testCancelAndUnchangedDoNotEmitColumnWrites() {
    let html = Data("<b>\(sample)</b>".utf8)
    let source = RichTextSource(representations: [
      RichTextRepresentation(type: NSPasteboard.PasteboardType.html.rawValue, value: html)
    ], title: "t")
    let session = RichTextSession(store: RichTextDraftStore())
    session.load(identity: "keep", source: source)
    session.noteBody(sample + "x")
    session.abandon()
    XCTAssertNil(session.store.draft(for: "keep"))
    XCTAssertEqual(source.representations[0].value, html)
    let untouched = session.save(current: source)
    XCTAssertFalse(untouched.applyColumnChanges)
    XCTAssertTrue(untouched.columnChanges.isEmpty)
  }

  func testFileBackedRichEditIsRefused() {
    let source = RichTextSource(
      representations: [RichTextRepresentation(type: NSPasteboard.PasteboardType.html.rawValue, value: Data("<b>中文</b>".utf8))],
      title: "file",
      fileBacked: true
    )
    let assessment = RichTextModel.assess(source)
    XCTAssertEqual(assessment.refusal, .fileBacked)
    let session = RichTextSession(store: RichTextDraftStore())
    session.load(identity: "file", source: source)
    session.noteBody("changed")
    let transaction = session.save(current: source)
    XCTAssertFalse(transaction.applyColumnChanges)
    XCTAssertTrue(transaction.columnChanges.isEmpty)
  }

  /// Offscreen PreviewItemView rich host. Not a visible window and not a physical IME.
  func testPreviewHTMLCancelKeepsTitleRepresentationsAndMetadata() async throws {
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let (item, original) = try htmlItem(includeRTF: true)
    let identity = item.id
    let object = ObjectIdentifier(item.item)
    let presented = AppState.shared.panelPresented
    var copies = 0
    var hides = 0
    Clipboard.shared.copyProbe = { _, _ in copies += 1 }
    Clipboard.shared.explicitHideProbe = { hides += 1 }
    let host = try mountPreview(item)
    let body = try await waitRichBody(in: host)
    XCTAssertTrue(body.string.contains("中文"))
    XCTAssertTrue(body.string.contains("English"))
    XCTAssertTrue(body.string.contains("😀"))
    XCTAssertTrue(body.isRichText)
    XCTAssertNil(find("lab-preview-title", in: host), "text preview still has a title field")
    XCTAssertNil(find("lab-preview-edit-title", in: host))
    XCTAssertNil(find("lab-preview-edit-save", in: host))
    XCTAssertNil(find("lab-preview-edit-cancel", in: host))
    XCTAssertNil(find("lab-rich-title-save", in: host))
    XCTAssertNil(find("lab-rich-title-cancel", in: host))

    assertSameRepresentations(representationBytes(item.item), original)
    try beginRich(body, in: host)
    let beforeCancel = body.string
    let end = NSRange(location: (body.string as NSString).length, length: 0)
    body.insertText("取消n\u{0303} ", replacementRange: end)
    XCTAssertNotEqual(body.string, beforeCancel)
    body.keyDown(with: try key("\u{1b}", code: 53, flags: []))
    try await settle(0.2)
    assertSameRepresentations(representationBytes(item.item), original)
    XCTAssertEqual(item.item.title, "原标题", "body cancel changed the stored title")
    XCTAssertEqual(item.item.pin, "s")
    XCTAssertEqual(item.item.tags, ["kept"])
    XCTAssertNil(RichTextDraftStore.shared.draft(for: richIdentity ?? ""))
    assertIdentity(item, id: identity, object: object)
    assertSealed(host, front: front, copies: copies, hides: hides, presented: presented)
  }

  /// Same PreviewItemView HTML/RTF editor: marked Return, Shift+Enter, failed save, retry.
  /// Not a visible window and not a physical IME.
  func testPreviewHTMLMarkedShiftEnterFailureThenRetry() async throws {
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let (item, original) = try htmlItem(includeRTF: true)
    let identity = item.id
    let object = ObjectIdentifier(item.item)
    let presented = AppState.shared.panelPresented
    var copies = 0
    var hides = 0
    Clipboard.shared.copyProbe = { _, _ in copies += 1 }
    Clipboard.shared.explicitHideProbe = { hides += 1 }
    let host = try mountPreview(item)
    let body = try await waitRichBody(in: host)
    XCTAssertTrue(body.isRichText)
    XCTAssertNil(find("lab-preview-title", in: host))
    XCTAssertNil(find("lab-preview-edit-save", in: host))
    XCTAssertNil(find("lab-preview-edit-cancel", in: host))
    XCTAssertTrue(body.string.contains("中文") && body.string.contains("😀"))
    try beginRich(body, in: host)

    let beforeInsert = body.string
    let insertAt = NSRange(location: (beforeInsert as NSString).length, length: 0)
    body.insertText("n\u{0303} ", replacementRange: insertAt)
    let delta = String(body.string.dropFirst(beforeInsert.count))
    let nfd = "n\u{0303} "
    let nfc = nfd.precomposedStringWithCanonicalMapping
    XCTAssertTrue(
      delta == nfd || delta == nfc,
      "combining insert must remain a suffix delta: \(delta.debugDescription)"
    )
    XCTAssertTrue(delta.hasSuffix(" "), "trailing space dropped: \(delta.debugDescription)")
    XCTAssertNotEqual(body.string, beforeInsert)
    let markedAt = NSRange(location: (body.string as NSString).length, length: 0)
    body.setMarkedText(
      "候",
      selectedRange: NSRange(location: 0, length: 1),
      replacementRange: markedAt
    )
    XCTAssertTrue(body.hasMarkedText())
    body.keyDown(with: try key("\r", code: 36, flags: []))
    try await settle(0.15)
    assertSameRepresentations(representationBytes(item.item), original, "marked Return saved")
    XCTAssertEqual(item.item.title, "原标题", "marked Return changed the title")
    XCTAssertTrue(body.isEditable, "marked Return called onSave and left the edit")
    XCTAssertNil(find("lab-preview-edit-error", in: host), "marked Return surfaced a save error")
    XCTAssertTrue(host.window?.firstResponder === body)
    XCTAssertEqual(copies, 0)
    XCTAssertEqual(hides, 0, "marked Return hid the panel")
    XCTAssertEqual(AppState.shared.panelPresented, presented)
    if body.hasMarkedText() {
      let range = body.markedRange()
      XCTAssertNotEqual(range.location, NSNotFound)
      body.insertText("", replacementRange: range)
    }
    XCTAssertFalse(body.hasMarkedText(), "test did not clear its own composition")
    let beforeNewline = body.string
    XCTAssertTrue(beforeNewline.hasSuffix(" "), "trailing space missing before Shift+Enter: \(beforeNewline.debugDescription)")
    let newlinesBefore = beforeNewline.filter { $0 == "\n" }.count
    let selectionBefore = body.selectedRange().location
    body.keyDown(with: try key("\r", code: 36, flags: [.shift]))
    XCTAssertEqual(body.string, beforeNewline + "\n", "Shift+Enter did not append one LF: \(body.string.debugDescription)")
    XCTAssertEqual(body.string.filter { $0 == "\n" }.count, newlinesBefore + 1, "Shift+Enter did not add one LF: \(body.string.debugDescription)")
    XCTAssertTrue(body.string.hasSuffix(" \n"), "trailing space+LF lost: \(body.string.debugDescription)")
    XCTAssertGreaterThan(body.selectedRange().location, selectionBefore)
    let drafted = body.string
    XCTAssertNotEqual(drafted, drafted.trimmingCharacters(in: .whitespacesAndNewlines))

    Storage.shared.saveImplementation = { throw CocoaError(.fileWriteUnknown) }
    body.keyDown(with: try key("\r", code: 36, flags: []))
    let failed = try await waitRichBody(in: host, editable: true, string: drafted)
    assertSameRepresentations(representationBytes(item.item), original)
    XCTAssertEqual(failed.string, drafted)
    XCTAssertTrue(failed.isEditable)
    XCTAssertEqual(RichTextDraftStore.shared.draft(for: richIdentity ?? "")?.body, drafted)
    let error = try await waitError(in: host)
    XCTAssertFalse(error.stringValue.isEmpty)
    assertIdentity(item, id: identity, object: object)
    XCTAssertEqual(copies, 0)
    XCTAssertEqual(hides, 0)
    XCTAssertEqual(AppState.shared.panelPresented, presented)

    Storage.shared.saveImplementation = nil
    let submitted = failed.string
    failed.keyDown(with: try key("\r", code: 36, flags: []))
    let plain = try await waitPlainBody(in: host, item: item.item, expected: submitted)
    XCTAssertEqual(plain.string, submitted)
    XCTAssertFalse(plain.string.trimmingCharacters(in: .whitespacesAndNewlines) == submitted)
    let stored = representationBytes(item.item)
    XCTAssertEqual(stored.count, 1)
    let saved = try XCTUnwrap(stored.first)
    XCTAssertEqual(saved.0, NSPasteboard.PasteboardType.string.rawValue)
    XCTAssertEqual(saved.1, Data(submitted.utf8))
    XCTAssertNotEqual(saved.1, Data(submitted.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
    XCTAssertFalse(item.item.contents.contains { RichTextTypes.isRich($0.type) })
    XCTAssertNil(find("lab-rich-text-body", in: host), "old rich node was treated as the saved plain body")
    XCTAssertEqual(item.item.title, "原标题", "body submit changed the stored title")
    assertIdentity(item, id: identity, object: object)
    XCTAssertNil(RichTextDraftStore.shared.draft(for: richIdentity ?? ""))
    assertSealed(host, front: front, copies: copies, hides: hides, presented: presented)
  }

  private func mount(_ view: NSView) throws -> NSView {
    let window = SealedInlinePanel(
      contentRect: NSRect(x: -24000, y: -24000, width: 320, height: 180),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
    view.frame = host.bounds
    host.addSubview(view)
    window.contentView = host
    panel = window
    return host
  }

  private func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: flags,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: characters,
      isARepeat: false,
      keyCode: code
    ))
  }

  private func htmlItem(includeRTF: Bool) throws -> (HistoryItemDecorator, [(String, Data)]) {
    guard Storage.shared.isInMemory else {
      XCTFail("refusing to write outside the XCTest memory store")
      throw IsolatedStoreRequired()
    }
    History.shared.clearAll()
    let visible = "中文 English 😀"
    let html = Data("<meta charset=\"utf-8\"><p>\(visible)</p>".utf8)
    var contents = [
      HistoryItemContent(type: NSPasteboard.PasteboardType.html.rawValue, value: html)
    ]
    if includeRTF {
      let styled = NSAttributedString(
        string: visible,
        attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]
      )
      let rtf = try XCTUnwrap(styled.rtf(from: NSRange(location: 0, length: styled.length)))
      contents.append(HistoryItemContent(type: NSPasteboard.PasteboardType.rtf.rawValue, value: rtf))
    }
    let item = HistoryItem(contents: contents)
    item.title = "原标题"
    item.pin = "s"
    item.tags = ["kept"]
    item.application = "com.example.html-edit"
    item.numberOfCopies = 4
    item.firstCopiedAt = Date(timeIntervalSince1970: 1_700_000_000)
    item.lastCopiedAt = Date(timeIntervalSince1970: 1_700_000_100)
    Storage.shared.context.insert(item)
    let decorator = History.shared.add(item)
    decorator.title = item.title
    richIdentity = RichTextIdentity.modelKey(item)
    inserted = decorator
    return (decorator, representationBytes(item))
  }

  private func representationBytes(_ item: HistoryItem) -> [(String, Data)] {
    item.contents.compactMap { content in
      guard let value = content.value else { return nil }
      return (content.type, value)
    }.sorted { $0.0 < $1.0 }
  }

  /// Array of tuples is not Equatable for XCTest here. Compare each type and its bytes.
  private func assertSameRepresentations(
    _ got: [(String, Data)],
    _ want: [(String, Data)],
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(got.count, want.count, message, file: file, line: line)
    for index in 0..<min(got.count, want.count) {
      XCTAssertEqual(got[index].0, want[index].0, message, file: file, line: line)
      XCTAssertEqual(got[index].1, want[index].1, message, file: file, line: line)
    }
  }

  private struct IsolatedStoreRequired: Error {}

  private func assertIdentity(_ item: HistoryItemDecorator, id: UUID, object: ObjectIdentifier) {
    XCTAssertEqual(item.id, id)
    XCTAssertEqual(ObjectIdentifier(item.item), object)
    XCTAssertFalse(item.isRemoved)
    assertMetadata(item.item)
  }

  private func assertMetadata(_ item: HistoryItem) {
    XCTAssertEqual(item.pin, "s")
    XCTAssertEqual(item.tags, ["kept"])
    XCTAssertEqual(item.application, "com.example.html-edit")
    XCTAssertEqual(item.numberOfCopies, 4)
    XCTAssertEqual(item.firstCopiedAt, Date(timeIntervalSince1970: 1_700_000_000))
    XCTAssertEqual(item.lastCopiedAt, Date(timeIntervalSince1970: 1_700_000_100))
  }

  private func mountPreview(_ item: HistoryItemDecorator) throws -> NSView {
    let window = SealedInlinePanel(
      contentRect: NSRect(x: -24000, y: -24000, width: 520, height: 360),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    let host = NSHostingView(
      rootView: PreviewItemView(item: item)
        .environment(AppState.shared)
        .environment(ModifierFlags())
        .modelContainer(Storage.shared.container)
    )
    host.sizingOptions = []
    host.frame = NSRect(x: 0, y: 0, width: 520, height: 360)
    window.contentView = host
    panel = window
    XCTAssertFalse(window.isVisible)
    XCTAssertFalse(window.isKeyWindow)
    XCTAssertLessThan(window.frame.maxX, 0)
    return host
  }

  private func waitRichBody(in host: NSView, editable: Bool? = nil, string: String? = nil) async throws -> RichTextBodyView {
    let deadline = Date().addingTimeInterval(4)
    while Date() < deadline {
      host.layoutSubtreeIfNeeded()
      if let view = find("lab-rich-text-body", in: host) as? RichTextBodyView {
        let editableOK = editable == nil || view.isEditable == editable
        let stringOK = string == nil || view.string == string
        if editableOK && stringOK { return view }
      }
      try await Task.sleep(for: .milliseconds(40))
    }
    let found = find("lab-rich-text-body", in: host) as? RichTextBodyView
    return try XCTUnwrap(found, "rich body missing or not \(string ?? "ready"): \(identifiers(in: host))")
  }

  private func waitPlainBody(in host: NSView, item: HistoryItem, expected: String) async throws -> NSTextView {
    let deadline = Date().addingTimeInterval(4)
    while Date() < deadline {
      host.layoutSubtreeIfNeeded()
      let bytes = representationBytes(item)
      let plain = bytes.count == 1 && bytes.first?.1 == Optional(Data(expected.utf8))
      if plain, let view = textView("lab-preview-edit-body", in: host) ?? textView("lab-preview-body", in: host),
         view.string == expected {
        return view
      }
      try await Task.sleep(for: .milliseconds(40))
    }
    let types = item.contents.map(\.type).joined(separator: ",")
    return try XCTUnwrap(
      textView("lab-preview-edit-body", in: host) ?? textView("lab-preview-body", in: host),
      "plain body not installed after save types=\(types) ids=\(identifiers(in: host))"
    )
  }

  private func waitError(in host: NSView) async throws -> NSTextField {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
      host.layoutSubtreeIfNeeded()
      if let field = find("lab-preview-edit-error", in: host) as? NSTextField, !field.stringValue.isEmpty {
        return field
      }
      try await Task.sleep(for: .milliseconds(40))
    }
    return try XCTUnwrap(
      find("lab-preview-edit-error", in: host) as? NSTextField,
      "edit error was not installed: \(identifiers(in: host))"
    )
  }

  private func beginRich(_ view: RichTextBodyView, in host: NSView) throws {
    XCTAssertFalse(view.isEditable)
    view.mouseDown(with: try mouseDown())
    XCTAssertTrue(view.isEditable, "rich click did not enter edit")
    XCTAssertTrue(host.window?.makeFirstResponder(view) ?? false)
    XCTAssertTrue(host.window?.firstResponder === view)
    XCTAssertFalse(host.window?.isVisible ?? true)
    XCTAssertFalse(host.window?.isKeyWindow ?? true)
  }

  private func textView(_ id: String, in root: NSView) -> NSTextView? {
    if let view = find(id, in: root) as? NSTextView { return view }
    if let scroll = find(id, in: root) as? NSScrollView, let view = scroll.documentView as? NSTextView {
      return view
    }
    return nil
  }

  private func find(_ id: String, in root: NSView) -> NSView? {
    if root.accessibilityIdentifier() == id { return root }
    for subview in root.subviews {
      if let found = find(id, in: subview) { return found }
    }
    return nil
  }

  private func identifiers(in root: NSView) -> [String] {
    var ids: [String] = []
    func walk(_ view: NSView) {
      let id = view.accessibilityIdentifier()
      if !id.isEmpty { ids.append(id) }
      view.subviews.forEach(walk)
    }
    walk(root)
    return ids
  }

  private func mouseDown() throws -> NSEvent {
    try XCTUnwrap(NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: NSPoint(x: 8, y: 8),
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: panel?.windowNumber ?? 0,
      context: nil,
      eventNumber: 1,
      clickCount: 1,
      pressure: 1
    ))
  }

  /// Suspends the MainActor so PreviewItemView.task continuations can install views.
  /// A synchronous RunLoop spin holds the actor and never reaches the awaited load.
  private func settle(_ interval: TimeInterval) async throws {
    let end = Date().addingTimeInterval(interval)
    while Date() < end {
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func assertSealed(_ host: NSView, front: pid_t?, copies: Int, hides: Int, presented: Bool) {
    XCTAssertFalse(host.window?.isVisible ?? true)
    XCTAssertFalse(host.window?.isKeyWindow ?? true)
    XCTAssertLessThan(host.window?.frame.maxX ?? 0, 0)
    XCTAssertEqual(host.window?.frame.origin.x, -24000)
    XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, front)
    XCTAssertEqual(copies, 0)
    XCTAssertEqual(hides, 0)
    XCTAssertEqual(AppState.shared.panelPresented, presented)
  }
}

private final class InlineFieldHolder: ObservableObject {
  @Published var text = "中文 English 😀\n第二行"
  @Published var token = 1
  @Published var editing = false
}

private struct InlineFieldHarness: View {
  @ObservedObject var holder: InlineFieldHolder
  var body: some View {
    PreviewInlineField(
      text: holder.text,
      font: .systemFont(ofSize: 13),
      identifier: "lab-preview-body",
      editing: holder.editing,
      token: holder.token,
      scrolling: false,
      onBegin: {},
      onText: { _ in },
      onSave: { true },
      onCancel: {}
    )
  }
}

private final class SealedInlinePanel: NSPanel {
  func detachForTeardown() {
    super.order(.out, relativeTo: 0)
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
  override func makeKey() {}
  override func becomeKey() {}
  override func makeMain() {}
  override func makeKeyAndOrderFront(_ sender: Any?) {}
  override func orderFront(_ sender: Any?) {}
  override func orderFrontRegardless() {}
  override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {}
}
