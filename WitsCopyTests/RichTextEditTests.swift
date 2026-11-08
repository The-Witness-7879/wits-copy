import AppKit
import Defaults
import ObjectiveC
import SwiftUI
import XCTest
@testable import WitsCopy

/// Synthetic rich-text display and plain-save contract. Does not order a window,
/// touch the system pasteboard, or read user history.
@MainActor
final class RichTextEditTests: XCTestCase {
  private var panel: NSPanel?
  private var inkBytesPremultiplied = false
  private var inkBytesBGRA = false
  private var inkByteRowMatchesColorAtY = true

  override func tearDown() {
    panel?.close()
    panel = nil
    super.tearDown()
  }

  func testSaveAfterBodyEditDeletesRichTextAndWritesPlain() {
    let fixture = richItem(plain: "Alpha", html: "<b>Alpha</b>")
    let session = session(fixture, identity: "item-a")
    session.noteBody("Alpha edited")

    let transaction = session.save(current: fixture.source)
    assertNoStripUnlessBodyChanged(transaction)
    XCTAssertEqual(transaction.status, .ready)
    XCTAssertTrue(transaction.applyColumnChanges)
    XCTAssertTrue(transaction.bodyChanged)
    XCTAssertEqual(String(data: replacedPlain(transaction) ?? Data(), encoding: .utf8), "Alpha edited")
    XCTAssertTrue(deleted(transaction, RichTextTypes.rtf))
    XCTAssertTrue(deleted(transaction, NSPasteboard.PasteboardType.html.rawValue))
    XCTAssertTrue(deleted(transaction, "com.apple.WebKit.custom-pasteboard-data"))
    XCTAssertFalse(transaction.columnChanges.contains { $0.type == NSPasteboard.PasteboardType.png.rawValue })
    XCTAssertFalse(transaction.columnChanges.contains { change in
      guard case .replace(let data) = change.action else { return false }
      return data == fixture.rtf || data == fixture.html
    })
    let utf16 = replacedPlain(transaction, type: "public.utf16-plain-text") ?? Data()
    XCTAssertEqual(String(data: utf16, encoding: .utf16), "Alpha edited")
    XCTAssertNotEqual(utf16, fixture.oldUTF16)
  }

  func testHTMLOnlySaveInsertsPlainAndDeletesHTML() {
    let html = Data("<b>Alpha</b>".utf8)
    let source = RichTextSource(representations: [
      RichTextRepresentation(type: NSPasteboard.PasteboardType.html.rawValue, value: html)
    ], title: "t")
    let session = session(source, identity: "html-only")
    session.noteBody("Alpha!")

    let transaction = session.save(current: source)
    XCTAssertTrue(transaction.applyColumnChanges)
    XCTAssertTrue(transaction.columnChanges.contains {
      $0.type == RichTextTypes.plainUTF8 && $0.insertIfMissing && $0.action == .replace(Data("Alpha!".utf8))
    })
    XCTAssertTrue(deleted(transaction, NSPasteboard.PasteboardType.html.rawValue))
    XCTAssertFalse(transaction.columnChanges.contains { $0.type == RichTextTypes.rtf })
  }

  func testUneditedBodyAndTitleOnlyDoNotStripFormatting() {
    let fixture = richItem(plain: "Alpha", html: "<b>Alpha</b>")
    let session = session(fixture, identity: "keep")

    let untouched = session.save(current: fixture.source)
    XCTAssertEqual(untouched.status, .unchanged)
    XCTAssertFalse(untouched.applyColumnChanges)
    XCTAssertTrue(untouched.columnChanges.isEmpty)
    XCTAssertNil(untouched.title)

    session.noteBody("Alpha")
    let typedBack = session.save(current: fixture.source)
    XCTAssertFalse(typedBack.bodyChanged)
    XCTAssertFalse(typedBack.applyColumnChanges)
    XCTAssertTrue(typedBack.columnChanges.isEmpty)

    XCTAssertEqual(fixture.source.representations, fixture.original)
  }

  func testSaveFailureAndStaleCommitKeepTheDraft() {
    let fixture = richItem(plain: "Alpha", html: "<b>Alpha</b>")
    let store = RichTextDraftStore()
    let session = RichTextSession(store: store)
    session.load(identity: "draft", source: fixture.source)
    session.noteBody("pending")
    let first = session.save(current: fixture.source)
    store.noteSaveFailed(identity: "draft", generation: first.generation, message: "disk")
    XCTAssertEqual(store.draft(for: "draft")?.body, "pending")
    XCTAssertEqual(store.draft(for: "draft")?.error, "disk")

    session.noteBody("pending more")
    let second = session.save(current: fixture.source)
    store.noteCommitted(identity: "draft", generation: first.generation)
    XCTAssertEqual(store.draft(for: "draft")?.body, "pending more")
    XCTAssertNotEqual(first.generation, second.generation)
    store.noteCommitted(identity: "draft", generation: second.generation)
    XCTAssertNil(store.draft(for: "draft"))
  }

  func testEmptyConflictAndRefusalsDoNotStrip() {
    let fixture = richItem(plain: "Alpha", html: "<b>Alpha</b>")
    let session = session(fixture, identity: "refuse")
    session.noteBody("   ")
    let empty = session.save(current: fixture.source)
    XCTAssertEqual(empty.status, .rejected(.empty))
    XCTAssertFalse(empty.applyColumnChanges)
    XCTAssertEqual(session.store.draft(for: "refuse")?.body, "   ")

    session.noteBody("changed")
    var moved = fixture.source
    moved.representations[0].value = Data("other".utf8)
    let conflict = session.save(current: moved)
    XCTAssertEqual(conflict.status, .rejected(.conflict))
    XCTAssertFalse(conflict.applyColumnChanges)
    XCTAssertEqual(session.store.draft(for: "refuse")?.body, "changed")

    var removed = fixture.source
    removed.removed = true
    XCTAssertEqual(RichTextSession(store: RichTextDraftStore()).load(identity: "gone", source: removed).refusal, .removed)
    let removedSave = RichTextSession(store: RichTextDraftStore())
    removedSave.load(identity: "gone", source: removed)
    XCTAssertFalse(removedSave.save(current: removed).applyColumnChanges)

    var truncated = fixture.source
    truncated.previewTruncated = true
    let truncatedSession = RichTextSession(store: RichTextDraftStore())
    truncatedSession.load(identity: "cut", source: truncated)
    truncatedSession.noteBody("fragment")
    XCTAssertFalse(truncatedSession.save(current: truncated).applyColumnChanges)

    var image = fixture.source
    image.image = true
    let imageSession = RichTextSession(store: RichTextDraftStore())
    imageSession.load(identity: "img", source: image)
    imageSession.noteBody("nope")
    XCTAssertFalse(imageSession.save(current: image).applyColumnChanges)
  }

  func testRebindMovesDraftAndDoesNotResurrectTheOldIdentity() {
    let store = RichTextDraftStore()
    let session = RichTextSession(store: store)
    session.load(identity: "old", source: richItem(plain: "Alpha", html: "<b>Alpha</b>").source)
    session.noteBody("kept")
    XCTAssertTrue(store.rebind(from: "old", to: "new"))
    XCTAssertNil(store.draft(for: "old"))
    XCTAssertEqual(store.draft(for: "new")?.body, "kept")
    store.noteCommitted(identity: "old", generation: store.draft(for: "new")?.generation ?? 0)
    XCTAssertEqual(store.draft(for: "new")?.body, "kept")
    store.retain(RichTextDraft(
      identity: "taken",
      generation: 1,
      body: "other",
      title: "",
      baselineBody: "",
      baselineTitle: "",
      baselineRepresentations: []
    ))
    XCTAssertFalse(store.rebind(from: "new", to: "taken"))
    XCTAssertEqual(store.draft(for: "taken")?.body, "other")
    XCTAssertEqual(store.draft(for: "new")?.body, "kept")
  }

  func testRTFRendersAndSafeHTMLKeepsEmphasisColorAndLink() {
    let rtf = richItem(plain: "Alpha", html: "<b>Alpha</b>")
    let rtfAssessment = RichTextModel.assess(rtf.source)
    XCTAssertEqual(rtfAssessment.presentation, .richText)
    XCTAssertEqual(rtfAssessment.refusal, nil)
    XCTAssertTrue(traits(rtfAssessment.display, at: 0).contains(.boldFontMask))

    let html = Data("<meta charset=\"utf-8\"><span style=\"color:#cc1919\"><b>Alpha</b></span> <a href=\"https://example.com/docs\">link</a>".utf8)
    let assessment = RichTextModel.assess(RichTextSource(representations: [
      RichTextRepresentation(type: NSPasteboard.PasteboardType.html.rawValue, value: html)
    ]))
    XCTAssertEqual(assessment.presentation, .richText)
    XCTAssertEqual(assessment.display.string.contains("Alpha"), true)
    XCTAssertTrue(traits(assessment.display, at: 0).contains(.boldFontMask))
    let color = (assessment.display.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
    XCTAssertEqual(color?.redComponent ?? 0, 204 / 255, accuracy: 0.02)
    XCTAssertEqual(color?.greenComponent ?? 1, 25 / 255, accuracy: 0.02)
    let linkRange = (assessment.display.string as NSString).range(of: "link")
    XCTAssertEqual(assessment.display.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL, URL(string: "https://example.com/docs"))
    XCTAssertEqual(RichTextLimits.maxEditableCharacters, PreviewLimits.maxDisplayCharacters)
    XCTAssertEqual(RichTextLimits.maxEditableBytes, PreviewLimits.maxTextReadBytes)
  }

  func testUnsafeHTMLFallsBackToReadableTextWithoutLoadingOrExecuting() {
    let html = """
    <p>Hi</p><table><tr><td>cell</td></tr></table>\
    <script>alert(1)</script><img src="http://127.0.0.1:9/nope.png">\
    <a href="javascript:alert(1)">bad</a>
    """.data(using: .utf8)!
    let assessment = RichTextModel.assess(RichTextSource(representations: [
      RichTextRepresentation(type: NSPasteboard.PasteboardType.html.rawValue, value: html)
    ]))
    XCTAssertEqual(assessment.presentation, .readableText)
    XCTAssertFalse(assessment.risks.isEmpty)
    XCTAssertTrue(assessment.display.string.contains("Hi"))
    XCTAssertTrue(assessment.display.string.contains("cell"))
    XCTAssertTrue(assessment.display.string.contains("bad"))
    XCTAssertFalse(assessment.display.string.contains("alert"))
    XCTAssertFalse(assessment.display.string.contains("127.0.0.1"))
    XCTAssertNil(assessment.display.attribute(.link, at: 0, effectiveRange: nil))
    XCTAssertNil(assessment.display.attribute(.attachment, at: 0, effectiveRange: nil))
    XCTAssertNotNil(assessment.editBody)
    let session = RichTextSession(store: RichTextDraftStore())
    session.load(identity: "unsafe", source: RichTextSource(representations: [
      RichTextRepresentation(type: NSPasteboard.PasteboardType.html.rawValue, value: html)
    ]))
    let kept = session.save(current: session.source)
    XCTAssertFalse(kept.applyColumnChanges)
    XCTAssertTrue(kept.columnChanges.isEmpty)
  }

  func testOversizedTextCannotReplaceTheCompleteItem() {
    let huge = String(repeating: "x", count: RichTextLimits.maxEditableCharacters + 1)
    let source = RichTextSource(representations: [
      RichTextRepresentation(type: RichTextTypes.plainUTF8, value: Data(huge.utf8)),
      RichTextRepresentation(type: RichTextTypes.rtf, value: Data("{\\rtf1 nope}".utf8))
    ])
    let session = RichTextSession(store: RichTextDraftStore())
    let assessment = session.load(identity: "big", source: source)
    XCTAssertEqual(assessment.refusal, .oversized)
    session.noteBody("fragment")
    let transaction = session.save(current: source)
    XCTAssertFalse(transaction.applyColumnChanges)
    XCTAssertTrue(transaction.columnChanges.isEmpty)
  }

  func testDisplayIsOneScrollViewAndEditHintIsOnlyTheShortTooltip() throws {
    let fixture = richItem(plain: "Alpha", html: "<b>Alpha</b>")
    let display = RichTextEditBox(
      display: RichTextModel.assess(fixture.source).display,
      draft: "Alpha",
      editing: false,
      rich: true,
      token: 1,
      onText: { _ in },
      onSave: {},
      onCancel: {}
    )
    let shown = try mount(display)
    let scroll = try XCTUnwrap(find("lab-rich-text-scroll", in: shown) as? NSScrollView)
    XCTAssertEqual(scrollCount(scroll), 1)
    let textView = try XCTUnwrap(scroll.documentView as? RichTextBodyView)
    XCTAssertEqual(textView.accessibilityIdentifier(), "lab-rich-text-body")
    XCTAssertTrue(textView.isRichText)
    XCTAssertFalse(textView.isEditable)
    XCTAssertNil(textView.toolTip)
    XCTAssertNil(textView.accessibilityHelp())
    XCTAssertTrue(labels(in: shown).allSatisfy { $0.count <= 8 })

    let editing = RichTextEditBox(
      display: NSAttributedString(string: "Alpha"),
      draft: "Alpha",
      editing: true,
      rich: true,
      token: 2,
      onText: { _ in },
      onSave: {},
      onCancel: {}
    )
    let editor = try mount(editing)
    let editingView = try XCTUnwrap((find("lab-rich-text-scroll", in: editor) as? NSScrollView)?.documentView as? RichTextBodyView)
    XCTAssertFalse(editingView.isRichText)
    XCTAssertTrue(editingView.isEditable)
    XCTAssertEqual(editingView.toolTip, nil)
    XCTAssertNil(editingView.accessibilityHelp())
    let handled = editingView.delegate?.textView?(editingView, clickedOnLink: URL(string: "https://example.com")!, at: 0)
    XCTAssertEqual(handled, true)
    XCTAssertEqual(editingView.linkAttempts, 1)
    XCTAssertFalse(panel?.isVisible ?? true)
    XCTAssertFalse(panel?.isKeyWindow ?? true)
    XCTAssertLessThan(panel?.frame.maxX ?? 0, 0)
  }

  func testRichDisplayHonorsWrapOffWithoutFlattening() throws {
    let long = String(repeating: "RICHWRAP ", count: 16)
    let font = NSFont.boldSystemFont(ofSize: 13)
    let display = NSAttributedString(string: long, attributes: [.font: font])
    let box = RichTextEditBox(
      display: display,
      draft: long,
      editing: false,
      rich: true,
      token: 1,
      wraps: false,
      onText: { _ in },
      onSave: {},
      onCancel: {}
    )
    let shown = try mount(box.frame(width: 180, height: 90))
    let scroll = try XCTUnwrap(find("lab-rich-text-scroll", in: shown) as? NSScrollView)
    let textView = try XCTUnwrap(scroll.documentView as? RichTextBodyView)
    XCTAssertFalse(textView.textContainer?.widthTracksTextView ?? true)
    XCTAssertTrue(textView.isHorizontallyResizable)
    XCTAssertTrue(scroll.hasHorizontalScroller)
    XCTAssertTrue(textView.isRichText)
    XCTAssertFalse(textView.isEditable)
    XCTAssertTrue(textView.acceptsFirstMouse(for: nil))
    XCTAssertEqual(textView.attributedString().string, long)
    let kept = try XCTUnwrap(textView.attributedString().attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    XCTAssertTrue(NSFontManager.shared.traits(of: kept).contains(.boldFontMask), "wrap off flattened rich display")
  }

  func testBodyOnlyTitleTransactionKeepsRepresentationsWithoutATitleField() {
    let source = RichTextSource(
      representations: [
        RichTextRepresentation(type: RichTextTypes.plainUTF8, value: Data("正文".utf8)),
        RichTextRepresentation(type: RichTextTypes.rtf, value: Data("{\\rtf1 body}".utf8))
      ],
      title: "原标题 "
    )
    let before = source.representations.map(\.value)
    let session = RichTextSession(store: RichTextDraftStore())
    session.load(identity: "title-keep", source: source)
    XCTAssertEqual(session.editedBody, "正文")
    XCTAssertEqual(source.representations.map(\.value), before)
  }

  func testAccessibilityValueOnRichBodyUsesTheDraftPath() {
    let view = RichTextBodyView(usingTextLayoutManager: false)
    view.isEditable = true
    view.string = "合成粗体保留"
    var noted: String?
    view.onText = { noted = $0 }
    view.setAccessibilityValue("合成纯文本已保存")
    XCTAssertEqual(view.string, "合成纯文本已保存")
    XCTAssertEqual(noted, "合成纯文本已保存")
  }

  func testColumnReadoutOmitsPayloadText() {
    let rtf = Data("{\\rtf not-shown}".utf8)
    let plain = Data("合成粗体保留".utf8)
    let summary = RichColumnReadout.summary([
      (NSPasteboard.PasteboardType.rtf.rawValue, rtf),
      (NSPasteboard.PasteboardType.string.rawValue, plain)
    ])
    XCTAssertFalse(summary.contains("合成"))
    XCTAssertFalse(summary.contains("rtf1"))
    XCTAssertTrue(summary.contains("\(rtf.count)"))
    XCTAssertTrue(summary.contains("\(plain.count)"))
    let bold = NSMutableAttributedString(string: "合成粗体保留")
    bold.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13), range: NSRange(location: 0, length: 2))
    XCTAssertEqual(RichColumnReadout.traits(bold), "0-2:bold")
  }

  /// Known lossless plain must not be replaced by a conflicting RTF/HTML reading.
  /// A matching rich body keeps its styles. Structural newlines are not a conflict.
  /// This does not reproduce the user's screenshot item; those bytes were not available.
  func testKnownPlainIsNotReplacedByInconsistentRichAndConsistentChineseKeepsStyle() throws {
    let plain = "中文 English"
    let plainData = Data(plain.utf8)
    let hello = NSAttributedString(string: "hello", attributes: [.font: NSFont.systemFont(ofSize: 13)])
    let conflictingRTF = try XCTUnwrap(hello.rtf(from: NSRange(location: 0, length: hello.length), documentAttributes: [:]))
    let conflictingHTML = Data("<p>hello</p>".utf8)
    let conflict = RichTextSource(representations: [
      RichTextRepresentation(type: "public.utf16-plain-text", value: Data([0x2D, 0x4E, 0x87, 0x65])),
      RichTextRepresentation(type: RichTextTypes.plainUTF8, value: plainData),
      RichTextRepresentation(type: RichTextTypes.rtf, value: conflictingRTF),
      RichTextRepresentation(type: NSPasteboard.PasteboardType.html.rawValue, value: conflictingHTML)
    ])
    let conflicted = RichTextModel.assess(conflict)
    XCTAssertEqual(conflicted.display.string, plain)
    XCTAssertEqual(conflicted.editBody, plain, "conflict must not rewrite the edit string")
    XCTAssertEqual(conflicted.presentation, .readableText)
    XCTAssertFalse(conflicted.display.string.contains("hello"))
    let fallbackColor = conflicted.display.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    XCTAssertEqual(fallbackColor, NSColor.labelColor)
    XCTAssertEqual(conflict.representations.map(\.value), [
      Data([0x2D, 0x4E, 0x87, 0x65]), plainData, conflictingRTF, conflictingHTML
    ])

    let reversed = RichTextSource(representations: [
      RichTextRepresentation(type: RichTextTypes.plainUTF8, value: plainData),
      RichTextRepresentation(type: "public.utf16-plain-text", value: Data([0x2D, 0x4E, 0x87, 0x65]))
    ] + conflict.representations.dropFirst(2))
    XCTAssertEqual(RichTextModel.assess(reversed).editBody, conflicted.editBody)

    let crlf = "中文\r\nEnglish"
    let styled = Data("<meta charset=\"utf-8\"><p><span style=\"color:#cc1919\"><b>中文</b></span></p><p>English</p>".utf8)
    let matched = RichTextSource(representations: [
      RichTextRepresentation(type: RichTextTypes.plainUTF8, value: Data(crlf.utf8)),
      RichTextRepresentation(type: NSPasteboard.PasteboardType.html.rawValue, value: styled)
    ])
    let kept = RichTextModel.assess(matched)
    XCTAssertEqual(kept.presentation, .richText, "structural CRLF/block newline was treated as a conflict")
    XCTAssertTrue(kept.display.string.contains("中文"))
    XCTAssertEqual(kept.editBody, crlf, "comparison rewrote the edit string")
    XCTAssertTrue(traits(kept.display, at: 0).contains(.boldFontMask))
    let red = (kept.display.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
    XCTAssertEqual(red?.redComponent ?? 0, 204 / 255, accuracy: 0.02)
    XCTAssertEqual(red?.greenComponent ?? 1, 25 / 255, accuracy: 0.02)
    XCTAssertEqual(matched.representations[1].value, styled)

    let htmlOnly = Data("<p><b>中文样式</b></p>".utf8)
    let noPlain = RichTextModel.assess(RichTextSource(representations: [
      RichTextRepresentation(type: NSPasteboard.PasteboardType.html.rawValue, value: htmlOnly)
    ]))
    XCTAssertEqual(noPlain.presentation, .richText)
    XCTAssertTrue(noPlain.display.string.contains("中文样式"))
    XCTAssertTrue(traits(noPlain.display, at: 0).contains(.boldFontMask))
    XCTAssertEqual(
      RichTextSource(representations: [RichTextRepresentation(type: NSPasteboard.PasteboardType.html.rawValue, value: htmlOnly)]).representations[0].value,
      htmlOnly
    )
  }

  /// No-color runs get labelColor on the display copy. Explicit emphasis stays.
  /// Drawn through the existing offscreen RichTextEditBox host. Not the user's screenshot item.
  func testUncoloredRunsDrawLabelInkAndKeepExplicitEmphasis() throws {
    let plain = "正文黑字 REDWORD"
    let html = Data("<p>正文黑字 <span style=\"color:#cc0000\"><b>REDWORD</b></span></p>".utf8)
    let htmlSource = RichTextSource(representations: [
      RichTextRepresentation(type: RichTextTypes.plainUTF8, value: Data(plain.utf8)),
      RichTextRepresentation(type: NSPasteboard.PasteboardType.html.rawValue, value: html)
    ])
    let htmlAssessed = RichTextModel.assess(htmlSource)
    XCTAssertEqual(htmlAssessed.presentation, .richText)
    let bodyColor = htmlAssessed.display.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    XCTAssertEqual(bodyColor, NSColor.labelColor, "no-color HTML run was left without a display foreground")
    let redRange = (htmlAssessed.display.string as NSString).range(of: "REDWORD")
    let keptRed = (htmlAssessed.display.attribute(.foregroundColor, at: redRange.location, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
    XCTAssertGreaterThan(keptRed?.redComponent ?? 0, 0.6)
    XCTAssertTrue(traits(htmlAssessed.display, word: "REDWORD").contains(.boldFontMask))
    XCTAssertEqual(htmlSource.representations[1].value, html)

    let bare = NSAttributedString(string: "正文黑字", attributes: [.font: NSFont.systemFont(ofSize: 13)])
    let rtf = try XCTUnwrap(bare.rtf(from: NSRange(location: 0, length: bare.length), documentAttributes: [:]))
    let rtfSource = RichTextSource(representations: [
      RichTextRepresentation(type: RichTextTypes.plainUTF8, value: Data("正文黑字".utf8)),
      RichTextRepresentation(type: RichTextTypes.rtf, value: rtf)
    ])
    let rtfAssessed = RichTextModel.assess(rtfSource)
    XCTAssertTrue(rtfAssessed.display.string.contains("正文黑字"))
    XCTAssertEqual(rtfAssessed.editBody, "正文黑字")
    XCTAssertEqual(rtfSource.representations[1].value, rtf)
    let imported = NSAttributedString(rtf: rtf, documentAttributes: nil)
    let importedColor = imported?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    let shownColor = rtfAssessed.display.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    if importedColor == nil {
      XCTAssertEqual(shownColor, NSColor.labelColor, "no-color RTF run was left without a display foreground")
    } else {
      let before = importedColor?.usingColorSpace(.sRGB)
      let after = shownColor?.usingColorSpace(.sRGB)
      XCTAssertEqual(after?.redComponent ?? -1, before?.redComponent ?? -2, accuracy: 0.02, "importer color was replaced")
    }

    let hello = NSAttributedString(string: "hello", attributes: [.font: NSFont.systemFont(ofSize: 13)])
    let foreign = try XCTUnwrap(hello.rtf(from: NSRange(location: 0, length: hello.length), documentAttributes: [:]))
    let fallbackSource = RichTextSource(representations: [
      RichTextRepresentation(type: RichTextTypes.plainUTF8, value: Data("正文黑字".utf8)),
      RichTextRepresentation(type: RichTextTypes.rtf, value: foreign)
    ])
    let fallback = RichTextModel.assess(fallbackSource)
    XCTAssertEqual(fallback.display.string, "正文黑字")
    XCTAssertEqual(fallback.display.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, NSColor.labelColor)
    XCTAssertEqual(fallbackSource.representations[1].value, foreign)

    for name in [NSAppearance.Name.darkAqua, NSAppearance.Name.aqua] {
      try assertDrawnLabelDirection(htmlAssessed.display, appearanceName: name, word: "正文黑字", keepRed: true)
      try assertDrawnLabelDirection(fallback.display, appearanceName: name, word: "正文黑字", keepRed: false)
      try assertDrawnLabelDirection(rtfAssessed.display, appearanceName: name, word: "正文黑字", keepRed: false)
    }
  }

  private func assertDrawnLabelDirection(
    _ display: NSAttributedString,
    appearanceName: NSAppearance.Name,
    word: String,
    keepRed: Bool
  ) throws {
    let before = display.string
    let shown = try mountReadable(display, appearanceName: appearanceName)
    let textView = try XCTUnwrap(shown.textView)
    textView.layoutManager?.ensureLayout(for: textView.textContainer!)
    let canvas = appearanceName == .darkAqua
      ? Ink(r: 0.101, g: 0.101, b: 0.101, a: 1, count: 0)
      : resolvedCanvas(.aqua)
    let render = try renderInk(textView, canvas: canvas, label: "uncolored-\(word)-\(appearanceName.rawValue)")
    let ink = try XCTUnwrap(render.ink[word], "\(appearanceName.rawValue) no ink for \(word)")
    var expected = Ink(r: 0, g: 0, b: 0, a: 1, count: 0)
    NSAppearance(named: appearanceName)?.performAsCurrentDrawingAppearance {
      let color = NSColor.labelColor.usingColorSpace(.sRGB) ?? NSColor.labelColor
      expected = Ink(r: color.redComponent, g: color.greenComponent, b: color.blueComponent, a: 1, count: 0)
    }
    let black = Ink(r: 0, g: 0, b: 0, a: 1, count: 0)
    let white = Ink(r: 1, g: 1, b: 1, a: 1, count: 0)
    XCTAssertGreaterThanOrEqual(contrast(ink, canvas), 4.5, "\(appearanceName.rawValue) uncolored ink contrast")
    if appearanceName == .darkAqua {
      XCTAssertLessThan(colorDistance(ink, expected), colorDistance(ink, black), "dark uncolored ink stayed nearer black than label")
    } else {
      XCTAssertLessThan(colorDistance(ink, expected), colorDistance(ink, white), "light uncolored ink stayed nearer white than label")
    }
    if keepRed {
      let red = try XCTUnwrap(render.ink["REDWORD"], "explicit emphasis ink was not rendered")
      XCTAssertGreaterThan(red.r, red.g + 0.12)
      XCTAssertGreaterThan(colorDistance(red, ink), 0.15)
    }
    XCTAssertEqual(display.string, before, "drawing mutated the display string")
    XCTAssertFalse(shown.panel.isVisible)
    XCTAssertFalse(shown.panel.isKeyWindow)
    XCTAssertLessThan(shown.panel.frame.maxX, 0)
  }

  /// Offscreen pixel signal for the parent-verified dark-canvas failure.
  /// Canvas sRGB 0.101 is the corner color of 03-html.png and 04-rtf.png.
  /// Pass requires rendered ink, not a configuration flag.
  func testUneditedRichDisplayStaysReadableOnDarkAndLightCanvas() throws {
    let fixtures = [
      try readabilitySource(kind: "rtf"),
      try readabilitySource(kind: "html")
    ]
    for appearanceName in [NSAppearance.Name.darkAqua, NSAppearance.Name.aqua] {
      for fixture in fixtures {
        try assertReadable(fixture, appearanceName: appearanceName)
      }
    }
  }

  // MARK: - Fixtures

  private struct Fixture {
    var source: RichTextSource
    var original: [RichTextRepresentation]
    var rtf: Data
    var html: Data
    var oldUTF16: Data
  }

  private func richItem(plain: String, html: String) -> Fixture {
    let font = NSFont(name: "Helvetica", size: 14)!
    let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    let text = NSMutableAttributedString(string: plain, attributes: [.font: font])
    text.addAttribute(.font, value: bold, range: NSRange(location: 0, length: min(5, text.length)))
    let rtf = text.rtf(from: NSRange(location: 0, length: text.length), documentAttributes: [:])!
    let htmlData = Data(html.utf8)
    let oldUTF16 = Data("stale-utf16".utf8)
    let representations = [
      RichTextRepresentation(type: RichTextTypes.plainUTF8, value: Data(plain.utf8)),
      RichTextRepresentation(type: "public.utf16-plain-text", value: oldUTF16),
      RichTextRepresentation(type: RichTextTypes.rtf, value: rtf),
      RichTextRepresentation(type: NSPasteboard.PasteboardType.html.rawValue, value: htmlData),
      RichTextRepresentation(type: "com.apple.WebKit.custom-pasteboard-data", value: Data("stale-html".utf8)),
      RichTextRepresentation(type: NSPasteboard.PasteboardType.png.rawValue, value: Data([0x89, 0x50, 0x4E, 0x47]))
    ]
    return Fixture(
      source: RichTextSource(representations: representations, title: "title"),
      original: representations,
      rtf: rtf,
      html: htmlData,
      oldUTF16: oldUTF16
    )
  }

  private func session(_ fixture: Fixture, identity: String) -> RichTextSession {
    session(fixture.source, identity: identity)
  }

  private func session(_ source: RichTextSource, identity: String) -> RichTextSession {
    let session = RichTextSession(store: RichTextDraftStore())
    session.load(identity: identity, source: source)
    return session
  }

  private func deleted(_ transaction: RichTextSaveTransaction, _ type: String) -> Bool {
    transaction.columnChanges.contains { $0.type == type && $0.action == .delete }
  }

  private func replacedPlain(_ transaction: RichTextSaveTransaction, type: String = RichTextTypes.plainUTF8) -> Data? {
    for change in transaction.columnChanges where change.type == type {
      if case .replace(let data) = change.action { return data }
    }
    return nil
  }

  private func assertNoStripUnlessBodyChanged(_ transaction: RichTextSaveTransaction) {
    if transaction.applyColumnChanges {
      XCTAssertTrue(transaction.bodyChanged)
      XCTAssertEqual(transaction.status, .ready)
      XCTAssertFalse(transaction.columnChanges.isEmpty)
    } else {
      XCTAssertFalse(transaction.columnChanges.contains {
        if case .delete = $0.action { return true }
        return false
      })
    }
  }

  private func traits(_ text: NSAttributedString, at index: Int) -> NSFontTraitMask {
    guard let font = text.attribute(.font, at: index, effectiveRange: nil) as? NSFont else { return [] }
    return NSFontManager.shared.traits(of: font)
  }

  private func mount<V: View>(_ view: V) throws -> NSView {
    let panel = NSPanel(
      contentRect: NSRect(x: -24000, y: -24000, width: 320, height: 160),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(x: 0, y: 0, width: 320, height: 160)
    panel.contentView = host
    self.panel?.close()
    self.panel = panel
    let deadline = Date().addingTimeInterval(1.5)
    while Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
      host.layoutSubtreeIfNeeded()
      if find("lab-rich-text-scroll", in: host) != nil { break }
    }
    XCTAssertFalse(panel.isVisible)
    XCTAssertFalse(panel.isKeyWindow)
    return host
  }

  private func find(_ id: String, in root: NSView) -> NSView? {
    if root.accessibilityIdentifier() == id { return root }
    for subview in root.subviews {
      if let found = find(id, in: subview) { return found }
    }
    return nil
  }

  private func scrollCount(_ view: NSView) -> Int {
    (view is NSScrollView ? 1 : 0) + view.subviews.reduce(0) { $0 + scrollCount($1) }
  }

  private func labels(in view: NSView) -> [String] {
    var result: [String] = []
    if let field = view as? NSTextField { result.append(field.stringValue) }
    for subview in view.subviews { result.append(contentsOf: labels(in: subview)) }
    return result
  }

  private struct ReadabilityFixture {
    var kind: String
    var source: RichTextSource
    var payload: Data
    var display: NSAttributedString
  }

  private struct Ink {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat
    var a: CGFloat
    var count: Int
  }

  private func readabilitySource(kind: String) throws -> ReadabilityFixture {
    let black = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    let red = NSColor(srgbRed: 0.8, green: 0, blue: 0, alpha: 1)
    let headingFont = NSFont.boldSystemFont(ofSize: 22)
    let bodyFont = NSFont.systemFont(ofSize: 13)
    if kind == "rtf" {
      let text = NSMutableAttributedString()
      text.append(NSAttributedString(string: "标题大字\n", attributes: [
        .font: headingFont, .foregroundColor: black
      ]))
      text.append(NSAttributedString(string: "正文黑字 ", attributes: [
        .font: bodyFont, .foregroundColor: black
      ]))
      text.append(NSAttributedString(string: "REDWORD", attributes: [
        .font: bodyFont, .foregroundColor: red
      ]))
      let range = NSRange(location: 0, length: text.length)
      let rtf = try XCTUnwrap(text.rtf(from: range, documentAttributes: [:]))
      let source = RichTextSource(representations: [
        RichTextRepresentation(type: RichTextTypes.plainUTF8, value: Data("标题大字\n正文黑字 REDWORD".utf8)),
        RichTextRepresentation(type: RichTextTypes.rtf, value: rtf)
      ], title: "rtf-readability")
      return ReadabilityFixture(kind: kind, source: source, payload: rtf, display: RichTextModel.assess(source).display)
    }
    let html = """
    <!DOCTYPE html><html><head><meta charset="utf-8"></head><body>\
    <p style="font-size:22pt;font-weight:bold;color:#000000">标题大字</p>\
    <p style="font-size:13pt;color:#000000">正文黑字 <span style="color:#cc0000">REDWORD</span></p>\
    </body></html>
    """
    let data = Data(html.utf8)
    let source = RichTextSource(representations: [
      RichTextRepresentation(type: NSPasteboard.PasteboardType.html.rawValue, value: data)
    ], title: "html-readability")
    let assessed = RichTextModel.assess(source)
    XCTAssertTrue(assessed.display.string.contains("标题大字"), "html display=\(assessed.display.string)")
    return ReadabilityFixture(kind: kind, source: source, payload: data, display: assessed.display)
  }

  private func assertReadable(_ fixture: ReadabilityFixture, appearanceName: NSAppearance.Name) throws {
    let beforePayload = fixture.payload
    let beforeReps = fixture.source.representations
    let beforeBody = foregroundComponents(fixture.display, word: "正文黑字")
    XCTAssertLessThan(beforeBody?.r ?? 1, 0.2, "\(fixture.kind) fixture lost explicit black")
    let shown = try mountReadable(fixture.display, appearanceName: appearanceName)
    let textView = try XCTUnwrap(shown.textView)
    textView.layoutManager?.ensureLayout(for: textView.textContainer!)
    let label = "\(fixture.kind)-\(appearanceName.rawValue)"
    XCTAssertTrue(textView.string.contains("正文黑字"), "\(label) string=\(textView.string)")
    XCTAssertTrue(textView.string.contains("REDWORD"))
    XCTAssertTrue(textView.string.contains("标题大字"))
    let headingFont = font(textView.attributedString(), word: "标题大字")
    let bodyFont = font(textView.attributedString(), word: "正文黑字")
    XCTAssertGreaterThan(headingFont?.pointSize ?? 0, (bodyFont?.pointSize ?? 0) + 4, label)
    XCTAssertTrue(traits(textView.attributedString(), word: "标题大字").contains(.boldFontMask), label)
    XCTAssertFalse(traits(textView.attributedString(), word: "正文黑字").contains(.boldFontMask), label)

    let canvas = appearanceName == .darkAqua
      ? Ink(r: 0.101, g: 0.101, b: 0.101, a: 1, count: 0)
      : resolvedCanvas(.aqua)
    let render = try renderInk(textView, canvas: canvas, label: label)
    let body = try XCTUnwrap(render.ink["正文黑字"], "\(label) no body ink; seam did not draw")
    let heading = try XCTUnwrap(render.ink["标题大字"], "\(label) no heading ink")
    let red = try XCTUnwrap(render.ink["REDWORD"], "\(label) no red ink")
    let bodyContrast = contrast(body, canvas)
    let headingContrast = contrast(heading, canvas)
    fputs(
      String(format: "RICH-READABILITY %@ body=%.3f,%.3f,%.3f c=%.2f head=%.3f,%.3f,%.3f c=%.2f red=%.3f,%.3f,%.3f map=%d appearance=%@ png=%@\n",
             label, body.r, body.g, body.b, bodyContrast, heading.r, heading.g, heading.b, headingContrast,
             red.r, red.g, red.b, textView.usesAdaptiveColorMappingForDarkAppearance ? 1 : 0,
             textView.effectiveAppearance.name.rawValue, render.path),
      stderr
    )
    fflush(stderr)
    XCTAssertGreaterThanOrEqual(bodyContrast, 4.5, "\(label) body contrast \(bodyContrast)")
    XCTAssertGreaterThanOrEqual(headingContrast, 3.0, "\(label) heading contrast \(headingContrast)")
    XCTAssertGreaterThan(red.r, red.g + 0.12, "\(label) red emphasis flattened")
    XCTAssertGreaterThan(red.r, red.b + 0.12, "\(label) red emphasis flattened")
    XCTAssertGreaterThan(colorDistance(red, body), 0.15, "\(label) red matches body")
    if appearanceName == .aqua {
      XCTAssertLessThan(body.r, 0.45, "\(label) light mode inverted body ink")
    }
    let headingRect = glyphRect(textView, word: "标题大字")
    let bodyRect = glyphRect(textView, word: "正文黑字")
    XCTAssertGreaterThan(headingRect.height, bodyRect.height * 1.15, "\(label) size hierarchy missing in glyphs")
    XCTAssertEqual(fixture.source.representations, beforeReps, "\(label) display mutated source representations")
    XCTAssertEqual(fixture.payload, beforePayload)
    let afterBody = foregroundComponents(fixture.display, word: "正文黑字")
    XCTAssertEqual(afterBody?.r ?? -1, beforeBody?.r ?? -2, accuracy: 0.02, "\(label) caller display color changed")
    XCTAssertFalse(shown.panel.isVisible)
    XCTAssertFalse(shown.panel.isKeyWindow)
    XCTAssertLessThan(shown.panel.frame.maxX, 0)
    let session = RichTextSession(store: RichTextDraftStore())
    session.load(identity: "readability-\(label)", source: fixture.source)
    let untouched = session.save(current: fixture.source)
    XCTAssertFalse(untouched.applyColumnChanges)
    XCTAssertTrue(untouched.columnChanges.isEmpty)
  }

  private func mountReadable(_ display: NSAttributedString, appearanceName: NSAppearance.Name) throws -> (panel: NSPanel, textView: RichTextBodyView?) {
    let appearance = NSAppearance(named: appearanceName)
    let panel = SilentRichPanel(
      contentRect: NSRect(x: -24000, y: -24000, width: 460, height: 180),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isReleasedWhenClosed = false
    panel.appearance = appearance
    let box = RichTextEditBox(
      display: display,
      draft: display.string,
      editing: false,
      rich: true,
      token: 1,
      wraps: true,
      onText: { _ in },
      onSave: {},
      onCancel: {}
    )
    let host = NSHostingView(rootView: box.frame(width: 460, height: 180))
    host.appearance = appearance
    host.frame = NSRect(x: 0, y: 0, width: 460, height: 180)
    self.panel?.close()
    self.panel = panel
    panel.contentView = host
    let deadline = Date().addingTimeInterval(1.5)
    var textView: RichTextBodyView?
    while Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
      host.layoutSubtreeIfNeeded()
      textView = (find("lab-rich-text-scroll", in: host) as? NSScrollView)?.documentView as? RichTextBodyView
      if textView != nil { break }
    }
    textView?.appearance = appearance
    textView?.enclosingScrollView?.appearance = appearance
    return (panel, textView)
  }

  private func renderInk(_ textView: NSTextView, canvas: Ink, label: String) throws -> (ink: [String: Ink], path: String) {
    textView.wantsLayer = false
    textView.layoutSubtreeIfNeeded()
    textView.layoutManager?.ensureLayout(for: textView.textContainer!)
    let used = textView.layoutManager?.usedRect(for: textView.textContainer!) ?? .zero
    let width = max(used.width + 8, 280)
    let height = max(used.height + 8, 72)
    textView.frame = NSRect(x: 0, y: 0, width: width, height: height)
    textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    textView.layoutManager?.ensureLayout(for: textView.textContainer!)
    let scale: CGFloat = 2
    let pixelsWide = max(1, Int((width * scale).rounded()))
    let pixelsHigh = max(1, Int((height * scale).rounded()))
    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: pixelsWide,
      pixelsHigh: pixelsHigh,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ) else {
      XCTFail("\(label) bitmap unavailable")
      return ([:], "")
    }
    rep.size = NSSize(width: width, height: height)
    let topIsLowY = bitmapTopIsLowY(size: NSSize(width: width, height: height), pixelsWide: pixelsWide, pixelsHigh: pixelsHigh)
    textView.cacheDisplay(in: textView.bounds, to: rep)
    _ = writeComposite(rep, label: "\(label)-cache")
    let shown = try compositeSourceOver(rep, canvas: canvas, label: label)
    let edge = byteSample(shown, x: max(0, shown.pixelsWide - 2), y: shown.pixelsHigh / 2)
    guard colorDistance(edge, canvas) < 0.08 else {
      _ = writeComposite(shown, label: label)
      XCTFail("\(label) composite did not keep canvas; measurement invalid edge=\(edge.r),\(edge.g),\(edge.b)")
      throw CocoaError(.fileReadCorruptFile)
    }
    var ink: [String: Ink] = [:]
    for word in ["标题大字", "正文黑字", "REDWORD"] {
      let rect = glyphRect(textView, word: word)
      let scaled = NSRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
      ink[word] = medianInk(shown, rect: scaled, canvas: canvas, pixelsHigh: pixelsHigh, topIsLowY: topIsLowY)
    }
    let path = writeComposite(shown, label: label)
    return (ink, path)
  }

  private func bitmapTopIsLowY(size: NSSize, pixelsWide: Int, pixelsHigh: Int) -> Bool {
    let probe = FlippedAxisProbe(frame: NSRect(origin: .zero, size: size))
    probe.wantsLayer = false
    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: pixelsWide,
      pixelsHigh: pixelsHigh,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ) else { return true }
    rep.size = size
    probe.cacheDisplay(in: probe.bounds, to: rep)
    let low = rep.colorAt(x: pixelsWide / 2, y: 2)?.usingColorSpace(.deviceRGB)
    return (low?.redComponent ?? 0) > 0.5
  }

  private func medianInk(
    _ rep: NSBitmapImageRep,
    rect: NSRect,
    canvas: Ink,
    pixelsHigh: Int,
    topIsLowY: Bool
  ) -> Ink? {
    let x0 = max(0, Int(rect.minX.rounded(.down)))
    let x1 = min(rep.pixelsWide - 1, Int(rect.maxX.rounded(.up)))
    let y0 = max(0, Int(rect.minY.rounded(.down)))
    let y1 = min(pixelsHigh - 1, Int(rect.maxY.rounded(.up)))
    guard x1 > x0, y1 > y0 else { return nil }
    var samples: [Ink] = []
    for viewY in y0...y1 {
      let bitmapY = topIsLowY ? viewY : (pixelsHigh - 1 - viewY)
      guard bitmapY >= 0, bitmapY < pixelsHigh else { continue }
      for x in x0...x1 {
        let sample = byteSample(rep, x: x, y: bitmapY)
        if colorDistance(sample, canvas) > 0.06 { samples.append(sample) }
      }
    }
    guard !samples.isEmpty else { return nil }
    samples.sort { $0.r + $0.g + $0.b < $1.r + $1.g + $1.b }
    let mid = samples[samples.count / 2]
    return Ink(r: mid.r, g: mid.g, b: mid.b, a: mid.a, count: samples.count)
  }

  /// Pixel-index source-over. setColor left the last attachment solid black, so this writes bitmap bytes.
  /// A uniform red probe checks the byte layout against native source-over before any product pixel is blended.
  private func compositeSourceOver(_ source: NSBitmapImageRep, canvas: Ink, label: String) throws -> NSBitmapImageRep {
    try calibrateSourceOverBytes(label: label)
    guard let out = makeInkBitmap(pixelsWide: source.pixelsWide, pixelsHigh: source.pixelsHigh),
          let src = source.bitmapData,
          let dst = out.bitmapData else {
      XCTFail("\(label) composite bitmap unavailable")
      throw CocoaError(.fileReadCorruptFile)
    }
    out.size = source.size
    for y in 0..<source.pixelsHigh {
      for x in 0..<source.pixelsWide {
        let sample = rawByteSample(src, rep: source, x: x, y: y)
        let blended = blendSourceOver(
          r: sample.r, g: sample.g, b: sample.b, a: sample.a,
          canvas: canvas, premultiplied: inkBytesPremultiplied
        )
        writeByte(dst, rep: out, x: x, y: y, ink: blended)
      }
    }
    return out
  }

  private func calibrateSourceOverBytes(label: String) throws {
    guard let src = makeInkBitmap(pixelsWide: 8, pixelsHigh: 8),
          let ctx = NSGraphicsContext(bitmapImageRep: src),
          let srcBytes = src.bitmapData else {
      XCTFail("\(label) source-over probe bitmap unavailable")
      throw CocoaError(.fileReadCorruptFile)
    }
    src.size = NSSize(width: 8, height: 8)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: 8, height: 8).fill()
    NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5).setFill()
    NSRect(x: 0, y: 0, width: 8, height: 8).fill()
    NSGraphicsContext.restoreGraphicsState()
    guard let read = src.colorAt(x: 4, y: 4)?.usingColorSpace(.deviceRGB) else {
      XCTFail("\(label) source-over probe unreadable")
      throw CocoaError(.fileReadCorruptFile)
    }
    var cr: CGFloat = 0, cg: CGFloat = 0, cb: CGFloat = 0, ca: CGFloat = 0
    read.getRed(&cr, green: &cg, blue: &cb, alpha: &ca)
    let i = 4 * src.bytesPerRow + 4 * 4
    let raw = [srcBytes[i], srcBytes[i + 1], srcBytes[i + 2], srcBytes[i + 3]]
    func near(_ value: UInt8, _ target: Int) -> Bool { abs(Int(value) - target) < 24 }
    let straight = near(raw[0], 255) && near(raw[3], 128)
    let premul = near(raw[0], 128) && near(raw[3], 128)
    let bgraStraight = near(raw[2], 255) && near(raw[3], 128)
    let bgraPremul = near(raw[2], 128) && near(raw[3], 128)
    if straight || premul {
      inkBytesBGRA = false
      inkBytesPremultiplied = premul && !straight
    } else if bgraStraight || bgraPremul {
      inkBytesBGRA = true
      inkBytesPremultiplied = bgraPremul && !bgraStraight
    } else {
      XCTFail("\(label) unrecognized bitmap bytes \(raw) colorAt=\(cr),\(cg),\(cb),\(ca)")
      throw CocoaError(.fileReadCorruptFile)
    }
    inkByteRowMatchesColorAtY = try byteRowMatchesColorAtY(label: label)
    let probeCanvas = Ink(r: 0.25, g: 0.25, b: 0.25, a: 1, count: 0)
    let decoded = rawByteSample(srcBytes, rep: src, x: 4, y: 4)
    let blended = blendSourceOver(
      r: decoded.r, g: decoded.g, b: decoded.b, a: decoded.a,
      canvas: probeCanvas, premultiplied: inkBytesPremultiplied
    )
    guard let check = makeInkBitmap(pixelsWide: 8, pixelsHigh: 8), let dst = check.bitmapData else {
      XCTFail("\(label) source-over check bitmap unavailable")
      throw CocoaError(.fileReadCorruptFile)
    }
    check.size = src.size
    for y in 0..<8 {
      for x in 0..<8 { writeByte(dst, rep: check, x: x, y: y, ink: blended) }
    }
    guard let written = check.colorAt(x: 4, y: 4)?.usingColorSpace(.deviceRGB) else {
      XCTFail("\(label) byte composite unreadable")
      throw CocoaError(.fileReadCorruptFile)
    }
    var wr: CGFloat = 0, wg: CGFloat = 0, wb: CGFloat = 0, wa: CGFloat = 0
    written.getRed(&wr, green: &wg, blue: &wb, alpha: &wa)
    let native = try nativeSourceOverPixel(source: src, canvas: probeCanvas, label: label)
    let err = max(abs(wr - native.r), abs(wg - native.g), abs(wb - native.b))
    fputs(
      String(format: "RICH-SOURCE-OVER %@ bytes=%d,%d,%d,%d premul=%d bgra=%d rowMatch=%d colorAt=%.3f,%.3f,%.3f,%.3f byteErr=%.3f native=%.3f,%.3f,%.3f\n",
             label, raw[0], raw[1], raw[2], raw[3], inkBytesPremultiplied ? 1 : 0, inkBytesBGRA ? 1 : 0,
             inkByteRowMatchesColorAtY ? 1 : 0, cr, cg, cb, ca, err, native.r, native.g, native.b),
      stderr
    )
    fflush(stderr)
    guard err <= 0.08 else {
      XCTFail("\(label) byte source-over err \(err) != native; not using a double-multiplied formula")
      throw CocoaError(.fileReadCorruptFile)
    }
  }

  private func byteRowMatchesColorAtY(label: String) throws -> Bool {
    guard let src = makeInkBitmap(pixelsWide: 8, pixelsHigh: 8),
          let ctx = NSGraphicsContext(bitmapImageRep: src) else {
      XCTFail("\(label) axis bitmap unavailable")
      throw CocoaError(.fileReadCorruptFile)
    }
    src.size = NSSize(width: 8, height: 8)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    NSColor.blue.setFill()
    NSRect(x: 0, y: 0, width: 8, height: 8).fill()
    NSColor.red.setFill()
    NSRect(x: 0, y: 0, width: 8, height: 2).fill()
    NSGraphicsContext.restoreGraphicsState()
    let lowRed = (src.colorAt(x: 4, y: 0)?.usingColorSpace(.deviceRGB)?.redComponent ?? 0) > 0.5
    let highRed = (src.colorAt(x: 4, y: 7)?.usingColorSpace(.deviceRGB)?.redComponent ?? 0) > 0.5
    guard lowRed != highRed, let bytes = src.bitmapData else {
      XCTFail("\(label) axis probe did not separate rows")
      throw CocoaError(.fileReadCorruptFile)
    }
    let row0Red = bytes[inkBytesBGRA ? 2 : 0] > 128
    let row7 = 7 * src.bytesPerRow
    let row7Red = bytes[row7 + (inkBytesBGRA ? 2 : 0)] > 128
    if lowRed == row0Red { return true }
    if lowRed == row7Red { return false }
    XCTFail("\(label) colorAt row does not match bitmap bytes")
    throw CocoaError(.fileReadCorruptFile)
  }

  private func rawByteSample(_ bytes: UnsafeMutablePointer<UInt8>, rep: NSBitmapImageRep, x: Int, y colorAtY: Int) -> Ink {
    let row = inkByteRowMatchesColorAtY ? colorAtY : (rep.pixelsHigh - 1 - colorAtY)
    let i = row * rep.bytesPerRow + x * 4
    let r = CGFloat(bytes[i + (inkBytesBGRA ? 2 : 0)]) / 255
    let g = CGFloat(bytes[i + 1]) / 255
    let b = CGFloat(bytes[i + (inkBytesBGRA ? 0 : 2)]) / 255
    let a = CGFloat(bytes[i + 3]) / 255
    return Ink(r: r, g: g, b: b, a: a, count: 1)
  }

  private func byteSample(_ rep: NSBitmapImageRep, x: Int, y colorAtY: Int) -> Ink {
    guard let bytes = rep.bitmapData, x >= 0, x < rep.pixelsWide, colorAtY >= 0, colorAtY < rep.pixelsHigh else {
      return Ink(r: 0, g: 0, b: 0, a: 0, count: 0)
    }
    let sample = rawByteSample(bytes, rep: rep, x: x, y: colorAtY)
    guard inkBytesPremultiplied, sample.a > 0.001, sample.a < 0.999 else { return sample }
    return Ink(
      r: min(1, sample.r / sample.a),
      g: min(1, sample.g / sample.a),
      b: min(1, sample.b / sample.a),
      a: sample.a,
      count: 1
    )
  }

  private func writeByte(_ bytes: UnsafeMutablePointer<UInt8>, rep: NSBitmapImageRep, x: Int, y colorAtY: Int, ink: Ink) {
    let row = inkByteRowMatchesColorAtY ? colorAtY : (rep.pixelsHigh - 1 - colorAtY)
    let i = row * rep.bytesPerRow + x * 4
    let r = UInt8(min(255, max(0, Int((ink.r * 255).rounded()))))
    let g = UInt8(min(255, max(0, Int((ink.g * 255).rounded()))))
    let b = UInt8(min(255, max(0, Int((ink.b * 255).rounded()))))
    bytes[i + (inkBytesBGRA ? 2 : 0)] = r
    bytes[i + 1] = g
    bytes[i + (inkBytesBGRA ? 0 : 2)] = b
    bytes[i + 3] = 255
  }

  private func nativeSourceOverPixel(source: NSBitmapImageRep, canvas: Ink, label: String) throws -> Ink {
    guard let out = makeInkBitmap(pixelsWide: source.pixelsWide, pixelsHigh: source.pixelsHigh),
          let ctx = NSGraphicsContext(bitmapImageRep: out) else {
      XCTFail("\(label) native source-over bitmap unavailable")
      throw CocoaError(.fileReadCorruptFile)
    }
    out.size = source.size
    let image = NSImage(size: source.size)
    image.addRepresentation(source)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .none
    NSColor(srgbRed: canvas.r, green: canvas.g, blue: canvas.b, alpha: 1).setFill()
    NSRect(origin: .zero, size: source.size).fill()
    image.draw(
      in: NSRect(origin: .zero, size: source.size),
      from: NSRect(origin: .zero, size: source.size),
      operation: .sourceOver,
      fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()
    guard let color = out.colorAt(x: source.pixelsWide / 2, y: source.pixelsHigh / 2)?.usingColorSpace(.sRGB)
      ?? out.colorAt(x: source.pixelsWide / 2, y: source.pixelsHigh / 2)?.usingColorSpace(.deviceRGB) else {
      XCTFail("\(label) native source-over unreadable")
      throw CocoaError(.fileReadCorruptFile)
    }
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    color.getRed(&r, green: &g, blue: &b, alpha: &a)
    return Ink(r: r, g: g, b: b, a: a, count: 1)
  }

  private func blendSourceOver(
    r: CGFloat,
    g: CGFloat,
    b: CGFloat,
    a: CGFloat,
    canvas: Ink,
    premultiplied: Bool
  ) -> Ink {
    let srcR = premultiplied ? r : r * a
    let srcG = premultiplied ? g : g * a
    let srcB = premultiplied ? b : b * a
    let keep = 1 - a
    return Ink(
      r: min(1, max(0, srcR + canvas.r * keep)),
      g: min(1, max(0, srcG + canvas.g * keep)),
      b: min(1, max(0, srcB + canvas.b * keep)),
      a: 1,
      count: 1
    )
  }

  private func makeInkBitmap(pixelsWide: Int, pixelsHigh: Int) -> NSBitmapImageRep? {
    NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: pixelsWide,
      pixelsHigh: pixelsHigh,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    )
  }

  /// Pixel evidence is an xcresult attachment only. Do not write a PNG under
  /// the system temporary directory or the home directory. Export with
  /// `xcrun xcresulttool export attachments`.
  private func writeComposite(_ rep: NSBitmapImageRep, label: String) -> String {
    let leaked = FileManager.default.temporaryDirectory.appendingPathComponent("maccy-rich-\(label).png")
    let existed = FileManager.default.fileExists(atPath: leaked.path)
    guard let png = rep.representation(using: .png, properties: [:]) else {
      XCTFail("\(label) png attachment unavailable")
      return "导附件:unavailable:\(label)"
    }
    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    attachment.name = label
    attachment.lifetime = .keepAlways
    add(attachment)
    if !existed {
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: leaked.path),
        "\(label) wrote a system temporary PNG"
      )
    }
    return "导附件:\(label)"
  }

  private func glyphRect(_ textView: NSTextView, word: String) -> NSRect {
    let range = (textView.string as NSString).range(of: word)
    guard range.location != NSNotFound, let layout = textView.layoutManager, let container = textView.textContainer else {
      return .zero
    }
    let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
    var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
    rect.origin.x += textView.textContainerOrigin.x
    rect.origin.y += textView.textContainerOrigin.y
    return rect.insetBy(dx: 1, dy: 1)
  }

  private func font(_ text: NSAttributedString, word: String) -> NSFont? {
    let range = (text.string as NSString).range(of: word)
    guard range.location != NSNotFound else { return nil }
    return text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
  }

  private func traits(_ text: NSAttributedString, word: String) -> NSFontTraitMask {
    guard let font = font(text, word: word) else { return [] }
    return NSFontManager.shared.traits(of: font)
  }

  private func foregroundComponents(_ text: NSAttributedString, word: String) -> Ink? {
    let range = (text.string as NSString).range(of: word)
    guard range.location != NSNotFound,
          let color = text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor,
          let srgb = color.usingColorSpace(.sRGB) else { return nil }
    return Ink(r: srgb.redComponent, g: srgb.greenComponent, b: srgb.blueComponent, a: srgb.alphaComponent, count: 1)
  }

  private func resolvedCanvas(_ name: NSAppearance.Name) -> Ink {
    let appearance = NSAppearance(named: name) ?? NSAppearance(named: .aqua)!
    var ink = Ink(r: 1, g: 1, b: 1, a: 1, count: 0)
    appearance.performAsCurrentDrawingAppearance {
      let color = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? NSColor.white
      ink = Ink(r: color.redComponent, g: color.greenComponent, b: color.blueComponent, a: 1, count: 0)
    }
    return ink
  }

  private func contrast(_ ink: Ink, _ canvas: Ink) -> Double {
    func linear(_ channel: CGFloat) -> Double {
      let value = Double(channel)
      return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    func luminance(_ sample: Ink) -> Double {
      0.2126 * linear(sample.r) + 0.7152 * linear(sample.g) + 0.0722 * linear(sample.b)
    }
    let hi = max(luminance(ink), luminance(canvas))
    let lo = min(luminance(ink), luminance(canvas))
    return (hi + 0.05) / (lo + 0.05)
  }

  private func colorDistance(_ lhs: Ink, _ rhs: Ink) -> CGFloat {
    let dr = lhs.r - rhs.r
    let dg = lhs.g - rhs.g
    let db = lhs.b - rhs.b
    return (dr * dr + dg * dg + db * db).squareRoot()
  }
}

private final class SilentRichPanel: NSPanel {
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

private final class FlippedAxisProbe: NSView {
  override var isFlipped: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.red.setFill()
    NSRect(x: 0, y: 0, width: bounds.width, height: 6).fill()
    NSColor.blue.setFill()
    NSRect(x: 0, y: max(0, bounds.height - 6), width: bounds.width, height: 6).fill()
  }
}

/// Requirement 7 contract. Lives in this already-registered file because the
/// project has no PBXFileSystemSynchronized group; a new test file would not compile.
/// Intercepts NSAlert presentation so the real `requestDelete` finish closure runs
/// without a modal, sheet, AX, or pasteboard access.
@MainActor
final class DeleteItemConfirmationContractTests: XCTestCase {
  private var created: [HistoryItemDecorator] = []
  private var armed = false
  private var savedSize = 0
  private var savedClear = false
  private var savedQuit = false
  private var savedPresented = false
  private var savedDelete: Any?
  private var standardBefore: [String: String] = [:]

  override func tearDown() {
    defer {
      if armed {
        DeleteAlertProbe.uninstall()
        armed = false
      }
      super.tearDown()
    }
    guard armed else { return }
    for item in created where !item.isRemoved {
      History.shared.delete(item)
    }
    created.removeAll()
    Defaults[.size] = savedSize
    Defaults[.suppressClearAlert] = savedClear
    Defaults[.suppressQuitAlert] = savedQuit
    restoreDelete(savedDelete)
    AppState.shared.deleteConfirmationPresented = savedPresented
    DeleteAlertProbe.releaseAlert()
    assertStandardUntouched()
  }

  func testMissingKeyPromptsAndCancelKeepsItemWhileSuppressWritesOnlyDeleteKey() throws {
    guard arm() else { return }
    let deleteKey = DeleteItemConfirmation.suppressKeyName
    LabDefaults.suite.removeObject(forKey: deleteKey)
    XCTAssertNil(LabDefaults.suite.object(forKey: deleteKey))
    XCTAssertFalse(DeleteItemConfirmationStore.isSuppressed)
    XCTAssertTrue(DeleteItemConfirmation.shouldPrompt(suppressed: DeleteItemConfirmationStore.isSuppressed))
    XCTAssertNotEqual(deleteKey, "suppressClearAlert")
    XCTAssertNotEqual(deleteKey, "suppressQuitAlert")
    try assertDeleteEntrypointsCallRequestDelete()

    let kept = addItem("delete-contract-cancel-\(UUID().uuidString)")
    _ = prompt(kept, response: .alertSecondButtonReturn, suppress: false)
    XCTAssertEqual(DeleteAlertProbe.runModalCount + DeleteAlertProbe.sheetCount, 1)
    XCTAssertFalse(kept.isRemoved)
    XCTAssertTrue(History.shared.all.contains(kept))
    XCTAssertNil(LabDefaults.suite.object(forKey: deleteKey))
    XCTAssertFalse(DeleteItemConfirmationStore.isSuppressed)
    XCTAssertFalse(AppState.shared.deleteConfirmationPresented)
    notePath("cancel-unsuppressed")

    _ = prompt(kept, response: .alertSecondButtonReturn, suppress: true)
    XCTAssertEqual(DeleteAlertProbe.runModalCount + DeleteAlertProbe.sheetCount, 1)
    XCTAssertFalse(kept.isRemoved, "cancel must not delete even when suppression is checked")
    XCTAssertEqual(LabDefaults.suite.object(forKey: deleteKey) as? Bool, true)
    XCTAssertTrue(DeleteItemConfirmationStore.isSuppressed)
    XCTAssertFalse(Defaults[.suppressClearAlert])
    XCTAssertTrue(Defaults[.suppressQuitAlert])
    XCTAssertFalse(AppState.shared.deleteConfirmationPresented)
    notePath("cancel-suppressed")
    assertStandardUntouched()
  }

  func testConfirmDeletesAndSuppressedRepeatDeletesWithoutAlert() throws {
    guard arm() else { return }
    let deleteKey = DeleteItemConfirmation.suppressKeyName
    LabDefaults.suite.removeObject(forKey: deleteKey)
    XCTAssertTrue(DeleteItemConfirmation.shouldPrompt(suppressed: DeleteItemConfirmationStore.isSuppressed))

    let confirmed = addItem("delete-contract-confirm-\(UUID().uuidString)")
    _ = prompt(confirmed, response: .alertFirstButtonReturn, suppress: false)
    XCTAssertEqual(DeleteAlertProbe.runModalCount + DeleteAlertProbe.sheetCount, 1)
    XCTAssertTrue(confirmed.isRemoved)
    XCTAssertFalse(History.shared.all.contains(confirmed))
    XCTAssertNil(LabDefaults.suite.object(forKey: deleteKey), "confirm without suppression must not write the key")
    XCTAssertFalse(Defaults[.suppressClearAlert])
    XCTAssertTrue(Defaults[.suppressQuitAlert])
    notePath("confirm-unsuppressed")

    let suppressed = addItem("delete-contract-suppress-confirm-\(UUID().uuidString)")
    _ = prompt(suppressed, response: .alertFirstButtonReturn, suppress: true)
    XCTAssertEqual(DeleteAlertProbe.runModalCount + DeleteAlertProbe.sheetCount, 1)
    XCTAssertTrue(suppressed.isRemoved)
    XCTAssertEqual(LabDefaults.suite.object(forKey: deleteKey) as? Bool, true)
    XCTAssertTrue(DeleteItemConfirmationStore.isSuppressed)
    XCTAssertFalse(Defaults[.suppressClearAlert])
    XCTAssertTrue(Defaults[.suppressQuitAlert])
    notePath("confirm-suppressed")

    let direct = addItem("delete-contract-direct-\(UUID().uuidString)")
    DeleteAlertProbe.reset()
    AppState.shared.requestDelete([direct])
    XCTAssertEqual(DeleteAlertProbe.runModalCount, 0)
    XCTAssertEqual(DeleteAlertProbe.sheetCount, 0)
    XCTAssertNil(DeleteAlertProbe.captured)
    XCTAssertTrue(direct.isRemoved, "a set suppress key must delete without another alert")
    XCTAssertFalse(History.shared.all.contains(direct))
    XCTAssertFalse(Defaults[.suppressClearAlert])
    XCTAssertTrue(Defaults[.suppressQuitAlert])
    XCTAssertEqual(LabDefaults.suite.object(forKey: deleteKey) as? Bool, true)
    XCTAssertFalse(AppState.shared.deleteConfirmationPresented)
    fputs("DELETE-CONTRACT path=none calls=0/0 direct=1\n", stderr)
    fflush(stderr)
    assertStandardUntouched()
  }

  private func arm() -> Bool {
    guard LabRuntime.isIsolated, LabRuntime.isUnitTestProcess else {
      XCTFail("refusing delete contract: process is not isolated")
      return false
    }
    guard Storage.shared.isInMemory else {
      XCTFail("refusing delete contract: storage is not in memory")
      return false
    }
    guard LabDefaults.suite !== UserDefaults.standard else {
      XCTFail("refusing delete contract: suite is UserDefaults.standard")
      return false
    }
    let probe = "maccy.delete.contract.probe"
    let named = UserDefaults(suiteName: LabRuntime.isolatedDefaultsSuite)
    named?.set("probe", forKey: probe)
    let seenBySuite = LabDefaults.suite.string(forKey: probe) == "probe"
    let leaked = UserDefaults.standard.object(forKey: probe) != nil
    named?.removeObject(forKey: probe)
    LabDefaults.suite.removeObject(forKey: probe)
    guard seenBySuite, !leaked else {
      XCTFail("refusing delete contract: isolated suite probe missed or leaked to standard")
      return false
    }
    savedSize = Defaults[.size]
    savedClear = Defaults[.suppressClearAlert]
    savedQuit = Defaults[.suppressQuitAlert]
    savedPresented = AppState.shared.deleteConfirmationPresented
    savedDelete = LabDefaults.suite.object(forKey: DeleteItemConfirmation.suppressKeyName)
    snapStandard()
    Defaults[.size] = max(savedSize, History.shared.all.count + 8)
    Defaults[.suppressClearAlert] = false
    Defaults[.suppressQuitAlert] = true
    armed = true
    guard DeleteAlertProbe.install() else {
      XCTFail("refusing delete contract: NSAlert modal was not intercepted")
      return false
    }
    return true
  }

  private func addItem(_ title: String) -> HistoryItemDecorator {
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: Data(title.utf8)
      )
    ]
    item.numberOfCopies = 1
    item.title = title
    let decorator = History.shared.add(item)
    created.append(decorator)
    return decorator
  }

  @discardableResult
  private func prompt(
    _ item: HistoryItemDecorator,
    response: NSApplication.ModalResponse,
    suppress: Bool
  ) -> NSAlert? {
    DeleteAlertProbe.reset()
    DeleteAlertProbe.response = response
    DeleteAlertProbe.prepare = { alert in
      self.assertAlertContract(alert)
      alert.suppressionButton?.state = suppress ? .on : .off
    }
    AppState.shared.requestDelete([item])
    return DeleteAlertProbe.captured
  }

  private func assertAlertContract(_ alert: NSAlert, file: StaticString = #filePath, line: UInt = #line) {
    let confirm = NSLocalizedString("delete_item_alert_confirm", value: "Delete", comment: "")
    let cancel = NSLocalizedString("clear_alert_cancel", value: "Cancel", comment: "")
    XCTAssertEqual(alert.buttons.count, 2, file: file, line: line)
    XCTAssertEqual(alert.buttons.first?.title, confirm, file: file, line: line)
    XCTAssertEqual(alert.buttons.dropFirst().first?.title, cancel, file: file, line: line)
    XCTAssertEqual(
      alert.buttons.first?.toolTip,
      NSLocalizedString("delete_item_alert_confirm_help", value: "Delete the selected items.", comment: ""),
      file: file, line: line
    )
    XCTAssertEqual(
      alert.buttons.dropFirst().first?.toolTip,
      NSLocalizedString("delete_item_alert_cancel_help", value: "Keep the selected items.", comment: ""),
      file: file, line: line
    )
    XCTAssertTrue(alert.showsSuppressionButton, file: file, line: line)
    XCTAssertNotNil(alert.suppressionButton, file: file, line: line)
    XCTAssertEqual(
      alert.suppressionButton?.toolTip,
      NSLocalizedString(
        "delete_item_alert_suppress_help",
        value: "Don't ask again before deleting an item.",
        comment: ""
      ),
      file: file, line: line
    )
    XCTAssertEqual(
      alert.messageText,
      NSLocalizedString("delete_item_alert_message", value: "Delete this item?", comment: ""),
      file: file, line: line
    )
  }

  private func assertDeleteEntrypointsCallRequestDelete() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let preview = try String(contentsOf: root.appending(path: "WitsCopy/Views/PreviewItemView.swift"), encoding: .utf8)
    let row = try String(contentsOf: root.appending(path: "WitsCopy/Views/HistoryItemView.swift"), encoding: .utf8)
    XCTAssertTrue(preview.contains("identifier: \"lab-preview-delete\""))
    XCTAssertTrue(preview.contains("appState.requestDelete([item])"))
    XCTAssertTrue(row.contains("lab-row-delete-"))
    XCTAssertTrue(row.contains("appState.requestDelete([item])"))
  }

  private func notePath(_ label: String) {
    let path = DeleteAlertProbe.sheetCount > 0 ? "sheet" : "runModal"
    fputs(
      "DELETE-CONTRACT \(label) path=\(path) calls=\(DeleteAlertProbe.runModalCount)/\(DeleteAlertProbe.sheetCount)\n",
      stderr
    )
    fflush(stderr)
  }

  private func snapStandard() {
    standardBefore = Dictionary(uniqueKeysWithValues: standardKeys.map {
      ($0, token(UserDefaults.standard.object(forKey: $0)))
    })
  }

  private func assertStandardUntouched(file: StaticString = #filePath, line: UInt = #line) {
    for key in standardKeys {
      XCTAssertEqual(
        token(UserDefaults.standard.object(forKey: key)),
        standardBefore[key],
        "standard defaults changed for \(key)",
        file: file,
        line: line
      )
    }
  }

  private func restoreDelete(_ value: Any?) {
    let key = DeleteItemConfirmation.suppressKeyName
    if let value {
      LabDefaults.suite.set(value, forKey: key)
    } else {
      LabDefaults.suite.removeObject(forKey: key)
    }
  }

  private func token(_ value: Any?) -> String {
    guard let value else { return "nil" }
    return "\(type(of: value)):\(value)"
  }

  private var standardKeys: [String] {
    ["suppressDeleteItemAlert", "suppressClearAlert", "suppressQuitAlert", "historySize"]
  }
}

/// Hits the production clear/quit alert assembly. Not a model that assigns toolTip itself.
/// Factory coverage builds Footer() items and calls presentFooterConfirmation plus requestDelete.
/// It does not call quit() or runFooterItem: the unsuppressed branch opens the panel.
@MainActor
final class FooterConfirmationContractTests: XCTestCase {
  private var armed = false
  private var factoryActionsSpied = false
  private var savedClearObject: Any?
  private var savedQuitObject: Any?
  private var savedDelete: Any?
  private var savedPresented = false
  private var savedQuitAuthorized = false
  private var savedSize = 0
  private var created: [HistoryItemDecorator] = []
  private var standardBefore: [String: String] = [:]
  private var standardObjects: [String: Any] = [:]
  private var standardMissing: Set<String> = []

  override func tearDown() {
    if armed {
      if Storage.shared.isInMemory {
        for item in created where !item.isRemoved {
          History.shared.delete(item)
        }
      }
      created.removeAll()
      Defaults[.size] = savedSize
      restoreObservedPreferences()
      AppState.shared.deleteConfirmationPresented = savedPresented
      AppState.shared.quitAuthorized = savedQuitAuthorized
      factoryActionsSpied = false
      DeleteAlertProbe.reset()
      sweepAlerts()
      DeleteAlertProbe.uninstall()
      armed = false
    }
    super.tearDown()
  }

  func testClearAndQuitAlertsInstallNativeToolTipsAndKeepSuppressKeysIndependent() throws {
    guard arm() else { return }
    var clearBound = false
    var quitBound = false
    var clearActions = 0
    var quitActions = 0
    let clear = footerItem(
      message: "clear_all_alert_message",
      comment: "clear_all_alert_comment",
      confirm: "clear_alert_confirm",
      cancel: "clear_alert_cancel",
      confirmHelp: "clear_alert_confirm_help",
      cancelHelp: "clear_alert_cancel_help",
      suppressHelp: "clear_alert_suppress_help",
      suppress: Binding(get: { clearBound }, set: { clearBound = $0 }),
      action: { clearActions += 1 }
    )
    let quit = footerItem(
      message: "quit_alert_message",
      comment: "quit_alert_comment",
      confirm: "quit",
      cancel: "clear_alert_cancel",
      confirmHelp: "quit_alert_confirm_help",
      cancelHelp: "quit_alert_cancel_help",
      suppressHelp: "quit_alert_suppress_help",
      suppress: Binding(get: { quitBound }, set: { quitBound = $0 }),
      action: { quitActions += 1 }
    )

    present(clear, response: .alertSecondButtonReturn, suppress: true)
    XCTAssertEqual(clearActions, 0, "cancel must not clear")
    XCTAssertTrue(clearBound)
    XCTAssertFalse(quitBound)
    XCTAssertFalse(Defaults[.suppressClearAlert])
    XCTAssertTrue(Defaults[.suppressQuitAlert])
    XCTAssertNotEqual(LabDefaults.suite.object(forKey: DeleteItemConfirmation.suppressKeyName) as? Bool, true)
    XCTAssertFalse(clear.showConfirmation)
    DeleteAlertProbe.releaseAlert()

    present(quit, response: .alertFirstButtonReturn, suppress: false)
    XCTAssertEqual(quitActions, 1)
    XCTAssertFalse(quitBound)
    XCTAssertEqual(clearActions, 0)
    XCTAssertFalse(Defaults[.suppressClearAlert])
    XCTAssertTrue(Defaults[.suppressQuitAlert])
    XCTAssertFalse(quit.showConfirmation)

    present(quit, response: .alertFirstButtonReturn, suppress: false)
    XCTAssertEqual(quitActions, 2, "a second confirm is a new prompt, not a replay of the first")
    XCTAssertEqual(DeleteAlertProbe.runModalCount + DeleteAlertProbe.sheetCount, 1)

    clearBound = true
    DeleteAlertProbe.reset()
    AppState.shared.presentFooterConfirmation(clear)
    XCTAssertEqual(DeleteAlertProbe.runModalCount + DeleteAlertProbe.sheetCount, 0)
    XCTAssertEqual(clearActions, 1, "suppressed clear runs once and does not alert")
    XCTAssertEqual(quitActions, 2)

    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let keys = try String(contentsOf: root.appending(path: "WitsCopy/Views/KeyHandlingView.swift"), encoding: .utf8)
    let app = try String(contentsOf: root.appending(path: "WitsCopy/Observables/AppState.swift"), encoding: .utf8)
    XCTAssertTrue(keys.contains("presentFooterConfirmation"))
    XCTAssertTrue(app.contains("func runFooterItem"))
    XCTAssertTrue(app.contains("presentFooterConfirmation(item)"))
    XCTAssertFalse(app.contains("item.showConfirmation = true\n      if !panelPresented"))
  }

  /// Same-process suite reopen only. This does not claim a GUI restart persisted the keys.
  func testFactoryBindingsCrossQuitClearAndDeleteWithoutSkippingOtherConfirmations() {
    guard arm() else { return }
    let footer = Footer()
    guard let clear = footer.items.first(where: { $0.title == "clear_all" }),
          let quit = footer.items.first(where: { $0.title == "quit" }),
          clear !== quit,
          clear.confirmation?.messageKey == "clear_all_alert_message",
          quit.confirmation?.messageKey == "quit_alert_message",
          let clearBinding = clear.suppressConfirmation,
          let quitBinding = quit.suppressConfirmation,
          let liveClear = AppState.shared.footer.items.first(where: { $0.title == "clear_all" }),
          let liveQuit = AppState.shared.footer.items.first(where: { $0.title == "quit" }),
          liveClear !== clear,
          liveQuit !== quit
    else {
      XCTFail("Footer() did not build distinct clear_all/quit items with live suppress bindings")
      return
    }
    let liveClearShown = liveClear.showConfirmation
    let liveQuitShown = liveQuit.showConfirmation
    let originalClear = clear.action
    let originalQuit = quit.action
    defer {
      clear.action = originalClear
      quit.action = originalQuit
      factoryActionsSpied = false
    }
    var clearRuns = 0
    var quitRuns = 0
    clear.action = { clearRuns += 1 }
    quit.action = { quitRuns += 1 }
    factoryActionsSpied = true
    let quitAuthorized = AppState.shared.quitAuthorized

    removeThreeKeys()
    assertThreeKeys(clear: nil, quit: nil, delete: nil, clearItem: clear, quitItem: quit, label: "baseline")

    clearBinding.wrappedValue = true
    XCTAssertTrue(Defaults[.suppressClearAlert])
    XCTAssertEqual(liveClear.suppressConfirmation?.wrappedValue, true)
    XCTAssertEqual(liveQuit.suppressConfirmation?.wrappedValue, false)
    assertThreeKeys(clear: true, quit: nil, delete: nil, clearItem: clear, quitItem: quit, label: "factory-clear-write")

    Defaults[.suppressQuitAlert] = true
    XCTAssertEqual(quitBinding.wrappedValue, true)
    XCTAssertEqual(clearBinding.wrappedValue, true)
    XCTAssertEqual(liveQuit.suppressConfirmation?.wrappedValue, true)
    assertThreeKeys(clear: true, quit: true, delete: nil, clearItem: clear, quitItem: quit, label: "defaults-quit-write")

    removeThreeKeys()
    assertThreeKeys(clear: nil, quit: nil, delete: nil, clearItem: clear, quitItem: quit, label: "reset")

    guard presentFactory(clear, response: .alertSecondButtonReturn, suppress: true, label: "clear-cancel-suppress") else { return }
    XCTAssertEqual(clearRuns, 0)
    XCTAssertEqual(quitRuns, 0)
    assertThreeKeys(clear: true, quit: nil, delete: nil, clearItem: clear, quitItem: quit, label: "clear-cancel-wrote-only-clear")

    guard expectSuppressedFooterSkipsAlert(clear, label: "clear-true-skips-own-alert") else { return }
    XCTAssertEqual(clearRuns, 1)
    XCTAssertEqual(quitRuns, 0)
    guard presentFactory(quit, response: .alertSecondButtonReturn, suppress: false, label: "quit-still-prompts-while-clear-true") else { return }
    XCTAssertEqual(quitRuns, 0)
    XCTAssertEqual(clearRuns, 1)
    assertThreeKeys(clear: true, quit: nil, delete: nil, clearItem: clear, quitItem: quit, label: "quit-cancel-wrote-nothing")
    guard let keptWhileClear = addSynthetic("footer-factory-clear-cross") else { return }
    guard promptDelete(keptWhileClear, response: .alertSecondButtonReturn, suppress: false, label: "delete-still-prompts-while-clear-true") else { return }
    XCTAssertFalse(keptWhileClear.isRemoved)
    XCTAssertTrue(History.shared.all.contains(keptWhileClear))
    assertThreeKeys(clear: true, quit: nil, delete: nil, clearItem: clear, quitItem: quit, label: "delete-cancel-wrote-nothing")

    clearBinding.wrappedValue = false
    absent(Defaults.Keys.suppressQuitAlert)
    XCTAssertEqual(quitBinding.wrappedValue, false)
    assertThreeKeys(clear: false, quit: nil, delete: nil, clearItem: clear, quitItem: quit, label: "before-quit-confirm")
    guard presentFactory(quit, response: .alertFirstButtonReturn, suppress: true, label: "quit-confirm-suppress") else { return }
    XCTAssertEqual(quitRuns, 1)
    XCTAssertEqual(clearRuns, 1)
    assertThreeKeys(clear: false, quit: true, delete: nil, clearItem: clear, quitItem: quit, label: "quit-confirm-wrote-only-quit")
    guard expectSuppressedFooterSkipsAlert(quit, label: "quit-true-skips-own-alert") else { return }
    XCTAssertEqual(quitRuns, 2)
    XCTAssertEqual(clearRuns, 1)
    guard presentFactory(clear, response: .alertSecondButtonReturn, suppress: false, label: "clear-still-prompts-while-quit-true") else { return }
    XCTAssertEqual(clearRuns, 1)
    assertThreeKeys(clear: false, quit: true, delete: nil, clearItem: clear, quitItem: quit, label: "clear-cancel-while-quit-true")
    guard let keptWhileQuit = addSynthetic("footer-factory-quit-cross") else { return }
    guard promptDelete(keptWhileQuit, response: .alertSecondButtonReturn, suppress: false, label: "delete-still-prompts-while-quit-true") else { return }
    XCTAssertFalse(keptWhileQuit.isRemoved)
    assertThreeKeys(clear: false, quit: true, delete: nil, clearItem: clear, quitItem: quit, label: "delete-unchanged-while-quit-true")

    guard let confirmed = addSynthetic("footer-factory-delete-confirm") else { return }
    let countBeforeConfirm = History.shared.all.count
    guard promptDelete(confirmed, response: .alertFirstButtonReturn, suppress: false, label: "delete-confirm-no-suppress") else { return }
    XCTAssertTrue(confirmed.isRemoved)
    XCTAssertFalse(History.shared.all.contains(confirmed))
    XCTAssertEqual(History.shared.all.count, countBeforeConfirm - 1)
    assertThreeKeys(clear: false, quit: true, delete: nil, clearItem: clear, quitItem: quit, label: "delete-confirm-wrote-nothing")

    guard let suppressedCancel = addSynthetic("footer-factory-delete-cancel") else { return }
    guard promptDelete(suppressedCancel, response: .alertSecondButtonReturn, suppress: true, label: "delete-cancel-suppress") else { return }
    XCTAssertFalse(suppressedCancel.isRemoved)
    assertThreeKeys(clear: false, quit: true, delete: true, clearItem: clear, quitItem: quit, label: "delete-cancel-wrote-only-delete")

    guard presentFactory(clear, response: .alertSecondButtonReturn, suppress: false, label: "clear-still-prompts-while-delete-true") else { return }
    XCTAssertEqual(clearRuns, 1)
    assertThreeKeys(clear: false, quit: true, delete: true, clearItem: clear, quitItem: quit, label: "clear-unchanged-while-delete-true")
    quitBinding.wrappedValue = false
    assertThreeKeys(clear: false, quit: false, delete: true, clearItem: clear, quitItem: quit, label: "quit-cleared-delete-remains")
    guard presentFactory(quit, response: .alertSecondButtonReturn, suppress: false, label: "quit-still-prompts-while-delete-true") else { return }
    XCTAssertEqual(quitRuns, 2)
    assertThreeKeys(clear: false, quit: false, delete: true, clearItem: clear, quitItem: quit, label: "quit-cancel-while-delete-true")

    guard let direct = addSynthetic("footer-factory-delete-direct") else { return }
    guard expectSuppressedDeleteSkipsAlert(direct, label: "delete-true-skips-own-alert") else { return }
    XCTAssertEqual(clearRuns, 1)
    XCTAssertEqual(quitRuns, 2)
    assertThreeKeys(clear: false, quit: false, delete: true, clearItem: clear, quitItem: quit, label: "delete-skip-wrote-nothing-else")

    absent(Defaults.Keys.suppressClearAlert)
    XCTAssertFalse(clearBinding.wrappedValue)
    guard presentFactory(clear, response: .alertFirstButtonReturn, suppress: false, label: "clear-confirm-no-suppress") else { return }
    XCTAssertEqual(clearRuns, 2)
    XCTAssertEqual(quitRuns, 2)
    assertThreeKeys(clear: nil, quit: false, delete: true, clearItem: clear, quitItem: quit, label: "clear-confirm-wrote-nothing")

    XCTAssertEqual(AppState.shared.quitAuthorized, quitAuthorized)
    XCTAssertEqual(liveClear.showConfirmation, liveClearShown)
    XCTAssertEqual(liveQuit.showConfirmation, liveQuitShown)
    XCTAssertNil(NSApp.alertWindow)
    assertStandardUntouched()
  }

  private func arm() -> Bool {
    guard LabRuntime.isIsolated, LabRuntime.isUnitTestProcess, Storage.shared.isInMemory else {
      XCTFail("refusing footer confirmation contract: process or storage is not isolated")
      return false
    }
    guard LabDefaults.suite !== UserDefaults.standard else {
      XCTFail("refusing footer confirmation contract: suite is UserDefaults.standard")
      return false
    }
    guard Defaults.Keys.suppressClearAlert.suite !== UserDefaults.standard,
          Defaults.Keys.suppressQuitAlert.suite !== UserDefaults.standard,
          Defaults.Keys.size.suite !== UserDefaults.standard else {
      XCTFail("refusing footer confirmation contract: suppress or historySize keys are bound to UserDefaults.standard")
      return false
    }
    let probe = "maccy.footer.factory.binding.probe"
    guard let named = UserDefaults(suiteName: LabRuntime.isolatedDefaultsSuite),
          named !== UserDefaults.standard else {
      XCTFail("refusing footer confirmation contract: isolated suite did not reopen")
      return false
    }
    named.set("probe", forKey: probe)
    let seenBySuite = LabDefaults.suite.string(forKey: probe) == "probe"
    let seenByClearKey = Defaults.Keys.suppressClearAlert.suite.string(forKey: probe) == "probe"
    let leaked = UserDefaults.standard.object(forKey: probe) != nil
    named.removeObject(forKey: probe)
    LabDefaults.suite.removeObject(forKey: probe)
    Defaults.Keys.suppressClearAlert.suite.removeObject(forKey: probe)
    guard seenBySuite, seenByClearKey, !leaked, named.object(forKey: probe) == nil else {
      XCTFail("refusing footer confirmation contract: isolated suite probe missed or leaked to standard")
      return false
    }
    let clearName = Defaults.Keys.suppressClearAlert.name
    let quitName = Defaults.Keys.suppressQuitAlert.name
    let clearOnKey = Defaults.Keys.suppressClearAlert.suite.object(forKey: clearName)
    let quitOnKey = Defaults.Keys.suppressQuitAlert.suite.object(forKey: quitName)
    let clearOnLab = LabDefaults.suite.object(forKey: clearName)
    let quitOnLab = LabDefaults.suite.object(forKey: quitName)
    guard samePreference(clearOnKey, clearOnLab), samePreference(quitOnKey, quitOnLab) else {
      XCTFail("refusing footer confirmation contract: production key suite and isolated suite disagree")
      return false
    }
    savedClearObject = clearOnLab
    savedQuitObject = quitOnLab
    savedDelete = LabDefaults.suite.object(forKey: DeleteItemConfirmation.suppressKeyName)
    savedPresented = AppState.shared.deleteConfirmationPresented
    savedQuitAuthorized = AppState.shared.quitAuthorized
    savedSize = Defaults[.size]
    snapStandard()
    armed = true
    Defaults[.suppressClearAlert] = false
    Defaults[.suppressQuitAlert] = true
    LabDefaults.suite.set(false, forKey: DeleteItemConfirmation.suppressKeyName)
    guard DeleteAlertProbe.install() else {
      XCTFail("refusing footer confirmation contract: NSAlert modal was not intercepted")
      return false
    }
    return true
  }

  private func gateReady(_ label: String) -> Bool {
    guard DeleteAlertProbe.install() else {
      XCTFail("\(label): NSAlert modal is not intercepted; refusing to run the action")
      return false
    }
    return true
  }

  private func sweepAlerts() {
    DeleteAlertProbe.releaseAlert()
    for window in NSApp.windows where window.className == "_NSAlertPanel" {
      window.orderOut(nil)
      window.close()
    }
  }

  @discardableResult
  private func presentFactory(
    _ item: FooterItem,
    response: NSApplication.ModalResponse,
    suppress: Bool,
    label: String
  ) -> Bool {
    guard factoryActionsSpied else {
      XCTFail("\(label): refusing footer confirmation before the factory action was replaced")
      return false
    }
    guard gateReady(label) else { return false }
    let historyCount = History.shared.all.count
    let authorized = AppState.shared.quitAuthorized
    guard present(item, response: response, suppress: suppress) else { return false }
    XCTAssertEqual(History.shared.all.count, historyCount, "\(label): confirmation cleared history")
    XCTAssertEqual(AppState.shared.quitAuthorized, authorized, "\(label): confirmation authorized quit")
    XCTAssertFalse(item.showConfirmation, label)
    XCTAssertNil(NSApp.alertWindow, label)
    return true
  }

  private func expectSuppressedFooterSkipsAlert(_ item: FooterItem, label: String) -> Bool {
    guard factoryActionsSpied else {
      XCTFail("\(label): refusing footer action before the factory action was replaced")
      return false
    }
    guard item.confirmation != nil else {
      XCTFail("\(label): factory item has no confirmation; refusing to run its action")
      return false
    }
    guard item.suppressConfirmation?.wrappedValue == true else {
      XCTFail("\(label): suppress is not true; refusing a call that would present")
      return false
    }
    guard gateReady(label) else { return false }
    let historyCount = History.shared.all.count
    let authorized = AppState.shared.quitAuthorized
    DeleteAlertProbe.reset()
    AppState.shared.presentFooterConfirmation(item)
    let calls = DeleteAlertProbe.runModalCount + DeleteAlertProbe.sheetCount
    XCTAssertEqual(calls, 0, label)
    XCTAssertNil(DeleteAlertProbe.captured, label)
    XCTAssertEqual(History.shared.all.count, historyCount, "\(label): skipped confirmation cleared history")
    XCTAssertEqual(AppState.shared.quitAuthorized, authorized, "\(label): skipped confirmation authorized quit")
    XCTAssertFalse(item.showConfirmation, label)
    sweepAlerts()
    XCTAssertNil(NSApp.alertWindow, label)
    return calls == 0
  }

  @discardableResult
  private func promptDelete(
    _ item: HistoryItemDecorator,
    response: NSApplication.ModalResponse,
    suppress: Bool,
    label: String
  ) -> Bool {
    guard gateReady(label) else { return false }
    guard !item.isRemoved else {
      XCTFail("\(label): refusing requestDelete on an already removed item")
      return false
    }
    DeleteAlertProbe.reset()
    DeleteAlertProbe.response = response
    DeleteAlertProbe.prepare = { alert in
      XCTAssertTrue(alert.showsSuppressionButton, label)
      XCTAssertNotNil(alert.suppressionButton, label)
      alert.suppressionButton?.state = suppress ? .on : .off
    }
    AppState.shared.requestDelete([item])
    let calls = DeleteAlertProbe.runModalCount + DeleteAlertProbe.sheetCount
    XCTAssertEqual(calls, 1, label)
    XCTAssertFalse(AppState.shared.deleteConfirmationPresented, label)
    sweepAlerts()
    XCTAssertNil(NSApp.alertWindow, label)
    return calls == 1
  }

  private func expectSuppressedDeleteSkipsAlert(_ item: HistoryItemDecorator, label: String) -> Bool {
    guard DeleteItemConfirmationStore.isSuppressed else {
      XCTFail("\(label): delete suppress is not true; refusing requestDelete that would present")
      return false
    }
    guard gateReady(label) else { return false }
    guard !item.isRemoved else {
      XCTFail("\(label): item already removed")
      return false
    }
    DeleteAlertProbe.reset()
    AppState.shared.requestDelete([item])
    let calls = DeleteAlertProbe.runModalCount + DeleteAlertProbe.sheetCount
    XCTAssertEqual(calls, 0, label)
    XCTAssertNil(DeleteAlertProbe.captured, label)
    XCTAssertTrue(item.isRemoved, label)
    XCTAssertFalse(History.shared.all.contains(item), label)
    XCTAssertFalse(AppState.shared.deleteConfirmationPresented, label)
    sweepAlerts()
    XCTAssertNil(NSApp.alertWindow, label)
    return calls == 0 && item.isRemoved
  }

  private func addSynthetic(_ title: String) -> HistoryItemDecorator? {
    guard LabRuntime.isIsolated, LabRuntime.isUnitTestProcess, Storage.shared.isInMemory else {
      XCTFail("refusing synthetic delete item: storage is not an isolated memory store")
      return nil
    }
    guard LabRuntime.suppressesNotifications else {
      XCTFail("refusing synthetic delete item: notifications are not suppressed")
      return nil
    }
    Defaults[.size] = max(savedSize, History.shared.all.count + 8)
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: Data("\(title)-\(UUID().uuidString)".utf8)
      )
    ]
    item.numberOfCopies = 1
    item.title = title
    let decorator = History.shared.add(item)
    created.append(decorator)
    return decorator
  }

  private func persistedFlag(_ name: String, suite: UserDefaults) -> Bool? {
    guard let domain = suite.persistentDomain(forName: LabRuntime.isolatedDefaultsSuite),
          let raw = domain[name] else { return nil }
    if let value = raw as? Bool { return value }
    if let number = raw as? NSNumber { return number.boolValue }
    return nil
  }

  private func removeThreeKeys() {
    absent(Defaults.Keys.suppressClearAlert)
    absent(Defaults.Keys.suppressQuitAlert)
    let deleteName = DeleteItemConfirmation.suppressKeyName
    LabDefaults.suite.removeObject(forKey: deleteName)
    UserDefaults(suiteName: LabRuntime.isolatedDefaultsSuite)?.removeObject(forKey: deleteName)
  }

  private func absent(_ key: Defaults.Key<Bool>) {
    key.reset()
    LabDefaults.suite.removeObject(forKey: key.name)
    UserDefaults(suiteName: LabRuntime.isolatedDefaultsSuite)?.removeObject(forKey: key.name)
  }

  private func assertThreeKeys(
    clear: Bool?,
    quit: Bool?,
    delete: Bool?,
    clearItem: FooterItem,
    quitItem: FooterItem,
    label: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard let reopened = UserDefaults(suiteName: LabRuntime.isolatedDefaultsSuite),
          reopened !== UserDefaults.standard else {
      XCTFail("\(label): isolated suite did not reopen", file: file, line: line)
      return
    }
    let clearName = Defaults.Keys.suppressClearAlert.name
    let quitName = Defaults.Keys.suppressQuitAlert.name
    let deleteName = DeleteItemConfirmation.suppressKeyName
    // object(forKey:) includes Defaults.register(defaults:). Absence is the persistent domain.
    XCTAssertEqual(persistedFlag(clearName, suite: reopened), clear, label, file: file, line: line)
    XCTAssertEqual(persistedFlag(quitName, suite: reopened), quit, label, file: file, line: line)
    XCTAssertEqual(persistedFlag(deleteName, suite: reopened), delete, label, file: file, line: line)
    XCTAssertEqual(persistedFlag(clearName, suite: LabDefaults.suite), clear, label, file: file, line: line)
    XCTAssertEqual(persistedFlag(quitName, suite: LabDefaults.suite), quit, label, file: file, line: line)
    XCTAssertEqual(persistedFlag(deleteName, suite: LabDefaults.suite), delete, label, file: file, line: line)
    XCTAssertNotNil(clearItem.suppressConfirmation, label, file: file, line: line)
    XCTAssertNotNil(quitItem.suppressConfirmation, label, file: file, line: line)
    XCTAssertEqual(clearItem.suppressConfirmation?.wrappedValue ?? false, clear ?? false, label, file: file, line: line)
    XCTAssertEqual(quitItem.suppressConfirmation?.wrappedValue ?? false, quit ?? false, label, file: file, line: line)
    XCTAssertEqual(DeleteItemConfirmationStore.isSuppressed, delete == true, label, file: file, line: line)
    let liveClearBinding = AppState.shared.footer.items.first { $0.title == "clear_all" }?.suppressConfirmation
    let liveQuitBinding = AppState.shared.footer.items.first { $0.title == "quit" }?.suppressConfirmation
    XCTAssertNotNil(liveClearBinding, label, file: file, line: line)
    XCTAssertNotNil(liveQuitBinding, label, file: file, line: line)
    XCTAssertEqual(liveClearBinding?.wrappedValue ?? false, clear ?? false, label, file: file, line: line)
    XCTAssertEqual(liveQuitBinding?.wrappedValue ?? false, quit ?? false, label, file: file, line: line)
    assertStandardUntouched(file: file, line: line)
  }

  private func restoreObservedPreferences() {
    let clearName = Defaults.Keys.suppressClearAlert.name
    let quitName = Defaults.Keys.suppressQuitAlert.name
    let deleteName = DeleteItemConfirmation.suppressKeyName
    var suites = [
      Defaults.Keys.suppressClearAlert.suite,
      Defaults.Keys.suppressQuitAlert.suite,
      LabDefaults.suite
    ]
    if let reopened = UserDefaults(suiteName: LabRuntime.isolatedDefaultsSuite) {
      suites.append(reopened)
    }
    for suite in suites where suite !== UserDefaults.standard {
      restorePreference(savedClearObject, name: clearName, suite: suite)
      restorePreference(savedQuitObject, name: quitName, suite: suite)
      restorePreference(savedDelete, name: deleteName, suite: suite)
    }
    restoreStandardIfTouched()
  }

  private func restorePreference(_ value: Any?, name: String, suite: UserDefaults) {
    guard suite !== UserDefaults.standard else { return }
    if let value {
      suite.set(value, forKey: name)
    } else {
      suite.removeObject(forKey: name)
    }
  }

  private func restoreStandardIfTouched() {
    for name in preferenceNames {
      guard token(UserDefaults.standard.object(forKey: name)) != standardBefore[name] else { continue }
      if standardMissing.contains(name) {
        UserDefaults.standard.removeObject(forKey: name)
      } else if let value = standardObjects[name] {
        UserDefaults.standard.set(value, forKey: name)
      }
    }
  }

  private func snapStandard() {
    standardObjects = [:]
    standardMissing = []
    standardBefore = [:]
    for name in preferenceNames {
      if let value = UserDefaults.standard.object(forKey: name) {
        standardObjects[name] = value
        standardBefore[name] = token(value)
      } else {
        standardMissing.insert(name)
        standardBefore[name] = "nil"
      }
    }
  }

  private func assertStandardUntouched(file: StaticString = #filePath, line: UInt = #line) {
    for name in preferenceNames {
      XCTAssertEqual(
        token(UserDefaults.standard.object(forKey: name)),
        standardBefore[name],
        "standard defaults changed for \(name)",
        file: file,
        line: line
      )
    }
  }

  private var preferenceNames: [String] {
    [
      Defaults.Keys.suppressClearAlert.name,
      Defaults.Keys.suppressQuitAlert.name,
      DeleteItemConfirmation.suppressKeyName,
      Defaults.Keys.size.name
    ]
  }

  private func samePreference(_ lhs: Any?, _ rhs: Any?) -> Bool {
    if lhs == nil && rhs == nil { return true }
    if let left = lhs as? Bool, let right = rhs as? Bool { return left == right }
    if let left = lhs as? NSNumber, let right = rhs as? NSNumber { return left.isEqual(to: right) }
    if let left = lhs as? Bool, let right = rhs as? NSNumber { return NSNumber(value: left).isEqual(to: right) }
    if let left = lhs as? NSNumber, let right = rhs as? Bool { return left.isEqual(to: NSNumber(value: right)) }
    return false
  }

  private func token(_ value: Any?) -> String {
    guard let value else { return "nil" }
    return "\(type(of: value)):\(value)"
  }

  private func footerItem(
    message: String,
    comment: String,
    confirm: String,
    cancel: String,
    confirmHelp: String,
    cancelHelp: String,
    suppressHelp: String,
    suppress: Binding<Bool>,
    action: @escaping () -> Void
  ) -> FooterItem {
    FooterItem(
      title: message,
      confirmation: .init(
        message: message,
        comment: comment,
        confirm: confirm,
        cancel: cancel,
        confirmHelp: confirmHelp,
        cancelHelp: cancelHelp,
        suppressHelp: suppressHelp
      ),
      suppressConfirmation: suppress,
      action: action
    )
  }

  @discardableResult
  private func present(_ item: FooterItem, response: NSApplication.ModalResponse, suppress: Bool) -> Bool {
    guard gateReady("presentFooterConfirmation") else { return false }
    DeleteAlertProbe.reset()
    DeleteAlertProbe.response = response
    DeleteAlertProbe.prepare = { alert in
      XCTAssertTrue(item.showConfirmation)
      XCTAssertEqual(alert.buttons.count, 2)
      XCTAssertEqual(alert.buttons.first?.title, NSLocalizedString(item.confirmation!.confirmKey, comment: ""))
      XCTAssertEqual(alert.buttons.dropFirst().first?.title, NSLocalizedString(item.confirmation!.cancelKey, comment: ""))
      XCTAssertEqual(alert.buttons.first?.toolTip, NSLocalizedString(item.confirmation!.confirmHelpKey, comment: ""))
      XCTAssertEqual(alert.buttons.dropFirst().first?.toolTip, NSLocalizedString(item.confirmation!.cancelHelpKey, comment: ""))
      XCTAssertFalse(alert.buttons.first?.toolTip?.isEmpty ?? true)
      XCTAssertFalse(alert.buttons.dropFirst().first?.toolTip?.isEmpty ?? true)
      XCTAssertTrue(alert.showsSuppressionButton)
      XCTAssertNotNil(alert.suppressionButton, "clear/quit suppression button was not installed")
      XCTAssertFalse(alert.suppressionButton?.toolTip?.isEmpty ?? true)
      XCTAssertEqual(
        alert.suppressionButton?.toolTip,
        NSLocalizedString(item.confirmation!.suppressHelpKey, comment: ""),
        "suppression tooltip is not bound to \(item.confirmation!.suppressHelpKey)"
      )
      XCTAssertNotEqual(
        NSLocalizedString("clear_alert_suppress_help", comment: ""),
        NSLocalizedString("quit_alert_suppress_help", comment: ""),
        "clear and quit suppression help must stay distinct"
      )
      alert.suppressionButton?.state = suppress ? .on : .off
      let calls = DeleteAlertProbe.runModalCount + DeleteAlertProbe.sheetCount
      AppState.shared.presentFooterConfirmation(item)
      XCTAssertEqual(DeleteAlertProbe.runModalCount + DeleteAlertProbe.sheetCount, calls, "reentry must not present a second alert")
    }
    AppState.shared.presentFooterConfirmation(item)
    XCTAssertEqual(DeleteAlertProbe.runModalCount + DeleteAlertProbe.sheetCount, 1)
    sweepAlerts()
    return DeleteAlertProbe.runModalCount + DeleteAlertProbe.sheetCount == 1
  }
}

private enum DeleteAlertProbe {
  static var installed = false
  static var runModalCount = 0
  static var sheetCount = 0
  static var captured: NSAlert?
  static var response: NSApplication.ModalResponse = .alertSecondButtonReturn
  static var prepare: ((NSAlert) -> Void)?
  private static var replacementRunIMP: IMP?
  private static var replacementSheetIMP: IMP?
  private static let runSelector = NSSelectorFromString("maccyContractRunModal")
  private static let sheetSelector = NSSelectorFromString("maccyContractBeginSheetModalForWindow:completionHandler:")

  static func reset() {
    runModalCount = 0
    sheetCount = 0
    response = .alertSecondButtonReturn
    prepare = nil
    releaseAlert()
  }

  static func releaseAlert() {
    captured?.window.orderOut(nil)
    captured = nil
  }

  static func install() -> Bool {
    guard !installed else { return impsMatch() }
    guard let runModal = class_getInstanceMethod(NSAlert.self, #selector(NSAlert.runModal)),
          let replacement = class_getInstanceMethod(NSAlert.self, runSelector),
          let sheet = class_getInstanceMethod(NSAlert.self, #selector(NSAlert.beginSheetModal(for:completionHandler:))),
          let sheetReplacement = class_getInstanceMethod(NSAlert.self, sheetSelector)
    else { return false }
    replacementRunIMP = method_getImplementation(replacement)
    replacementSheetIMP = method_getImplementation(sheetReplacement)
    method_exchangeImplementations(runModal, replacement)
    method_exchangeImplementations(sheet, sheetReplacement)
    installed = true
    return impsMatch()
  }

  static func uninstall() {
    guard installed,
          let runModal = class_getInstanceMethod(NSAlert.self, #selector(NSAlert.runModal)),
          let replacement = class_getInstanceMethod(NSAlert.self, runSelector),
          let sheet = class_getInstanceMethod(NSAlert.self, #selector(NSAlert.beginSheetModal(for:completionHandler:))),
          let sheetReplacement = class_getInstanceMethod(NSAlert.self, sheetSelector)
    else {
      installed = false
      return
    }
    method_exchangeImplementations(runModal, replacement)
    method_exchangeImplementations(sheet, sheetReplacement)
    installed = false
  }

  private static func impsMatch() -> Bool {
    class_getMethodImplementation(NSAlert.self, #selector(NSAlert.runModal)) == replacementRunIMP
      && class_getMethodImplementation(NSAlert.self, #selector(NSAlert.beginSheetModal(for:completionHandler:))) == replacementSheetIMP
  }
}

extension NSAlert {
  @objc(maccyContractRunModal)
  func maccyContractRunModal() -> NSApplication.ModalResponse {
    DeleteAlertProbe.runModalCount += 1
    DeleteAlertProbe.captured = self
    DeleteAlertProbe.prepare?(self)
    window.orderOut(nil)
    return DeleteAlertProbe.response
  }

  @objc(maccyContractBeginSheetModalForWindow:completionHandler:)
  func maccyContractBeginSheetModal(
    for window: NSWindow,
    completionHandler handler: ((NSApplication.ModalResponse) -> Void)?
  ) {
    DeleteAlertProbe.sheetCount += 1
    DeleteAlertProbe.captured = self
    DeleteAlertProbe.prepare?(self)
    self.window.orderOut(nil)
    handler?(DeleteAlertProbe.response)
  }
}
