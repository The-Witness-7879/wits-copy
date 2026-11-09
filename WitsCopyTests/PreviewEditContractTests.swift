import AppKit
import Defaults
import SwiftUI
import XCTest
@testable import WitsCopy

/// Offscreen native controls for pin-shortcut recording, original-text save, and the outer row.
/// Does not order, activate, send events through NSApp, or touch the system pasteboard.
@MainActor
final class PreviewEditContractTests: XCTestCase {
  private let history = History.shared
  private var savedCompact = false
  private var probe: SealedEditPanel?

  override func setUp() {
    super.setUp()
    savedCompact = Defaults[.compactRows]
    Defaults[.compactRows] = false
    history.clearAll()
    AppState.shared.panelPresented = false
    AppState.shared.windowPinned = false
    AppState.shared.endPinRecordingSession()
    AppState.shared.discardAllTextDrafts()
    AppState.shared.storageError = nil
    AppState.shared.navigator.select(item: nil)
    Storage.shared.saveImplementation = nil
    Clipboard.shared.copyProbe = nil
    history.searchQuery = ""
  }

  override func tearDown() {
    probe?.close()
    probe = nil
    AppState.shared.panelPresented = false
    AppState.shared.endPinRecordingSession()
    AppState.shared.discardAllTextDrafts()
    AppState.shared.storageError = nil
    Storage.shared.saveImplementation = nil
    Clipboard.shared.copyProbe = nil
    history.searchQuery = ""
    history.clearAll()
    Defaults[.compactRows] = savedCompact
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "maccy-preview-edit-contract-\(ProcessInfo.processInfo.processIdentifier)",
      isDirectory: true
    )
    try? FileManager.default.removeItem(at: root)
    super.tearDown()
  }

  func testDoubleClickRecordsCommandLetterAndSingleClickDoesNotCopy() throws {
    let item = pin("s", body: "slot-body")
    var copies = 0
    Clipboard.shared.copyProbe = { _, _ in copies += 1 }
    let host = try mount(HistoryItemView(item: item, previous: nil, next: nil, index: 0).frame(width: 420, height: 90))
    let recorder = try pinRecorder(id: item.id, in: host)
    XCTAssertEqual(recorder.accessibilityIdentifier(), "lab-pin-shortcut-\(item.id.uuidString)")
    XCTAssertNotNil(find("lab-row-shortcuts-\(item.id.uuidString)", in: host))

    recorder.mouseDown(with: try mouse(clickCount: 1, in: host))
    XCTAssertNil(AppState.shared.pinRecordingItemID)
    XCTAssertEqual(item.item.pin, "s")
    XCTAssertEqual(copies, 0)
    XCTAssertFalse(recorder.performKeyEquivalent(with: try key("l", code: 37, flags: .command)))

    recorder.mouseDown(with: try mouse(clickCount: 2, in: host))
    XCTAssertEqual(AppState.shared.pinRecordingItemID, item.id)
    XCTAssertTrue(host.window?.firstResponder === recorder)
    XCTAssertNotNil(find("lab-shortcut-recording", in: recorder))
    XCTAssertEqual(copies, 0, "double-click copied or committed the row")

    XCTAssertTrue(recorder.performKeyEquivalent(with: try key("L", code: 37, flags: .command)))
    XCTAssertEqual(item.item.pin, "l")
    XCTAssertEqual(item.title, "slot-body")
    XCTAssertNil(AppState.shared.pinRecordingItemID)
    XCTAssertEqual(copies, 0)
    XCTAssertFalse(host.window?.isVisible ?? true)
    XCTAssertLessThan(host.window?.frame.maxX ?? 0, 0)
  }

  func testIllegalAndConflictingKeysStayInRecordingWithoutStealing() throws {
    let taken = pin("k", body: "taken")
    let item = pin("s", body: "mine")
    let host = try mount(HistoryItemView(item: item, previous: nil, next: nil, index: 0).frame(width: 420, height: 90))
    let recorder = try pinRecorder(id: item.id, in: host)
    recorder.mouseDown(with: try mouse(clickCount: 2, in: host))

    XCTAssertTrue(recorder.keyDownConsumed(try key("1", code: 18, flags: .command)))
    XCTAssertEqual(item.item.pin, "s")
    XCTAssertEqual(AppState.shared.pinRecordingItemID, item.id)
    XCTAssertNotNil(find("lab-shortcut-error", in: recorder))

    XCTAssertTrue(recorder.performKeyEquivalent(with: try key("k", code: 40, flags: [.command, .shift])))
    XCTAssertEqual(item.item.pin, "s")
    XCTAssertEqual(taken.item.pin, "k")

    XCTAssertTrue(recorder.performKeyEquivalent(with: try key("k", code: 40, flags: .command)))
    XCTAssertEqual(item.item.pin, "s")
    XCTAssertEqual(taken.item.pin, "k")
    XCTAssertEqual(AppState.shared.pinRecordingItemID, item.id)

    recorder.keyDown(with: try key("", code: 53, flags: []))
    XCTAssertNil(AppState.shared.pinRecordingItemID)
    XCTAssertEqual(item.item.pin, "s")
  }

  func testUnpinnedSlotDoesNotRecordAndEmptyPinCanStillRecord() throws {
    let loose = history.add(textItem("loose"))
    let host = try mount(HistoryItemView(item: loose, previous: nil, next: nil, index: 0).frame(width: 420, height: 90))
    let recorder = try pinRecorder(id: loose.id, in: host)
    XCTAssertNil(recorder.hitTest(NSPoint(x: 4, y: 4)))
    recorder.mouseDown(with: try mouse(clickCount: 2, in: host))
    XCTAssertFalse(recorder.accessibilityPerformPress())
    XCTAssertNil(AppState.shared.pinRecordingItemID)
    XCTAssertNil(loose.item.pin)

    let blank = pin("", body: "no-letter")
    for letter in HistoryItem.supportedPins {
      let other = textItem("owner-\(letter)")
      other.pin = letter
      _ = history.add(other)
    }
    let pinnedHost = try mount(HistoryItemView(item: blank, previous: nil, next: nil, index: 0).frame(width: 420, height: 90))
    let pinnedRecorder = try pinRecorder(id: blank.id, in: pinnedHost)
    pinnedRecorder.mouseDown(with: try mouse(clickCount: 2, in: pinnedHost))
    XCTAssertEqual(AppState.shared.pinRecordingItemID, blank.id)
    XCTAssertTrue(pinnedRecorder.performKeyEquivalent(with: try key("b", code: 11, flags: .command)))
    XCTAssertEqual(blank.item.pin, "")
    XCTAssertNotNil(blank.item.pin, "exhausted letters removed the pin")
    XCTAssertEqual(AppState.shared.pinRecordingItemID, blank.id)
  }

  func testAllTwentySixLettersOccupiedStillLeavesTheItemPinned() throws {
    let reserved = ["a", "q", "v", "w", "z"]
    for letter in reserved {
      XCTAssertFalse(HistoryItem.supportedPins.contains(letter), "auto pool must keep \(letter) out")
    }
    let blank = pin("", body: "still-pinned")
    let host = try mount(HistoryItemView(item: blank, previous: nil, next: nil, index: 0).frame(width: 420, height: 90))
    let recorder = try pinRecorder(id: blank.id, in: host)
    recorder.mouseDown(with: try mouse(clickCount: 2, in: host))
    XCTAssertTrue(recorder.performKeyEquivalent(with: try key("a", code: 0, flags: .command)))
    XCTAssertEqual(blank.item.pin, "a", "a free reserved letter must still be recordable")
    blank.item.pin = ""
    let letters = Array("abcdefghijklmnopqrstuvwxyz").map(String.init)
    XCTAssertEqual(letters.count, 26)
    for letter in letters {
      let other = textItem("owner-\(letter)")
      other.pin = letter
      _ = history.add(other)
    }
    recorder.mouseDown(with: try mouse(clickCount: 2, in: host))
    XCTAssertTrue(recorder.performKeyEquivalent(with: try key("a", code: 0, flags: .command)))
    XCTAssertEqual(blank.item.pin, "", "a taken letter overwrote the empty pin")
    XCTAssertNotNil(blank.item.pin, "occupying every letter removed the pin")
    XCTAssertEqual(AppState.shared.pinRecordingItemID, blank.id)
    for letter in reserved {
      XCTAssertFalse(HistoryItem.supportedPins.contains(letter))
    }
    XCTAssertEqual(
      history.all.first { $0.title == "owner-a" }?.item.pin,
      "a"
    )
  }

  /// Row-end recording and tag editing share one session. Lead change already
  /// closes a preview tag editor, so the cross-item recording step uses the
  /// recorder press, which does not select.
  func testTagAndRowRecordingAreMutuallyExclusive() throws {
    XCTAssertTrue(LabRuntime.isIsolated)
    XCTAssertTrue(Storage.shared.isInMemory)
    let first = pin("s", body: "mutex-a")
    let second = pin("t", body: "mutex-b")
    AppState.shared.navigator.select(item: first)
    AppState.shared.preview.state = .open
    AppState.shared.clearTagEditor()
    AppState.shared.previewShortcutItemID = nil
    PinRecordingKeyRoute.end(nil)
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    let delegate = AppDelegate()
    let previous = AppState.shared.appDelegate
    let previousPanel = previous?.panel
    let panel = SealedShortcutPanel(
      contentRect: NSRect(x: -24000, y: -24000, width: 480, height: 420),
      identifier: "lab-editor-mutex",
      onClose: {}
    ) { ContentView() }
    panel.collectionBehavior = [.stationary, .ignoresCycle]
    panel.setFrame(NSRect(x: -24000, y: -24000, width: 480, height: 420), display: false)
    panel.isReleasedWhenClosed = false
    let host = NSHostingView(
      rootView: EditorMutexHost(first: first, second: second)
        .environment(AppState.shared)
        .environment(ModifierFlags())
        .modelContainer(Storage.shared.container)
    )
    host.sizingOptions = []
    host.frame = NSRect(x: 0, y: 0, width: 480, height: 420)
    panel.contentView = host
    AppState.shared.appDelegate = delegate
    delegate.panel = panel
    AppState.shared.panelPresented = true
    defer {
      AppState.shared.panelPresented = false
      AppState.shared.endPinRecordingSession()
      AppState.shared.clearTagEditor()
      AppState.shared.previewShortcutItemID = nil
      PinRecordingKeyRoute.end(nil)
      panel.close()
      delegate.panel = nil
      AppState.shared.appDelegate = previous
      previous?.panel = previousPanel
    }
    drain(0.15)
    host.layoutSubtreeIfNeeded()

    try pressTag(of: first, in: host)
    drain(0.25)
    host.layoutSubtreeIfNeeded()
    XCTAssertTrue(AppState.shared.presentsTagEditor(first, at: .preview))
    XCTAssertNotNil(find("lab-tag-field", in: host), "tag field did not mount")

    let firstRecorder = try pinRecorder(id: first.id, in: host)
    firstRecorder.mouseDown(with: try mouse(clickCount: 2, in: host))
    drain(0.25)
    host.layoutSubtreeIfNeeded()
    XCTAssertEqual(AppState.shared.navigator.leadHistoryItem?.id, first.id)
    XCTAssertNil(AppState.shared.tagEditorItem, "same-item row recording left the tag editor open")
    XCTAssertNil(find("lab-tag-field", in: host), "same-item row recording left the tag field mounted")
    XCTAssertEqual(AppState.shared.pinRecordingItemID, first.id)
    XCTAssertTrue(firstRecorder.recording)
    XCTAssertTrue(firstRecorder.ownsSession)
    XCTAssertTrue(PinRecordingKeyRoute.isInstalled)
    XCTAssertTrue(PinRecordingKeyRoute.owner === firstRecorder, "clearing the tag editor cancelled the recorder")
    XCTAssertEqual(first.item.pin, "s")
    XCTAssertEqual(second.item.pin, "t")

    try pressTag(of: first, in: host)
    drain(0.25)
    host.layoutSubtreeIfNeeded()
    XCTAssertTrue(AppState.shared.presentsTagEditor(first, at: .preview))
    XCTAssertNotNil(find("lab-tag-field", in: host))
    XCTAssertNil(AppState.shared.pinRecordingItemID, "tag edit left row recording active")
    XCTAssertFalse(firstRecorder.recording)
    XCTAssertFalse(PinRecordingKeyRoute.isInstalled, "tag edit left the recording monitor installed")

    let secondRecorder = try pinRecorder(id: second.id, in: host)
    XCTAssertTrue(secondRecorder.accessibilityPerformPress())
    drain(0.25)
    host.layoutSubtreeIfNeeded()
    XCTAssertEqual(
      AppState.shared.navigator.leadHistoryItem?.id,
      first.id,
      "cross-item press must not rely on a lead change to close the tag editor"
    )
    XCTAssertNil(AppState.shared.tagEditorItem, "cross-item recording left the other item's tag editor open")
    XCTAssertNil(find("lab-tag-field", in: host))
    XCTAssertEqual(AppState.shared.pinRecordingItemID, second.id)
    XCTAssertTrue(secondRecorder.recording)
    XCTAssertTrue(secondRecorder.ownsSession)
    XCTAssertTrue(PinRecordingKeyRoute.isInstalled)
    XCTAssertTrue(PinRecordingKeyRoute.owner === secondRecorder, "clearing the other tag editor cancelled the new recorder")
    XCTAssertEqual(first.item.pin, "s")
    XCTAssertEqual(second.item.pin, "t")

    try pressTag(of: first, in: host)
    drain(0.25)
    host.layoutSubtreeIfNeeded()
    XCTAssertTrue(AppState.shared.presentsTagEditor(first, at: .preview))
    XCTAssertNotNil(find("lab-tag-field", in: host))
    XCTAssertNil(AppState.shared.pinRecordingItemID, "cross-item tag edit left the other recording active")
    XCTAssertFalse(secondRecorder.recording)
    XCTAssertFalse(PinRecordingKeyRoute.isInstalled, "cross-item tag edit left the recording monitor installed")
    XCTAssertEqual(second.item.pin, "t")

    XCTAssertFalse(panel.isVisible)
    XCTAssertFalse(panel.isKeyWindow)
    XCTAssertLessThan(panel.frame.maxX, 0)
    XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0, front)
  }

  func testLateKeyAfterSwitchDoesNotWriteTheNewLead() throws {
    let first = pin("s", body: "first")
    let second = pin("t", body: "second")
    let host = try mount(HistoryItemView(item: first, previous: nil, next: nil, index: 0).frame(width: 420, height: 90))
    let recorder = try pinRecorder(id: first.id, in: host)
    recorder.mouseDown(with: try mouse(clickCount: 2, in: host))
    AppState.shared.navigator.select(item: second)
    XCTAssertNil(AppState.shared.pinRecordingItemID)
    recorder.performKeyEquivalent(with: try key("m", code: 46, flags: .command))
    XCTAssertEqual(first.item.pin, "s")
    XCTAssertEqual(second.item.pin, "t")
    XCTAssertNotEqual(AppState.shared.navigator.leadHistoryItem?.id, first.id)
  }

  func testAccessibilityPressStartsRecordingButDoesNotAssignAString() throws {
    let item = pin("s", body: "ax")
    let host = try mount(HistoryItemView(item: item, previous: nil, next: nil, index: 0).frame(width: 420, height: 90))
    let recorder = try pinRecorder(id: item.id, in: host)
    XCTAssertTrue(recorder.accessibilityPerformPress())
    XCTAssertEqual(AppState.shared.pinRecordingItemID, item.id)
    recorder.setAccessibilityValue("q")
    XCTAssertEqual(item.item.pin, "s", "an accessibility value assigned a shortcut without a key event")
    XCTAssertEqual(AppState.shared.pinRecordingItemID, item.id)
  }

  func testOriginalTextSaveKeepsIdentityAndCopyPayload() throws {
    let item = pin("s", body: "old")
    item.item.tags = ["kept"]
    item.item.application = "com.example.editor"
    item.item.numberOfCopies = 4
    let first = item.item.firstCopiedAt
    let last = item.item.lastCopiedAt
    let object = ObjectIdentifier(item.item)
    let host = try mount(OriginalTextEditSection(item: item).frame(width: 360, height: 220))
    let body = try beginEdit("lab-preview-edit-body", in: host)
    body.insertText("  \t你好⌘\n  let x = 1\n", replacementRange: NSRange(location: 0, length: body.string.utf16.count))
    body.didChangeText()
    drain(0.15)
    var copies = 0
    Clipboard.shared.copyProbe = { _, _ in copies += 1 }
    try submit(body)
    XCTAssertEqual(copies, 0)
    XCTAssertFalse(AppState.shared.panelPresented)
    let saved = "  \t你好⌘\n  let x = 1\n"
    XCTAssertEqual(item.item.text, saved)
    XCTAssertEqual(OriginalTextEdit.stringBytes(in: item.item), Data(saved.utf8))
    XCTAssertEqual(ObjectIdentifier(item.item), object)
    XCTAssertEqual(item.item.pin, "s")
    XCTAssertEqual(item.item.tags, ["kept"])
    XCTAssertEqual(item.item.application, "com.example.editor")
    XCTAssertEqual(item.item.numberOfCopies, 4)
    XCTAssertEqual(item.item.firstCopiedAt, first)
    XCTAssertEqual(item.item.lastCopiedAt, last)
    XCTAssertNil(find("lab-preview-edit-save", in: host))
    history.searchQuery = "你好"
    drain(0.2)
    XCTAssertTrue(history.items.contains { $0.id == item.id })
  }

  func testSaveFailureRestoresBytesAndKeepsTheDraft() throws {
    let item = pin("s", body: "original-body")
    let host = try mount(OriginalTextEditSection(item: item).frame(width: 360, height: 200))
    let body = try beginEdit("lab-preview-edit-body", in: host)
    body.insertText("retry-me", replacementRange: NSRange(location: 0, length: body.string.utf16.count))
    body.didChangeText()
    drain(0.1)
    Storage.shared.saveImplementation = { throw CocoaError(.fileWriteUnknown) }
    try submit(body)
    XCTAssertEqual(item.item.text, "original-body")
    XCTAssertEqual(body.string, "retry-me")
    XCTAssertTrue(body.isEditable, "failed save left the edit")
    let error = try XCTUnwrap(
      find("lab-preview-edit-error", in: host) as? NSTextField,
      errorMiss(in: host, itemID: item.id)
    )
    XCTAssertFalse(error.stringValue.isEmpty)
    XCTAssertEqual(AppState.shared.textDraft(for: item.id)?.body, "retry-me")

    Storage.shared.saveImplementation = nil
    try submit(body)
    XCTAssertEqual(item.item.text, "retry-me")
    XCTAssertNil(AppState.shared.textEditError(for: item.id))
  }

  func testCancelAndItemSwitchDoNotSilentlyDropOrOverwrite() throws {
    let first = pin("s", body: "first-body")
    let second = pin("t", body: "second-body")
    let host = try mount(OriginalTextEditSection(item: first).frame(width: 360, height: 180))
    let body = try beginEdit("lab-preview-edit-body", in: host)
    body.insertText("draft-one", replacementRange: NSRange(location: 0, length: body.string.utf16.count))
    drain(0.1)
    host.removeFromSuperview()
    drain(0.1)
    XCTAssertEqual(first.item.text, "first-body")
    XCTAssertEqual(AppState.shared.textDraft(for: first.id)?.body, "draft-one")

    let next = try mount(OriginalTextEditSection(item: second).frame(width: 360, height: 180))
    let nextBody = try textView("lab-preview-edit-body", in: next)
    XCTAssertEqual(nextBody.string, "second-body")
    XCTAssertEqual(second.item.text, "second-body")

    let restored = try mount(OriginalTextEditSection(item: first).frame(width: 360, height: 180))
    let restoredBody = try beginEdit("lab-preview-edit-body", in: restored)
    XCTAssertEqual(restoredBody.string, "draft-one")
    try cancelEdit(restoredBody)
    XCTAssertNil(AppState.shared.textDraft(for: first.id))
    XCTAssertEqual(first.item.text, "first-body")
  }

  func testNonTextAndOversizedItemsStayReadOnly() throws {
    let image = imageItem("pixel")
    let imageHost = try mount(OriginalTextEditSection(item: image).frame(width: 280, height: 80))
    XCTAssertNil(find("lab-preview-edit-body", in: imageHost))
    XCTAssertNil(find("lab-preview-edit-title", in: imageHost))
    XCTAssertNil(find("lab-preview-title", in: imageHost))
    XCTAssertNotNil(find("lab-preview-edit-refused", in: imageHost))
    XCTAssertEqual(AppState.shared.saveOriginalText(itemID: image.id, draft: OriginalTextDraft(title: "x", body: "y")), .rejected(OriginalTextRefusal.image.explanation))

    let file = try fileItem()
    let before = try Data(contentsOf: file.url)
    XCTAssertEqual(
      AppState.shared.saveOriginalText(itemID: file.item.id, draft: OriginalTextDraft(title: "x", body: "changed")),
      .rejected(OriginalTextRefusal.fileBacked.explanation)
    )
    XCTAssertEqual(try Data(contentsOf: file.url), before)

    let rich = textItem("rich-body")
    rich.contents.append(HistoryItemContent(type: NSPasteboard.PasteboardType.rtf.rawValue, value: Data("{\\rtf1 rich}".utf8)))
    let richDecorator = history.add(rich)
    XCTAssertEqual(OriginalTextEdit.refusal(for: richDecorator.item), .richText)
    XCTAssertNil(find("lab-preview-edit-body", in: try mount(OriginalTextEditSection(item: richDecorator).frame(width: 280, height: 80))))

    let huge = String(repeating: "x", count: OriginalTextEdit.maxEditableCharacters + 1)
    let hugeItem = textItem(huge)
    let hugeDecorator = history.add(hugeItem)
    XCTAssertEqual(OriginalTextEdit.refusal(for: hugeDecorator.item), .oversized)
    XCTAssertEqual(hugeDecorator.item.text, huge)
  }

  func testCommandReturnSavesAndEscapeCancelsWithoutCopying() throws {
    let item = pin("s", body: "cmd-body")
    var copies = 0
    Clipboard.shared.copyProbe = { _, _ in copies += 1 }
    AppState.shared.panelPresented = true
    let host = try mount(OriginalTextEditSection(item: item).frame(width: 360, height: 180))
    let body = try beginEdit("lab-preview-edit-body", in: host)
    body.insertText("saved-by-key", replacementRange: NSRange(location: 0, length: body.string.utf16.count))
    drain(0.1)
    try submit(body)
    XCTAssertEqual(item.item.text, "saved-by-key")
    XCTAssertEqual(copies, 0)
    XCTAssertTrue(AppState.shared.panelPresented)

    let again = try beginEdit("lab-preview-edit-body", in: host)
    again.insertText("discard-me", replacementRange: NSRange(location: 0, length: again.string.utf16.count))
    drain(0.05)
    try cancelEdit(again)
    XCTAssertEqual(item.item.text, "saved-by-key")
    XCTAssertEqual(copies, 0)
    XCTAssertTrue(AppState.shared.panelPresented)
  }

  func testOuterRowHighlightCoversTagsAndKeepsFixedEnds() throws {
    let first = history.add(textItem("row-one"))
    let second = history.add(textItem("row-two"))
    second.item.tags = ["kept-tag"]
    second.noteTagsChanged()
    AppState.shared.navigator.select(item: second)
    let root = VStack(spacing: 0) {
      HistoryItemView(item: first, previous: nil, next: second, index: 0)
      HistoryItemView(item: second, previous: first, next: nil, index: 1)
    }
    .frame(width: 460)
    let host = try mount(root)
    let previewOne = try frame("lab-row-preview-\(first.id.uuidString)", in: host)
    let previewTwo = try frame("lab-row-preview-\(second.id.uuidString)", in: host)
    let shortcut = try frame("lab-row-shortcuts-\(second.id.uuidString)", in: host)
    let tag = try frame("lab-row-category-kept-tag", in: host)
    let highlight = try frame("lab-row-highlight-\(second.id.uuidString)", in: host)
    let highlightOne = try frame("lab-row-highlight-\(first.id.uuidString)", in: host)

    XCTAssertEqual(previewOne.height, HistoryRowMetrics.contentHeight, accuracy: 0.5)
    // 快捷键槽只留够 ⌘X：槽里再留白，就会跟图钉之间空出一大截。
    XCTAssertEqual(shortcut.width, HistoryRowMetrics.shortcutWidth, accuracy: 0.5)
    // ⋯ 已撤，快捷键槽之后只剩一点贴边距离。
    XCTAssertEqual(highlight.maxX - shortcut.maxX, HistoryRowMetrics.shortcutTrailing, accuracy: 2)
    XCTAssertTrue(highlight.contains(previewTwo.insetBy(dx: 0, dy: 0.5)))
    XCTAssertTrue(highlight.contains(shortcut.insetBy(dx: 0, dy: 0.5)))
    XCTAssertTrue(highlight.contains(tag.insetBy(dx: 0, dy: 0.5)))
    XCTAssertEqual(adjacentGap(highlightOne, highlight), HistoryRowMetrics.rowGap, accuracy: 1.5)
    let previewView = try XCTUnwrap(find("lab-row-preview-\(second.id.uuidString)", in: host))
    let highlightView = try XCTUnwrap(find("lab-row-highlight-\(second.id.uuidString)", in: host))
    let local = previewView.convert(previewView.bounds, to: highlightView)
    let nearer = min(abs(local.minY), abs(highlightView.bounds.maxY - local.maxY))
    XCTAssertEqual(nearer, HistoryRowMetrics.verticalInset, accuracy: 2)
  }

  func testImageStateIsVisibleOnTheImageAndDoesNotHit() throws {
    let item = imageItem("shot")
    let canvas = NSImage(size: NSSize(width: 80, height: 40))
    canvas.lockFocus()
    NSColor.systemGreen.setFill()
    NSRect(x: 0, y: 0, width: 80, height: 40).fill()
    canvas.unlockFocus()
    item.thumbnailImage = canvas
    AppState.shared.navigator.select(item: item)
    let host = try mount(HistoryItemView(item: item, previous: nil, next: nil, index: 0).frame(width: 420, height: 90))
    let mark = try XCTUnwrap(find("lab-row-image-state-\(item.id.uuidString)", in: host) as? ImageStateMarkView)
    let image = try XCTUnwrap(find("lab-row-preview-\(item.id.uuidString)", in: host))
    XCTAssertNil(mark.hitTest(NSPoint(x: 1, y: 1)))
    let markFrame = mark.convert(mark.bounds, to: nil)
    let imageFrame = image.convert(image.bounds, to: nil)
    XCTAssertGreaterThan(mark.bounds.height, 20)
    XCTAssertTrue(markFrame.intersects(imageFrame))
    XCTAssertNil(mark.hitTest(NSPoint(x: 2, y: min(8, mark.bounds.midY))))
    let pixels = try XCTUnwrap(bitmap(mark))
    let edge = try XCTUnwrap(pixels.colorAt(x: 1, y: 1))
    XCTAssertGreaterThan(edge.alphaComponent, 0.2, "image state mark did not draw on the thumbnail")
    let imagePixels = try XCTUnwrap(bitmap(image))
    let center = try XCTUnwrap(imagePixels.colorAt(x: imagePixels.pixelsWide / 2, y: imagePixels.pixelsHigh / 2))
    XCTAssertGreaterThan(center.greenComponent, center.blueComponent, "state color covered the image content")
  }

  func testEveryCommandLetterCanBeExplicitlyAssigned() throws {
    let item = pin("s", body: "all-letters")
    let host = try mount(HistoryItemView(item: item, previous: nil, next: nil, index: 0).frame(width: 420, height: 90))
    let recorder = try pinRecorder(id: item.id, in: host)
    let letters: [(String, UInt16)] = [
      ("a", 0), ("b", 11), ("c", 8), ("d", 2), ("e", 14), ("f", 3),
      ("g", 5), ("h", 4), ("i", 34), ("j", 38), ("k", 40), ("l", 37),
      ("m", 46), ("n", 45), ("o", 31), ("p", 35), ("q", 12), ("r", 15),
      ("s", 1), ("t", 17), ("u", 32), ("v", 9), ("w", 13), ("x", 7),
      ("y", 16), ("z", 6)
    ]
    for (letter, code) in letters {
      XCTAssertTrue(recorder.accessibilityPerformPress())
      XCTAssertTrue(recorder.performKeyEquivalent(with: try key(letter, code: code, flags: .command)))
      XCTAssertEqual(item.item.pin, letter, "explicit Command+\(letter) was rejected")
      XCTAssertNil(AppState.shared.pinRecordingItemID)
    }
  }

  func testBodyEditKeepsTitleAndPinAndDoesNotShowATitleField() throws {
    let item = pin("s", body: "title-only-body")
    let host = try mount(OriginalTextEditSection(item: item).frame(width: 360, height: 220))
    XCTAssertNil(find("lab-preview-title", in: host))
    XCTAssertNil(find("lab-preview-edit-save", in: host))
    XCTAssertNil(find("lab-preview-edit-cancel", in: host))
    let body = try beginEdit("lab-preview-edit-body", in: host)
    XCTAssertEqual(body.string, "title-only-body")
    body.insertText("  正文改动  ", replacementRange: NSRange(location: 0, length: body.string.utf16.count))
    body.didChangeText()
    drain(0.1)
    try submit(body)
    XCTAssertEqual(item.item.title, "title-only-body", "body edit rewrote the stored title")
    XCTAssertEqual(item.item.text, "  正文改动  ")
    XCTAssertEqual(item.item.pin, "s")
    XCTAssertNil(find("lab-preview-edit-save", in: host))
  }

  func testShortcutLaneIsReachableThroughTheNativeHitTestChain() throws {
    let item = pin("s", body: "native-hit")
    let host = try mount(HistoryItemView(item: item, previous: nil, next: nil, index: 0).frame(width: 420, height: 90))
    let recorder = try pinRecorder(id: item.id, in: host)
    let root = try XCTUnwrap(host.window?.contentView)
    let center = NSPoint(x: recorder.bounds.midX, y: recorder.bounds.midY)
    let point = recorder.convert(center, to: root.superview)
    XCTAssertTrue(root.hitTest(point) === recorder, "the real row hit-test chain cannot reach the shortcut recorder")
  }

  func testResignFirstResponderEndsRecordingWithoutClearingANewSession() throws {
    let first = pin("s", body: "focus-a")
    let second = pin("t", body: "focus-b")
    let host = try mount(VStack(spacing: 0) {
      HistoryItemView(item: first, previous: nil, next: second, index: 0)
      HistoryItemView(item: second, previous: first, next: nil, index: 1)
    }.frame(width: 420, height: 200))
    let firstRecorder = try pinRecorder(id: first.id, in: host)
    let secondRecorder = try pinRecorder(id: second.id, in: host)

    firstRecorder.mouseDown(with: try mouse(clickCount: 2, in: host))
    XCTAssertEqual(AppState.shared.pinRecordingItemID, first.id)
    XCTAssertTrue(host.window?.firstResponder === firstRecorder)

    secondRecorder.mouseDown(with: try mouse(clickCount: 2, in: host))
    XCTAssertEqual(
      AppState.shared.pinRecordingItemID,
      second.id,
      "the previous recorder resign cleared the new recording"
    )
    XCTAssertTrue(host.window?.firstResponder === secondRecorder)

    let sinkWindow = host.window
    XCTAssertTrue(sinkWindow?.makeFirstResponder(nil) ?? false, "focus did not leave the recorder")
    XCTAssertFalse(sinkWindow?.firstResponder === secondRecorder)
    XCTAssertNil(AppState.shared.pinRecordingItemID, "leaving the recorder left recording active")
    XCTAssertEqual(first.item.pin, "s")
    XCTAssertEqual(second.item.pin, "t")
  }

  func testCommitDropsRecorderAsFirstResponder() throws {
    let item = pin("s", body: "resign-after-save")
    let host = try mount(HistoryItemView(item: item, previous: nil, next: nil, index: 0).frame(width: 420, height: 90))
    let recorder = try pinRecorder(id: item.id, in: host)
    recorder.mouseDown(with: try mouse(clickCount: 2, in: host))
    XCTAssertTrue(recorder.performKeyEquivalent(with: try key("l", code: 37, flags: .command)))
    XCTAssertEqual(item.item.pin, "l")
    XCTAssertNil(AppState.shared.pinRecordingItemID)
    XCTAssertFalse(
      host.window?.firstResponder is PinnedShortcutRecorder,
      "the recorder stayed first responder after recording ended"
    )
  }

  func testRecordingPromptIsVisibleAndSurvivesRedraw() throws {
    let item = pin("s", body: "visible-prompt")
    let host = try mount(HistoryItemView(item: item, previous: nil, next: nil, index: 0).frame(width: 420, height: 90))
    let recorder = try pinRecorder(id: item.id, in: host)
    let slot = try XCTUnwrap(find("lab-row-shortcuts-\(item.id.uuidString)", in: host))
    recorder.mouseDown(with: try mouse(clickCount: 2, in: host))

    let prompt = try visiblePrompt(in: recorder)
    XCTAssertFalse(prompt.isHidden)
    XCTAssertGreaterThan(prompt.alphaValue, 0.5)
    XCTAssertFalse(prompt.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    XCTAssertLessThanOrEqual(slot.bounds.width, 56.5, "the prompt widened the shortcut slot")
    XCTAssertNil(prompt.hitTest(NSPoint(x: 1, y: 1)))

    XCTAssertTrue(recorder.keyDownConsumed(try key("1", code: 18, flags: .command)))
    recorder.configure(
      itemID: item.id,
      pinned: true,
      recording: AppState.shared.pinRecordingItemID == item.id,
      message: AppState.shared.pinShortcutMessage(for: item.id),
      error: AppState.shared.pinShortcutError(for: item.id)
    )
    let redrawn = try visiblePrompt(in: recorder)
    XCTAssertFalse(
      redrawn.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      "SwiftUI redraw cleared the recording prompt"
    )
    XCTAssertNotEqual(redrawn.stringValue, item.item.pin, "the static shortcut label covered the prompt")
  }

  func testLocalizedPinAndEditCopyExistsInChineseAndEnglish() throws {
    let zh = try String(contentsOfFile: labStrings("zh-Hans"), encoding: .utf8)
    let en = try String(contentsOfFile: labStrings("en"), encoding: .utf8)
    for key in [
      "pin_shortcut_retry", "pin_shortcut_illegal", "pin_shortcut_conflict",
      "row_shortcut_help", "row_shortcut_help_disabled",
      "edit_blank", "edit_conflict", "edit_stale",
      "edit_refused_file", "edit_refused_image", "edit_refused_rich"
    ] {
      XCTAssertTrue(zh.contains("\"\(key)\""), "zh-Hans missing \(key)")
      XCTAssertTrue(en.contains("\"\(key)\""), "en missing \(key)")
    }
    XCTAssertTrue(zh.contains("请按"))
    // Shipped contract is the short slot copy, not the old long phrases.
    // Those phrases remain only as NSLocalizedString fallbacks in HistoryShortcutSlotCopy.
    // Replacement: row_shortcut_help / row_shortcut_help_disabled in en + zh-Hans.
    XCTAssertTrue(zh.contains("\"row_shortcut_help\" = \"快捷键\""))
    XCTAssertTrue(zh.contains("\"row_shortcut_help_disabled\" = \"先置顶\""))
    XCTAssertFalse(zh.contains("双击录制"), "old double-click phrase is not the shipped contract")
    XCTAssertFalse(zh.contains("先置顶，才能录制"))
    XCTAssertTrue(en.contains("\"row_shortcut_help\" = \"Shortcut\""))
    XCTAssertTrue(en.contains("\"row_shortcut_help_disabled\" = \"Pin first\""))
    XCTAssertFalse(en.contains("Double-click to record a pin shortcut"))
    XCTAssertFalse(en.contains("Pin this item before recording a shortcut"))
    let pinnedCopy = HistoryShortcutSlotCopy.text(pinned: true)
    let unpinnedCopy = HistoryShortcutSlotCopy.text(pinned: false)
    XCTAssertTrue(pinnedCopy == "Shortcut" || pinnedCopy == "快捷键", pinnedCopy)
    XCTAssertTrue(unpinnedCopy == "Pin first" || unpinnedCopy == "先置顶", unpinnedCopy)
    XCTAssertFalse(en.contains("双击录制"))
    XCTAssertTrue(zh.contains("仅限"))
    XCTAssertTrue(zh.contains("已占用"))
    XCTAssertTrue(zh.contains("保存"))
    XCTAssertTrue(zh.contains("取消"))
    XCTAssertFalse(en.contains("请按"))
  }

  func testUnpinnedShortcutSlotConsumesClicksWithoutCopy() throws {
    let loose = history.add(textItem("loose-hit"))
    var copies = 0
    Clipboard.shared.copyProbe = { _, _ in copies += 1 }
    let host = try mount(HistoryItemView(item: loose, previous: nil, next: nil, index: 0).frame(width: 420, height: 90))
    let recorder = try pinRecorder(id: loose.id, in: host)
    let slot = try XCTUnwrap(recorder.superview as? HistoryShortcutSlotView)
    XCTAssertEqual(slot.toolTip, HistoryShortcutSlotCopy.text(pinned: false))
    XCTAssertEqual(recorder.toolTip, slot.toolTip)
    XCTAssertFalse(slot.toolTip?.isEmpty ?? true)
    let root = try XCTUnwrap(host.window?.contentView)
    let center = NSPoint(x: recorder.bounds.midX, y: recorder.bounds.midY)
    let point = recorder.convert(center, to: root.superview)
    let hit = root.hitTest(point)
    XCTAssertTrue(
      hit === slot || hit === recorder,
      "unpinned shortcut slot let the click through to \(String(describing: type(of: hit)))"
    )
    let event = try mouse(clickCount: 2, at: point, in: host)
    hit?.mouseDown(with: event)
    XCTAssertEqual(copies, 0, "unpinned shortcut click copied the row")
    XCTAssertNil(AppState.shared.pinRecordingItemID)
    XCTAssertNil(loose.item.pin)
    XCTAssertFalse(recorder.accessibilityPerformPress())
    XCTAssertFalse(recorder.isAccessibilityEnabled())
  }

  func testPinnedShortcutSlotTooltipDoesNotStealTheDoubleClick() throws {
    let item = pin("s", body: "slot-tip-pinned")
    var copies = 0
    Clipboard.shared.copyProbe = { _, _ in copies += 1 }
    let host = try mount(HistoryItemView(item: item, previous: nil, next: nil, index: 0).frame(width: 420, height: 90))
    let recorder = try pinRecorder(id: item.id, in: host)
    let slot = try XCTUnwrap(recorder.superview as? HistoryShortcutSlotView)
    XCTAssertEqual(slot.toolTip, HistoryShortcutSlotCopy.text(pinned: true))
    XCTAssertEqual(recorder.toolTip, slot.toolTip)
    XCTAssertNotEqual(slot.toolTip, HistoryShortcutSlotCopy.text(pinned: false))
    recorder.mouseDown(with: try mouse(clickCount: 1, in: host))
    XCTAssertNil(AppState.shared.pinRecordingItemID, "a tooltip-bearing slot started recording on a single click")
    XCTAssertEqual(copies, 0)
    recorder.mouseDown(with: try mouse(clickCount: 2, in: host))
    XCTAssertEqual(AppState.shared.pinRecordingItemID, item.id)
    XCTAssertEqual(copies, 0, "double-click on the shortcut slot copied the row")
  }

  func testBodyEscapeRevertsAndEnterKeepsTheStoredTitle() throws {
    let item = pin("s", body: "title-keys")
    var copies = 0
    Clipboard.shared.copyProbe = { _, _ in copies += 1 }
    let host = try mount(OriginalTextEditSection(item: item).frame(width: 360, height: 220))
    XCTAssertNil(find("lab-preview-title", in: host))
    let body = try beginEdit("lab-preview-edit-body", in: host)
    body.insertText("改过的正文", replacementRange: NSRange(location: 0, length: body.string.utf16.count))
    body.didChangeText()
    drain(0.05)
    try cancelEdit(body)
    XCTAssertEqual(copies, 0, "body escape copied the item")
    XCTAssertEqual(item.item.text, "title-keys")
    XCTAssertEqual(item.item.title, "title-keys", "escape changed the stored title")
    XCTAssertFalse(host.window?.isVisible ?? true)

    let again = try beginEdit("lab-preview-edit-body", in: host)
    again.insertText("保存正文", replacementRange: NSRange(location: 0, length: again.string.utf16.count))
    again.didChangeText()
    drain(0.05)
    try submit(again)
    XCTAssertEqual(item.item.text, "保存正文")
    XCTAssertEqual(item.item.title, "title-keys", "body submit changed the stored title")
    XCTAssertEqual(item.item.pin, "s")
    XCTAssertEqual(copies, 0)
    XCTAssertFalse(host.window?.firstResponder === again, "save left the body editor focused")
  }

  func testDedupMigratesLiveDraftAndUnloadRejectsRemovedID() throws {
    let item = pin("s", body: "same-body")
    let host = try mount(OriginalTextEditSection(item: item).frame(width: 360, height: 220))
    let body = try beginEdit("lab-preview-edit-body", in: host)
    body.insertText("dirty-draft", replacementRange: NSRange(location: 0, length: body.string.utf16.count))
    body.didChangeText()
    drain(0.05)

    let incoming = textItem("same-body")
    let survivor = history.add(incoming)
    XCTAssertNotEqual(survivor.id, item.id)
    XCTAssertEqual(AppState.shared.textDraft(for: survivor.id)?.body, "dirty-draft")
    XCTAssertNil(AppState.shared.textDraft(for: item.id))

    _ = try mount(Text("gone").frame(width: 40, height: 20))
    drain(0.05)
    XCTAssertNil(AppState.shared.textDraft(for: item.id), "late unload retained the removed id")
    XCTAssertEqual(AppState.shared.textDraft(for: survivor.id)?.body, "dirty-draft")
  }

  func testSaveRefusesMovedBaselineAndStaleSaveLeavesDeletedBytes() throws {
    let item = pin("s", body: "v1")
    let host = try mount(OriginalTextEditSection(item: item).frame(width: 360, height: 220))
    let body = try beginEdit("lab-preview-edit-body", in: host)
    body.insertText("draft-v3", replacementRange: NSRange(location: 0, length: body.string.utf16.count))
    body.didChangeText()
    drain(0.05)
    item.item.contents.first(where: { $0.type == NSPasteboard.PasteboardType.string.rawValue })?.value = Data("v2".utf8)
    try submit(body)
    XCTAssertEqual(item.item.text, "v2", "save overwrote a concurrent body change")
    XCTAssertEqual(AppState.shared.textDraft(for: item.id)?.body, "draft-v3")
    let error = try XCTUnwrap(
      find("lab-preview-edit-error", in: host) as? NSTextField,
      errorMiss(in: host, itemID: item.id)
    )
    XCTAssertFalse(error.stringValue.isEmpty, "baseline conflict had no feedback")

    let doomed = pin("k", body: "do-not-touch")
    history.delete(doomed)
    let titleAfterDelete = doomed.item.title
    let textAfterDelete = doomed.item.text
    XCTAssertNil(AppState.shared.textDraft(for: doomed.id), "explicit delete kept the draft")
    AppState.shared.retainTextDraft(OriginalTextDraft(title: "late", body: "late"), itemID: doomed.id)
    XCTAssertNil(AppState.shared.textDraft(for: doomed.id), "retain accepted a removed id")
    let outcome = AppState.shared.saveOriginalText(
      itemID: doomed.id,
      draft: OriginalTextDraft(title: "nope", body: "nope")
    )
    XCTAssertNotEqual(outcome, .saved)
    XCTAssertFalse(AppState.shared.textEditError(for: doomed.id)?.isEmpty ?? true, "stale save gave no feedback")
    XCTAssertEqual(doomed.item.title, titleAfterDelete)
    XCTAssertEqual(doomed.item.text, textAfterDelete)
  }

  func testSaveSyncsPlainTextAliasAndRestoresOnFailure() throws {
    let aliasType = "public.utf16-plain-text"
    let raw = HistoryItem(contents: [
      HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data("old".utf8)),
      HistoryItemContent(type: aliasType, value: "old-alias".data(using: .utf16))
    ])
    raw.pin = "s"
    raw.title = "alias"
    Storage.shared.context.insert(raw)
    let item = history.add(raw)
    XCTAssertNil(OriginalTextEdit.refusal(for: item.item))
    let saved = AppState.shared.saveOriginalText(
      itemID: item.id,
      draft: OriginalTextDraft(title: "alias", body: "new-body")
    )
    XCTAssertEqual(saved, .saved)
    XCTAssertEqual(payload(aliasType, in: item.item), "new-body".data(using: .utf16))
    XCTAssertEqual(OriginalTextEdit.stringBytes(in: item.item), Data("new-body".utf8))

    Storage.shared.saveImplementation = { throw CocoaError(.fileWriteUnknown) }
    let failed = AppState.shared.saveOriginalText(
      itemID: item.id,
      draft: OriginalTextDraft(title: "alias", body: "should-roll-back")
    )
    if case .failed = failed {
    } else {
      XCTFail("expected failure, got \(failed)")
    }
    XCTAssertEqual(payload(aliasType, in: item.item), "new-body".data(using: .utf16))
    XCTAssertEqual(OriginalTextEdit.stringBytes(in: item.item), Data("new-body".utf8))
    XCTAssertEqual(AppState.shared.textDraft(for: item.id)?.body, "should-roll-back")
  }

  func testOfficialPanelRoutesPinCommandLetterAheadOfQuit() throws {
    let item = pin("q", body: "pin-q")
    AppState.shared.navigator.select(item: nil)
    var copies = 0
    Clipboard.shared.copyProbe = { _, _ in copies += 1 }
    let delegate = AppDelegate()
    let previous = AppState.shared.appDelegate
    let previousPanel = previous?.panel
    let panel = SealedShortcutPanel(
      contentRect: NSRect(x: -24000, y: -24000, width: 320, height: 180),
      identifier: "lab-pin-route",
      onClose: {}
    ) { ContentView() }
    AppState.shared.appDelegate = delegate
    delegate.panel = panel
    defer {
      panel.close()
      delegate.panel = nil
      AppState.shared.appDelegate = previous
      previous?.panel = previousPanel
      AppState.shared.panelPresented = false
    }
    AppState.shared.panelPresented = true
    let quit = AppState.shared.footer.items.first { $0.title == "quit" }
    quit?.showConfirmation = false
    AppState.shared.quitAuthorized = false

    let eaten = panel.performKeyEquivalent(with: try key("q", code: 12, flags: .command))
    XCTAssertTrue(eaten, "the official panel did not consume Command+Q for the pin")
    XCTAssertFalse(quit?.showConfirmation ?? false, "Command+Q started quit instead of the pin")
    XCTAssertFalse(AppState.shared.quitAuthorized)
    XCTAssertGreaterThan(copies, 0, "the pin letter did not copy")
    XCTAssertEqual(item.item.pin, "q")
    XCTAssertFalse(panel.isVisible)
    XCTAssertFalse(panel.isKeyWindow)
  }

  func testRecordingCommandQDoesNotQuit() throws {
    let item = pin("s", body: "recording-q")
    let delegate = AppDelegate()
    let previous = AppState.shared.appDelegate
    let previousPanel = previous?.panel
    let panel = SealedShortcutPanel(
      contentRect: NSRect(x: -24000, y: -24000, width: 320, height: 180),
      identifier: "lab-record-q",
      onClose: {}
    ) { ContentView() }
    AppState.shared.appDelegate = delegate
    delegate.panel = panel
    defer {
      panel.close()
      delegate.panel = nil
      AppState.shared.appDelegate = previous
      previous?.panel = previousPanel
      AppState.shared.panelPresented = false
    }
    let shell = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
    panel.contentView = shell
    let recorder = PinnedShortcutRecorder()
    recorder.itemID = item.id
    recorder.pinned = true
    recorder.onBegin = { AppState.shared.beginPinRecording(itemID: $0) }
    recorder.onCancel = { AppState.shared.cancelPinRecording(itemID: $0) }
    recorder.onCommit = { AppState.shared.commitPinLetter($1, itemID: $0) }
    recorder.sessionActive = { AppState.shared.pinRecordingItemID == $0 }
    recorder.frame = NSRect(x: 0, y: 0, width: 56, height: 56)
    shell.addSubview(recorder)
    recorder.mouseDown(with: try mouse(clickCount: 2, in: shell))
    XCTAssertTrue(panel.makeFirstResponder(recorder))
    AppState.shared.panelPresented = true
    let quit = AppState.shared.footer.items.first { $0.title == "quit" }
    quit?.showConfirmation = false

    XCTAssertTrue(panel.performKeyEquivalent(with: try key("q", code: 12, flags: .command)))
    XCTAssertFalse(quit?.showConfirmation ?? false)
    XCTAssertFalse(AppState.shared.quitAuthorized)
    XCTAssertEqual(item.item.pin, "q")
  }

  func testImageStateCoversTheImageNotOnlyATopStrip() throws {
    let item = imageItem("covered")
    let canvas = NSImage(size: NSSize(width: 80, height: 40))
    canvas.lockFocus()
    NSColor.systemGreen.setFill()
    NSRect(x: 0, y: 0, width: 80, height: 40).fill()
    canvas.unlockFocus()
    item.thumbnailImage = canvas
    AppState.shared.navigator.select(item: item)
    let host = try mount(HistoryItemView(item: item, previous: nil, next: nil, index: 0).frame(width: 420, height: 90))
    let mark = try XCTUnwrap(find("lab-row-image-state-\(item.id.uuidString)", in: host) as? ImageStateMarkView)
    let image = try XCTUnwrap(find("lab-row-preview-\(item.id.uuidString)", in: host))
    XCTAssertNil(mark.hitTest(NSPoint(x: 2, y: 2)))
    let markFrame = mark.convert(mark.bounds, to: nil)
    let imageFrame = image.convert(image.bounds, to: nil)
    XCTAssertGreaterThan(mark.bounds.height, 20, "image state is still a top strip")
    XCTAssertTrue(markFrame.intersects(imageFrame))
    XCTAssertLessThan(abs(markFrame.height - imageFrame.height), 8)
    let pixels = try XCTUnwrap(bitmap(mark))
    let edge = try XCTUnwrap(pixels.colorAt(x: 2, y: 2))
    let center = try XCTUnwrap(pixels.colorAt(x: pixels.pixelsWide / 2, y: pixels.pixelsHigh / 2))
    XCTAssertGreaterThan(edge.alphaComponent, 0.2, "image state did not draw a visible edge")
    XCTAssertGreaterThan(center.alphaComponent, 0.05, "image state did not tint the image")
    XCTAssertLessThan(center.alphaComponent, 0.45, "image state covered the image")
  }

  /// Editable plain body must follow the same wrap flag the toolbar owns.
  /// A short fixture cannot show this: the line has to exceed the viewport.
  func testEditablePlainBodyAppliesWrapOffAndBack() throws {
    let long = String(repeating: "QAWRAP ", count: 24)
    XCTAssertFalse(long.contains("\n"))
    let decorator = history.add(textItem(long))
    let flag = WrapFlag()
    flag.wraps = false
    let host = try mount(
      WrapToggleHarness(item: decorator, flag: flag)
        .frame(width: 280, height: 200)
    )
    let body = try textView("lab-preview-edit-body", in: host)
    XCTAssertEqual(body.string, long)
    XCTAssertFalse(body.textContainer?.widthTracksTextView ?? true, "wrap off did not reach the editor")
    XCTAssertTrue(body.isHorizontallyResizable)
    XCTAssertEqual(body.enclosingScrollView?.hasHorizontalScroller, true)
    XCTAssertEqual(fragmentCount(body), 1, "unwrapped long line still broke inside the viewport")

    let editing = try beginEdit("lab-preview-edit-body", in: host)
    let kept = NSRange(location: 2, length: 5)
    editing.setSelectedRange(kept)
    flag.wraps = true
    drain(0.25)
    host.layoutSubtreeIfNeeded()
    XCTAssertEqual(body.textContainer?.widthTracksTextView, true)
    XCTAssertFalse(body.isHorizontallyResizable)
    XCTAssertNotEqual(body.enclosingScrollView?.hasHorizontalScroller, true)
    XCTAssertGreaterThan(fragmentCount(body), 1, "wrap on did not reflow the long line")
    XCTAssertTrue(host.window?.firstResponder === editing, "wrap toggle resigned the editor")
    XCTAssertEqual(editing.selectedRange(), kept, "wrap toggle dropped the selection")
    XCTAssertEqual(editing.string, long, "wrap toggle replaced the draft")
    XCTAssertTrue(editing.isEditable)
    XCTAssertEqual(decorator.item.text, long, "wrap toggle rewrote stored text")
  }

  /// The toolbar only changes tint in a 448pt window when the longest line is ~38
  /// characters. A 200-character line must change real layout height, not just flags.
  func testWrapToggleChangesLayoutHeightOfATwoHundredCharacterLine() throws {
    let line = String(repeating: "换", count: 200)
    XCTAssertEqual(line.count, 200)
    XCTAssertFalse(line.contains("\n"))
    let decorator = history.add(textItem(line))
    let flag = WrapFlag()
    flag.wraps = true
    let host = try mount(
      WrapToggleHarness(item: decorator, flag: flag)
        .frame(width: 448, height: 240)
    )
    probe?.setFrame(NSRect(x: -24000, y: -24000, width: 448, height: 240), display: false)
    host.frame = NSRect(x: 0, y: 0, width: 448, height: 240)
    drain(0.05)
    host.layoutSubtreeIfNeeded()

    let body = try textView("lab-preview-edit-body", in: host)
    XCTAssertEqual(body.string, line)
    XCTAssertFalse(probe?.isVisible ?? true)
    XCTAssertFalse(probe?.isKeyWindow ?? true)
    XCTAssertLessThan(probe?.frame.maxX ?? 0, 0)

    let on = readWrapLayout(body)
    print("WRAP_GEOMETRY \(on.line(state: "on"))")
    XCTAssertGreaterThan(on.lineHeight, 0, "wrap on produced no line fragment: \(on.line(state: "on"))")
    XCTAssertGreaterThanOrEqual(on.fragments, 3, "wrap on did not break the 200-character line: \(on.line(state: "on"))")
    XCTAssertGreaterThanOrEqual(
      on.usedHeight,
      on.lineHeight * 3,
      "wrap on height is not at least 3 line-heights: \(on.line(state: "on"))"
    )
    XCTAssertLessThanOrEqual(
      on.usedWidth,
      448 + 2,
      "wrap on still drew wider than the 448pt viewport: \(on.line(state: "on"))"
    )

    flag.wraps = false
    drain(0.3)
    host.layoutSubtreeIfNeeded()
    let off = readWrapLayout(body)
    print("WRAP_GEOMETRY \(off.line(state: "off"))")
    XCTAssertEqual(body.string, line, "wrap toggle rewrote the line")
    XCTAssertEqual(off.fragments, 1, "wrap off still broke the line: \(off.line(state: "off"))")
    XCTAssertEqual(
      off.usedHeight,
      off.lineHeight,
      accuracy: 1,
      "wrap off height is not a single line: \(off.line(state: "off"))"
    )
    XCTAssertGreaterThan(off.usedWidth, 448, "wrap off did not stay wider than the 448pt viewport: \(off.line(state: "off"))")
    XCTAssertGreaterThan(
      on.usedHeight - off.usedHeight,
      off.lineHeight,
      "height did not drop when wrap turned off: on=\(on.line(state: "on")) off=\(off.line(state: "off"))"
    )
    XCTAssertGreaterThan(off.containerWidth, on.containerWidth, "wrap off container was not wider than wrap on")
    XCTAssertFalse(probe?.isVisible ?? true)
    XCTAssertLessThan(probe?.frame.maxX ?? 0, 0)
  }

  /// Constructor `wraps: false` must be one real line, not only container flags.
  /// Host stays at 200pt, the product tight preview floor. Do not go narrower.
  func testReadOnlyTextPreviewHonorsWrapOff() throws {
    let long = String(repeating: "FILEWRAP ", count: 20)
    XCTAssertFalse(long.contains("\n"))
    let render = PreviewTextRender(
      kind: .plain,
      languageLabel: "",
      monospace: false,
      display: long,
      full: long,
      truncated: false,
      lineCount: 1,
      attributed: NSAttributedString(string: long),
      structure: PreviewTextStructure(),
      lineNumbers: "1"
    )
    let host = try mount(
      SelectableTextPreview(render: render, wraps: false, showsLineNumbers: false)
        .frame(width: 200, height: 80)
    )
    probe?.setFrame(NSRect(x: -24000, y: -24000, width: 200, height: 80), display: false)
    host.frame = NSRect(x: 0, y: 0, width: 200, height: 80)
    drain(0.05)
    host.layoutSubtreeIfNeeded()

    let scroll = try XCTUnwrap(find("lab-text-preview", in: host) as? NSScrollView)
    let text = try XCTUnwrap(scroll.documentView as? NSTextView)
    XCTAssertNil(text.textLayoutManager, "file preview left TextKit 1")
    XCTAssertFalse(text.isEditable)
    XCTAssertFalse(text.textContainer?.widthTracksTextView ?? true)
    XCTAssertTrue(scroll.hasHorizontalScroller)
    XCTAssertFalse(probe?.isVisible ?? true)
    XCTAssertFalse(probe?.isKeyWindow ?? true)
    XCTAssertLessThan(probe?.frame.maxX ?? 0, 0)

    let opened = text.selectedRange()
    let off = readWrapLayout(text)
    let start = glyphMinXInViewport(text, scroll: scroll)
    print("WRAP_GEOMETRY \(off.line(state: "initial-off"))")
    print("GUTTER_SCROLL state=initial-off origin=\(scroll.contentView.bounds.origin) glyphMinX=\(start)")
    XCTAssertEqual(off.fragments, 1, "initial wrap off still broke the line: \(off.line(state: "initial-off"))")
    XCTAssertGreaterThan(off.lineHeight, 0, "initial wrap off produced no line fragment: \(off.line(state: "initial-off"))")
    XCTAssertEqual(
      off.usedHeight,
      off.lineHeight,
      accuracy: 1,
      "initial wrap off height is not a single line: \(off.line(state: "initial-off"))"
    )
    XCTAssertGreaterThan(off.viewportWidth, 1, "viewport was not installed: \(off.line(state: "initial-off"))")
    XCTAssertGreaterThan(off.usedWidth, off.viewportWidth, "initial wrap off did not exceed the viewport: \(off.line(state: "initial-off"))")
    XCTAssertGreaterThan(off.usedWidth, 200, "initial wrap off stayed inside the 200pt host: \(off.line(state: "initial-off"))")
    XCTAssertEqual(text.string, long, "initial wrap off rewrote the text")
    XCTAssertFalse(text.string.hasPrefix("1"), "line-number prefix was written into storage")
    XCTAssertFalse(text.string.contains("\n"), "initial wrap off inserted a line break")
    XCTAssertEqual(text.selectedRange(), opened, "initial layout changed the selection")
    XCTAssertGreaterThanOrEqual(start, -1, "line start was outside the viewport: \(start)")
    XCTAssertEqual(scroll.contentView.bounds.origin.x, 0, accuracy: 1)

    let kept = NSRange(location: 2, length: 5)
    text.setSelectedRange(kept)
    drain(0.05)
    host.layoutSubtreeIfNeeded()
    let again = readWrapLayout(text)
    XCTAssertEqual(again.fragments, 1, "relayout broke the initial-off line: \(again.line(state: "relayout"))")
    XCTAssertGreaterThan(again.usedWidth, again.viewportWidth, "relayout no longer exceeded the viewport: \(again.line(state: "relayout"))")
    XCTAssertEqual(text.string, long, "relayout rewrote the text")
    XCTAssertEqual(text.selectedRange(), kept, "relayout dropped the selection")
    XCTAssertTrue(scroll.documentView === text, "relayout replaced the text view")
    XCTAssertFalse(probe?.isVisible ?? true)
    XCTAssertFalse(probe?.isKeyWindow ?? true)
    XCTAssertLessThan(probe?.frame.maxX ?? 0, 0)
  }

  /// File previews mount SelectableTextPreview, not the editable body.
  /// Flag flips are not layout. A long line must change line fragments.
  func testSelectableTextPreviewWrapOffChangesLineFragments() throws {
    let line = String(repeating: "换", count: 80)
    XCTAssertFalse(line.contains("\n"))
    let render = PreviewTextRenderer.render(text: line, filename: "qa-positive-format.swift", mode: .code)
    XCTAssertEqual(render.kind, .code)
    let flag = SelectableWrapFlag()
    flag.wraps = true
    let host = try mount(
      SelectableWrapHarness(render: render, flag: flag, showsLineNumbers: false)
        .frame(width: 448, height: 180)
    )
    probe?.setFrame(NSRect(x: -24000, y: -24000, width: 448, height: 180), display: false)
    host.frame = NSRect(x: 0, y: 0, width: 448, height: 180)
    drain(0.05)
    host.layoutSubtreeIfNeeded()
    let scroll = try XCTUnwrap(find("lab-text-preview", in: host) as? NSScrollView)
    let text = try XCTUnwrap(scroll.documentView as? NSTextView)
    XCTAssertNil(text.textLayoutManager, "file preview left TextKit 1")
    XCTAssertFalse(probe?.isVisible ?? true)
    XCTAssertFalse(probe?.isKeyWindow ?? true)
    let on = readWrapLayout(text)
    XCTAssertGreaterThanOrEqual(on.fragments, 2, "wrap on did not break the long line: \(on.line(state: "on"))")
    XCTAssertLessThanOrEqual(on.usedWidth, 448 + 8, "wrap on drew wider than the viewport: \(on.line(state: "on"))")
    let kept = NSRange(location: 3, length: 4)
    text.setSelectedRange(kept)
    let origin = scroll.contentView.bounds.origin
    flag.wraps = false
    drain(0.3)
    host.layoutSubtreeIfNeeded()
    XCTAssertTrue(scroll.documentView === text, "wrap toggle replaced the text view")
    let off = readWrapLayout(text)
    XCTAssertEqual(off.fragments, 1, "wrap off still broke the line: \(off.line(state: "off"))")
    XCTAssertGreaterThan(off.usedWidth, 448, "wrap off did not exceed the viewport: \(off.line(state: "off"))")
    XCTAssertGreaterThan(off.containerWidth, on.containerWidth, "wrap off did not widen the container")
    XCTAssertEqual(text.selectedRange(), kept, "wrap toggle dropped the selection")
    XCTAssertEqual(text.string, line, "wrap toggle rewrote the text")
    XCTAssertEqual(scroll.contentView.bounds.origin.x, origin.x, accuracy: 1)
    flag.wraps = true
    drain(0.3)
    host.layoutSubtreeIfNeeded()
    let back = readWrapLayout(text)
    XCTAssertGreaterThanOrEqual(back.fragments, 2, "wrap on again did not reflow: \(back.line(state: "back"))")
    XCTAssertEqual(text.selectedRange(), kept)
    XCTAssertTrue(scroll.documentView === text)
  }

  /// Line numbers are glyphs in the same storage, not a separate ruler.
  /// Wrap off can scroll that gutter out. Wrap on hides the horizontal scroller,
  /// so a restored horizontal origin leaves the prefix outside the viewport.
  func testSelectableTextPreviewWrapOnRestoresLineNumberGutter() throws {
    let line = "// " + String(repeating: "不被执行。", count: 16)
    XCTAssertFalse(line.contains("\n"))
    let render = PreviewTextRenderer.render(text: line, filename: "qa-positive-format.swift", mode: .code)
    XCTAssertEqual(render.kind, .code)
    XCTAssertFalse(render.lineNumbers.isEmpty)
    let flag = SelectableWrapFlag()
    flag.wraps = true
    let host = try mount(
      SelectableWrapHarness(render: render, flag: flag, showsLineNumbers: true)
        .frame(width: 448, height: 180)
    )
    probe?.setFrame(NSRect(x: -24000, y: -24000, width: 448, height: 180), display: false)
    host.frame = NSRect(x: 0, y: 0, width: 448, height: 180)
    drain(0.05)
    host.layoutSubtreeIfNeeded()
    let scroll = try XCTUnwrap(find("lab-text-preview", in: host) as? NSScrollView)
    let text = try XCTUnwrap(scroll.documentView as? NSTextView)
    XCTAssertNil(text.textLayoutManager, "file preview left TextKit 1")
    XCTAssertFalse(probe?.isVisible ?? true)
    XCTAssertFalse(probe?.isKeyWindow ?? true)
    XCTAssertTrue(text.string.hasPrefix("1"), "line numbers were not written into storage")
    let on = readWrapLayout(text)
    let openedGutter = glyphMinXInViewport(text, scroll: scroll)
    print("GUTTER_SCROLL \(on.line(state: "on")) origin=\(scroll.contentView.bounds.origin) gutterMinX=\(openedGutter)")
    XCTAssertGreaterThanOrEqual(on.fragments, 2, "wrap on did not break the long line: \(on.line(state: "on"))")
    XCTAssertLessThanOrEqual(on.usedWidth, 448 + 8, "wrap on drew wider than the viewport: \(on.line(state: "on"))")
    XCTAssertGreaterThanOrEqual(openedGutter, -1, "line number prefix was not in the viewport on open: \(openedGutter)")

    flag.wraps = false
    drain(0.3)
    host.layoutSubtreeIfNeeded()
    XCTAssertTrue(scroll.documentView === text, "wrap toggle replaced the text view")
    let off = readWrapLayout(text)
    print("GUTTER_SCROLL \(off.line(state: "off")) frame=\(text.frame.size) origin=\(scroll.contentView.bounds.origin)")
    XCTAssertLessThan(off.fragments, on.fragments, "wrap off did not un-break the line: \(off.line(state: "off"))")
    XCTAssertGreaterThan(off.usedWidth, 448, "wrap off did not exceed the viewport: \(off.line(state: "off"))")
    XCTAssertTrue(scroll.hasHorizontalScroller)
    XCTAssertEqual(text.string.hasPrefix("1"), true, "wrap off rewrote storage")

    let visible = scroll.contentView.bounds.width
    let document = max(text.frame.width, text.bounds.width)
    let targetX = max(document, off.usedWidth + text.textContainerOrigin.x) - visible
    XCTAssertGreaterThan(
      targetX,
      8,
      "wrap off document was not wider than the viewport: frame=\(text.frame.size) used=\(off.usedWidth) visible=\(visible)"
    )
    let vertical = scroll.contentView.bounds.origin.y
    scroll.contentView.scroll(to: NSPoint(x: targetX, y: vertical))
    scroll.reflectScrolledClipView(scroll.contentView)
    let scrolled = scroll.contentView.bounds.origin
    let hidden = glyphMinXInViewport(text, scroll: scroll)
    print("GUTTER_SCROLL state=scrolled origin=\(scrolled) gutterMinX=\(hidden) document=\(document) target=\(targetX)")
    XCTAssertGreaterThan(scrolled.x, 1, "contentView scroll did not leave a non-zero horizontal origin")
    XCTAssertLessThan(hidden, -1, "horizontal scroll did not push the line-number prefix out of the viewport: \(hidden)")
    let kept = NSRange(location: 4, length: 2)
    text.setSelectedRange(kept)
    XCTAssertEqual(text.selectedRange(), kept)
    XCTAssertGreaterThan(scroll.contentView.bounds.origin.x, 1, "setting the selection cleared the horizontal scroll")

    flag.wraps = true
    drain(0.3)
    host.layoutSubtreeIfNeeded()
    let back = readWrapLayout(text)
    let restored = scroll.contentView.bounds.origin
    let gutter = glyphMinXInViewport(text, scroll: scroll)
    print("GUTTER_SCROLL \(back.line(state: "restored")) origin=\(restored) gutterMinX=\(gutter) containerOrigin=\(text.textContainerOrigin)")
    XCTAssertTrue(scroll.documentView === text, "wrap on replaced the text view")
    XCTAssertNil(text.textLayoutManager, "wrap on left TextKit 1")
    XCTAssertFalse(scroll.hasHorizontalScroller, "wrap on left a horizontal scroller, so a leftover origin cannot be recovered")
    XCTAssertGreaterThanOrEqual(back.fragments, 2, "wrap on again did not reflow: \(back.line(state: "restored"))")
    XCTAssertLessThanOrEqual(back.usedWidth, max(on.usedWidth, 448) + 8, "wrap on again stayed wider than the viewport: \(back.line(state: "restored"))")
    XCTAssertEqual(text.selectedRange(), kept, "wrap on dropped the selection")
    XCTAssertTrue(text.string.hasPrefix("1"), "wrap on dropped the line-number prefix from storage")
    XCTAssertTrue(text.string.contains(line), "wrap on rewrote the preview text")
    XCTAssertEqual(
      restored.x,
      0,
      accuracy: 1,
      "wrap on kept the horizontal origin and hid the line-number gutter: origin=\(restored) gutterMinX=\(gutter)"
    )
    XCTAssertEqual(restored.y, vertical, accuracy: 1, "wrap on discarded the vertical origin")
    XCTAssertGreaterThanOrEqual(
      gutter,
      -1,
      "line-number prefix stayed outside the viewport after wrap on: gutterMinX=\(gutter) origin=\(restored)"
    )
    XCTAssertLessThan(gutter, scroll.contentView.bounds.width, "line-number prefix was not inside the viewport: gutterMinX=\(gutter)")
    XCTAssertFalse(probe?.isVisible ?? true)
    XCTAssertLessThan(probe?.frame.maxX ?? 0, 0)
  }

  func testSelectableTextPreviewInitialOffWidthAndKinds() throws {
    let chinese = String(repeating: "注", count: 70)
    let plain = PreviewTextRenderer.render(text: chinese, filename: "note.txt", mode: .plain)
    XCTAssertEqual(plain.kind, .plain)
    let offFlag = SelectableWrapFlag()
    offFlag.wraps = false
    let host = try mount(
      SelectableWrapHarness(render: plain, flag: offFlag, showsLineNumbers: false)
        .frame(width: 448, height: 140)
    )
    probe?.setFrame(NSRect(x: -24000, y: -24000, width: 448, height: 140), display: false)
    host.frame = NSRect(x: 0, y: 0, width: 448, height: 140)
    drain(0.05)
    host.layoutSubtreeIfNeeded()
    let scroll = try XCTUnwrap(find("lab-text-preview", in: host) as? NSScrollView)
    let text = try XCTUnwrap(scroll.documentView as? NSTextView)
    XCTAssertNil(text.textLayoutManager)
    let initial = readWrapLayout(text)
    XCTAssertEqual(initial.fragments, 1, "initial wrap off still broke: \(initial.line(state: "initial"))")
    XCTAssertGreaterThan(initial.usedWidth, 448, "initial wrap off stayed inside 448: \(initial.line(state: "initial"))")

    offFlag.wraps = true
    offFlag.width = 220
    drain(0.25)
    host.layoutSubtreeIfNeeded()
    let narrow = readWrapLayout(text)
    offFlag.width = 448
    drain(0.25)
    host.layoutSubtreeIfNeeded()
    let wide = readWrapLayout(text)
    XCTAssertGreaterThan(narrow.fragments, wide.fragments, "narrow=\(narrow.line(state: "narrow")) wide=\(wide.line(state: "wide"))")

    for (mode, name) in [(PreviewTextMode.markdown, "note.md"), (.code, "qa-positive-format.swift")] {
      let render = PreviewTextRenderer.render(text: chinese, filename: name, mode: mode)
      let flag = SelectableWrapFlag()
      flag.wraps = true
      let mounted = try mount(
        SelectableWrapHarness(render: render, flag: flag, showsLineNumbers: mode == .code)
          .frame(width: 448, height: 160)
      )
      mounted.frame = NSRect(x: 0, y: 0, width: 448, height: 160)
      drain(0.05)
      mounted.layoutSubtreeIfNeeded()
      let kindScroll = try XCTUnwrap(find("lab-text-preview", in: mounted) as? NSScrollView)
      let kindText = try XCTUnwrap(kindScroll.documentView as? NSTextView)
      XCTAssertNil(kindText.textLayoutManager)
      let wrapped = readWrapLayout(kindText)
      XCTAssertGreaterThanOrEqual(wrapped.fragments, 2, "\(mode) wrap on: \(wrapped.line(state: "on"))")
      flag.wraps = false
      drain(0.25)
      mounted.layoutSubtreeIfNeeded()
      let unwrapped = readWrapLayout(kindText)
      XCTAssertGreaterThan(unwrapped.usedWidth, wrapped.usedWidth, "\(mode) wrap off did not widen: \(unwrapped.line(state: "off"))")
      XCTAssertLessThan(unwrapped.usedHeight, wrapped.usedHeight, "\(mode) wrap off did not shorten: \(unwrapped.line(state: "off"))")
      XCTAssertTrue(kindScroll.documentView === kindText)
    }
    XCTAssertFalse(probe?.isVisible ?? true)
    XCTAssertLessThan(probe?.frame.maxX ?? 0, 0)
  }

  /// Code opens unwrapped, so the text view has already grown to the full
  /// line width. Turning wrap on must fold it back to the viewport; a view
  /// left at the old width keeps one endless line.
  func testCodeOpenedUnwrappedFoldsWhenWrapIsTurnedOn() throws {
    let line = "(function(){'use strict';" + String(repeating: "var a=b.c(d,e)||f;", count: 900) + "})();"
    let render = PreviewTextRenderer.render(text: line, filename: "course.js", mode: .code)
    XCTAssertEqual(render.kind, .code)
    let flag = SelectableWrapFlag()
    flag.wraps = false
    let host = try mount(
      SelectableWrapHarness(render: render, flag: flag, showsLineNumbers: true)
        .frame(width: 448, height: 180)
    )
    probe?.setFrame(NSRect(x: -24000, y: -24000, width: 448, height: 180), display: false)
    host.frame = NSRect(x: 0, y: 0, width: 448, height: 180)
    drain(0.05)
    host.layoutSubtreeIfNeeded()
    let scroll = try XCTUnwrap(find("lab-text-preview", in: host) as? NSScrollView)
    let text = try XCTUnwrap(scroll.documentView as? NSTextView)
    let off = readWrapLayout(text)
    XCTAssertGreaterThan(off.usedWidth, 2_000, "fixture did not open as one long line: \(off.line(state: "off"))")

    flag.wraps = true
    drain(0.3)
    host.layoutSubtreeIfNeeded()
    let on = readWrapLayout(text)
    XCTAssertGreaterThanOrEqual(on.fragments, 10, "wrap on did not fold the long line: \(on.line(state: "on"))")
    XCTAssertLessThanOrEqual(on.usedWidth, 448 + 8, "wrap on stayed wider than the viewport: \(on.line(state: "on"))")
    XCTAssertLessThanOrEqual(text.frame.width, 448 + 8, "text view kept the unwrapped width: \(text.frame.width)")
  }

  /// Hiding line numbers and switching plain↔code can keep the same characters.
  /// String equality must not freeze the previous font, color, or paragraph style.
  func testSelectableTextPreviewSameStringFollowsRenderAttributes() throws {
    let body = String(repeating: "W", count: 16) + String(repeating: "样", count: 36)
    XCTAssertFalse(body.contains("\n"))
    let first = styleRender(
      body,
      size: 13,
      color: NSColor(srgbRed: 0.86, green: 0.12, blue: 0.10, alpha: 1),
      alignment: .left,
      spacing: 0,
      indent: 0,
      fixed: false
    )
    let second = styleRender(
      body,
      size: 22,
      color: NSColor(srgbRed: 0.08, green: 0.22, blue: 0.86, alpha: 1),
      alignment: .right,
      spacing: 7,
      indent: 14,
      fixed: true
    )
    XCTAssertEqual(first.attributed.string, second.attributed.string)
    XCTAssertFalse(first.attributed.isEqual(to: second.attributed))

    let flag = SelectableStyleFlag(render: first, wraps: false)
    let host = try mount(
      SelectableStyleHarness(flag: flag, showsLineNumbers: false)
        .frame(width: 280, height: 120)
    )
    probe?.setFrame(NSRect(x: -24000, y: -24000, width: 280, height: 120), display: false)
    host.frame = NSRect(x: 0, y: 0, width: 280, height: 120)
    drain(0.05)
    host.layoutSubtreeIfNeeded()
    let scroll = try XCTUnwrap(find("lab-text-preview", in: host) as? NSScrollView)
    let text = try XCTUnwrap(scroll.documentView as? NSTextView)
    XCTAssertNil(text.textLayoutManager, "file preview left TextKit 1")
    XCTAssertEqual(text.string, body)
    XCTAssertFalse(probe?.isVisible ?? true)
    XCTAssertFalse(probe?.isKeyWindow ?? true)

    let opened = appliedStyle(text)
    print("STYLE_FOLLOW \(opened.line(state: "opened"))")
    XCTAssertEqual(opened.pointSize, 13, accuracy: 0.5, "initial apply did not land the 13pt font: \(opened.line(state: "opened"))")
    XCTAssertEqual(opened.alignment, .left, "initial apply did not land paragraph alignment: \(opened.line(state: "opened"))")
    XCTAssertEqual(opened.lineSpacing, 0, accuracy: 0.5, "initial apply did not land paragraph spacing: \(opened.line(state: "opened"))")
    XCTAssertEqual(opened.red, 0.86, accuracy: 0.08, "initial apply did not land foreground color: \(opened.line(state: "opened"))")

    let kept = NSRange(location: 2, length: 4)
    text.setSelectedRange(kept)
    scroll.contentView.scroll(to: NSPoint(x: 48, y: 0))
    scroll.reflectScrolledClipView(scroll.contentView)
    let origin = scroll.contentView.bounds.origin
    XCTAssertGreaterThan(origin.x, 1, "fixture did not leave a non-zero scroll origin")

    flag.render = second
    drain(0.3)
    host.layoutSubtreeIfNeeded()
    XCTAssertTrue(scroll.documentView === text, "style update replaced the text view")
    let followed = appliedStyle(text)
    print("STYLE_FOLLOW \(followed.line(state: "followed"))")
    XCTAssertEqual(text.string, body, "same-string style update rewrote the text")
    XCTAssertEqual(followed.pointSize, 22, accuracy: 0.5, "same string froze the old font: \(followed.line(state: "followed"))")
    XCTAssertEqual(followed.alignment, .right, "same string froze paragraph alignment: \(followed.line(state: "followed"))")
    XCTAssertEqual(followed.lineSpacing, 7, accuracy: 0.5, "same string froze paragraph spacing: \(followed.line(state: "followed"))")
    XCTAssertEqual(followed.headIndent, 14, accuracy: 0.5, "same string froze paragraph indent: \(followed.line(state: "followed"))")
    XCTAssertEqual(followed.blue, 0.86, accuracy: 0.08, "same string froze the old color: \(followed.line(state: "followed"))")
    XCTAssertLessThan(followed.red, 0.3, "same string kept the old red: \(followed.line(state: "followed"))")
    XCTAssertEqual(
      followed.fontName,
      NSFont.monospacedSystemFont(ofSize: 22, weight: .regular).fontName,
      "same string did not take the monospace font: \(followed.line(state: "followed"))"
    )
    XCTAssertNotEqual(followed.fontName, opened.fontName, "same string kept the proportional font name")
    XCTAssertEqual(text.selectedRange(), kept, "same-string attribute update dropped the selection")
    XCTAssertEqual(scroll.contentView.bounds.origin.x, origin.x, accuracy: 1, "same-string attribute update moved the scroll origin")

    let other = body + "尾"
    let third = styleRender(
      other,
      size: 16,
      color: NSColor(srgbRed: 0.10, green: 0.62, blue: 0.18, alpha: 1),
      alignment: .center,
      spacing: 2,
      indent: 3,
      fixed: false
    )
    let keptOther = NSRange(location: 1, length: 3)
    text.setSelectedRange(keptOther)
    let replacedOrigin = scroll.contentView.bounds.origin
    flag.render = third
    drain(0.3)
    host.layoutSubtreeIfNeeded()
    let replaced = appliedStyle(text)
    print("STYLE_FOLLOW \(replaced.line(state: "replaced"))")
    XCTAssertEqual(text.string, other, "different-string update did not replace the text")
    XCTAssertEqual(text.selectedRange(), keptOther, "different-string update dropped the selection")
    XCTAssertEqual(replaced.pointSize, 16, accuracy: 0.5, "different string did not take the new font: \(replaced.line(state: "replaced"))")
    XCTAssertEqual(replaced.green, 0.62, accuracy: 0.08, "different string did not take the new color: \(replaced.line(state: "replaced"))")
    XCTAssertEqual(scroll.contentView.bounds.origin.x, replacedOrigin.x, accuracy: 1, "different-string update moved the scroll origin")
    XCTAssertTrue(scroll.documentView === text)
    XCTAssertFalse(probe?.isVisible ?? true)
    XCTAssertLessThan(probe?.frame.maxX ?? 0, 0)
  }

  /// Non-key panels drop the first click unless the text view accepts it.
  /// An invisible sealed panel does not dispatch mouseDown from sendEvent; the
  /// paired down/up must still return without tracking, and the live window
  /// covers the actual first click.
  func testBodyFirstClickEntersEditWithoutWaitingForMouseUp() throws {
    let decorator = history.add(textItem("合成正文甲"))
    let host = try mount(OriginalTextEditSection(item: decorator).frame(width: 320, height: 180))
    XCTAssertNil(find("lab-preview-title", in: host))
    let body = try textView("lab-preview-edit-body", in: host)
    let window = try XCTUnwrap(body.window)
    XCTAssertFalse(body.isEditable)
    XCTAssertFalse(window.isKeyWindow)
    XCTAssertFalse(window.isVisible)
    XCTAssertTrue(body.acceptsFirstMouse(for: nil), "non-key body drops the first click")
    let point = body.convert(NSPoint(x: body.bounds.midX, y: body.bounds.midY), to: nil)
    let hit = try XCTUnwrap(window.contentView?.hitTest(point))
    XCTAssertNotEqual(hit.accessibilityIdentifier(), "lab-preview-title")
    let down = try mouse(clickCount: 1, at: point, in: host, type: .leftMouseDown)
    let up = try mouse(clickCount: 1, at: point, in: host, type: .leftMouseUp)
    window.sendEvent(down)
    window.sendEvent(up)
    if !body.isEditable {
      hit.mouseDown(with: down)
      hit.mouseUp(with: up)
    }
    XCTAssertTrue(body.isEditable, "body click did not enter edit")
    XCTAssertEqual(decorator.item.title, "合成正文甲")
    XCTAssertFalse(window.isVisible)
    XCTAssertFalse(window.isKeyWindow)
  }

  /// Real search field, offscreen. Invalid regexp is a visible mark; exact, a legal pattern, and clearing are not.
  func testInvalidRegexpMarkAppearsOnlyForIllegalRegexpQuery() throws {
    guard LabRuntime.isIsolated, LabRuntime.isUnitTestProcess else {
      XCTFail("refusing invalid-regex view test: process is not isolated")
      return
    }
    guard LabDefaults.suite !== UserDefaults.standard else {
      XCTFail("refusing invalid-regex view test: LabDefaults.suite is UserDefaults.standard")
      return
    }
    let key = Defaults.Keys.searchMode
    guard key.suite !== UserDefaults.standard else {
      XCTFail("refusing invalid-regex view test: Defaults[.searchMode] is bound to UserDefaults.standard")
      return
    }
    let standardBefore = UserDefaults.standard.object(forKey: key.name)
    let savedMode = Defaults[.searchMode]
    defer {
      Defaults[.searchMode] = savedMode
      XCTAssertTrue(
        sameStoredDefault(UserDefaults.standard.object(forKey: key.name), standardBefore),
        "restoring searchMode wrote UserDefaults.standard"
      )
    }

    Defaults[.searchMode] = .regexp
    XCTAssertEqual(LabDefaults.suite.string(forKey: key.name), Search.Mode.regexp.rawValue)
    XCTAssertTrue(
      sameStoredDefault(UserDefaults.standard.object(forKey: key.name), standardBefore),
      "writing regexp searchMode leaked to UserDefaults.standard"
    )
    XCTAssertNil(Clipboard.shared.copyProbe)

    let illegal = SearchQueryBox("(")
    let host = try mount(SearchFieldHarness(box: illegal).frame(width: 280))
    let mark = try waitForInvalidMark(true, in: host)
    XCTAssertFalse(mark.label.isEmpty, "invalid regexp mark has an empty AX label")
    XCTAssertFalse(mark.help.isEmpty, "invalid regexp mark has an empty AX help")
    XCTAssertNotEqual(mark.label, "exclamationmark.triangle.fill")
    XCTAssertEqual(mark.label, mark.help)
    XCTAssertEqual(illegal.query, "(")
    assertSearchHostStaysInactive(host)

    illegal.query = ""
    try waitForInvalidMark(false, in: host)
    XCTAssertTrue(illegal.query.isEmpty)
    assertSearchHostStaysInactive(host)

    Defaults[.searchMode] = .exact
    XCTAssertEqual(LabDefaults.suite.string(forKey: key.name), Search.Mode.exact.rawValue)
    let exact = SearchQueryBox("(")
    let exactHost = try mount(SearchFieldHarness(box: exact).frame(width: 280))
    try waitForInvalidMark(false, in: exactHost)
    XCTAssertEqual(exact.query, "(")
    assertSearchHostStaysInactive(exactHost)

    Defaults[.searchMode] = .regexp
    let legal = SearchQueryBox("(a)")
    let legalHost = try mount(SearchFieldHarness(box: legal).frame(width: 280))
    try waitForInvalidMark(false, in: legalHost)
    XCTAssertEqual(legal.query, "(a)")
    assertSearchHostStaysInactive(legalHost)
    XCTAssertTrue(sameStoredDefault(UserDefaults.standard.object(forKey: key.name), standardBefore))
  }

  /// Auxiliary ICU predicate. The view assertion above is the contract.
  func testRegexpWarningPredicateUsesICUAndSkipsMixed() {
    XCTAssertTrue(SearchFieldView.showsInvalidRegexp(mode: .regexp, query: "("))
    XCTAssertFalse(SearchFieldView.showsInvalidRegexp(mode: .regexp, query: "(a)"))
    XCTAssertFalse(SearchFieldView.showsInvalidRegexp(mode: .regexp, query: ""))
    XCTAssertFalse(SearchFieldView.showsInvalidRegexp(mode: .exact, query: "("))
    XCTAssertFalse(SearchFieldView.showsInvalidRegexp(mode: .mixed, query: "("))
    XCTAssertFalse(SearchFieldView.showsInvalidRegexp(mode: .fuzzy, query: "("))
    XCTAssertNotNil(try? NSRegularExpression(pattern: "(a)"))
    XCTAssertNil(try? NSRegularExpression(pattern: "("))
  }

  private func errorMiss(in host: NSView, itemID: UUID) -> String {
    let model = AppState.shared.textEditError(for: itemID) ?? "nil"
    let found = find("lab-preview-edit-error", in: host)
    return "model=\(model) found=\(String(describing: found.map { String(describing: type(of: $0)) }))"
  }

  // MARK: - Host

  private func pin(_ letter: String, body: String) -> HistoryItemDecorator {
    let item = textItem(body)
    item.pin = letter
    item.title = body
    let decorator = history.add(item)
    decorator.title = body
    return decorator
  }

  private func textItem(_ value: String) -> HistoryItem {
    let item = HistoryItem(contents: [
      HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data(value.utf8))
    ])
    item.title = value
    Storage.shared.context.insert(item)
    return item
  }

  private func imageItem(_ title: String) -> HistoryItemDecorator {
    let item = HistoryItem(contents: [
      HistoryItemContent(type: NSPasteboard.PasteboardType.png.rawValue, value: Data([0x89, 0x50, 0x4E, 0x47]))
    ])
    item.title = title
    Storage.shared.context.insert(item)
    return history.add(item)
  }

  private func fileItem() throws -> (item: HistoryItemDecorator, url: URL) {
    // The test host is sandboxed; write inside the container instead of a fixed home path.
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("maccy-preview-edit-contract-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("read-only.txt")
    try Data("disk".utf8).write(to: url, options: .atomic)
    let item = HistoryItem(contents: [
      HistoryItemContent(type: NSPasteboard.PasteboardType.fileURL.rawValue, value: url.dataRepresentation)
    ])
    item.title = "file"
    Storage.shared.context.insert(item)
    return (history.add(item), url)
  }

  private func mount<V: View>(_ view: V) throws -> NSView {
    let panel = SealedEditPanel(
      contentRect: NSRect(x: -24000, y: -24000, width: 480, height: 280),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: view
      .environment(AppState.shared)
      .environment(ModifierFlags())
      .modelContainer(Storage.shared.container))
    host.sizingOptions = []
    host.frame = panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 480, height: 280)
    panel.contentView = host
    probe?.close()
    probe = panel
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
      drain(0.04)
      host.layoutSubtreeIfNeeded()
      if host.subviews.isEmpty == false { break }
    }
    XCTAssertFalse(panel.isVisible)
    XCTAssertFalse(panel.isKeyWindow)
    XCTAssertLessThan(panel.frame.maxX, 0)
    return host
  }

  private func pinRecorder(id: UUID, in root: NSView) throws -> PinnedShortcutRecorder {
    let found = find("lab-pin-shortcut-\(id.uuidString)", in: root) as? PinnedShortcutRecorder
    return try XCTUnwrap(found, "pin shortcut control was not installed")
  }

  private func pressTag(of item: HistoryItemDecorator, in root: NSView) throws {
    try press("lab-mutex-tag-\(item.id.uuidString)", in: root)
  }

  private func press(_ id: String, in root: NSView) throws {
    let button = try XCTUnwrap(find(id, in: root) as? ImmediateActionButton, "\(id) was not installed")
    XCTAssertTrue(button.isEnabled, "\(id) is disabled")
    button.mouseDown(with: try mouse(clickCount: 1, in: root))
  }

  private func beginEdit(_ id: String, in host: NSView) throws -> OriginalTextBodyView {
    XCTAssertNil(find("lab-preview-edit-save", in: host), "save button is still resident")
    XCTAssertNil(find("lab-preview-edit-cancel", in: host), "cancel button is still resident")
    let view = try textView(id, in: host)
    XCTAssertFalse(view.isEditable, "\(id) started editable")
    view.mouseDown(with: try mouse(clickCount: 1, at: NSPoint(x: 6, y: 6), in: host))
    XCTAssertTrue(view.isEditable, "click did not enter edit on \(id)")
    XCTAssertTrue(host.window?.makeFirstResponder(view) ?? false, "editor did not become first responder")
    XCTAssertTrue(host.window?.firstResponder === view)
    XCTAssertFalse(host.window?.isVisible ?? true)
    return view
  }

  private func submit(_ view: OriginalTextBodyView) throws {
    XCTAssertFalse(view.hasMarkedText())
    view.keyDown(with: try key("\n", code: 36, flags: []))
    drain(0.1)
  }

  private func cancelEdit(_ view: OriginalTextBodyView) throws {
    XCTAssertFalse(view.hasMarkedText())
    view.keyDown(with: try key("", code: 53, flags: []))
    drain(0.1)
  }

  private func textView(_ id: String, in root: NSView) throws -> OriginalTextBodyView {
    let ids = id == "lab-preview-edit-body" || id == "lab-preview-body"
      ? ["lab-preview-body", "lab-preview-edit-body"]
      : [id]
    for candidate in ids {
      if let view = find(candidate, in: root) as? OriginalTextBodyView { return view }
      if let scroll = find(candidate, in: root) as? NSScrollView,
         let view = scroll.documentView as? OriginalTextBodyView {
        return view
      }
      var found: OriginalTextBodyView?
      func walk(_ view: NSView) {
        if let body = view as? OriginalTextBodyView, body.accessibilityIdentifier() == candidate { found = body }
        view.subviews.forEach(walk)
      }
      walk(root)
      if let found { return found }
    }
    return try XCTUnwrap(nil as OriginalTextBodyView?, "original text editor was not installed for \(id)")
  }

  private func find(_ id: String, in root: NSView) -> NSView? {
    if root.accessibilityIdentifier() == id { return root }
    for subview in root.subviews {
      if let found = find(id, in: subview) { return found }
    }
    return nil
  }

  private struct InvalidRegexpMark {
    var label: String
    var help: String
  }

  private func waitForInvalidMark(_ present: Bool, in host: NSView, timeout: TimeInterval = 1.5) throws -> InvalidRegexpMark {
    let deadline = Date().addingTimeInterval(timeout)
    var last: [String] = []
    while Date() < deadline {
      host.layoutSubtreeIfNeeded()
      _ = host.accessibilityChildren()
      _ = host.accessibilityChildrenInNavigationOrder()
      last = accessibilityIdentifiers(in: host)
      if let mark = invalidRegexpMark(in: host), present, !mark.label.isEmpty, !mark.help.isEmpty {
        return mark
      }
      if invalidRegexpMark(in: host) == nil, !present {
        return InvalidRegexpMark(label: "", help: "")
      }
      drain(0.04)
    }
    XCTFail("invalid-regex mark present=\(present) timed out; ids=\(last.joined(separator: ",")); views=\(viewClasses(in: host))")
    throw SearchFieldProbeError()
  }

  private func invalidRegexpMark(in root: NSView) -> InvalidRegexpMark? {
    guard let node = accessibilityNode("lab-search-invalid-regex", in: root) else { return nil }
    let label = axString(node, "accessibilityLabel") ?? ""
    let help = axString(node, "accessibilityHelp") ?? ""
    return InvalidRegexpMark(label: label, help: help)
  }

  private func accessibilityNode(_ id: String, in root: NSView) -> NSObject? {
    var found: NSObject?
    var seen = Set<ObjectIdentifier>()
    func walk(_ object: AnyObject?, depth: Int) {
      guard found == nil, let object, depth < 48 else { return }
      let token = ObjectIdentifier(object)
      guard seen.insert(token).inserted else { return }
      let identifier: String
      if let view = object as? NSView {
        identifier = view.accessibilityIdentifier()
      } else {
        identifier = axString(object, "accessibilityIdentifier") ?? ""
      }
      if identifier == id, let ns = object as? NSObject {
        found = ns
        return
      }
      if let view = object as? NSView {
        view.subviews.forEach { walk($0, depth: depth + 1) }
      }
      axChildren(object).forEach { walk($0, depth: depth + 1) }
    }
    walk(root, depth: 0)
    return found
  }

  private func accessibilityIdentifiers(in root: NSView) -> [String] {
    var found: [String] = []
    var seen = Set<ObjectIdentifier>()
    func walk(_ object: AnyObject?, depth: Int) {
      guard let object, depth < 48, found.count < 40 else { return }
      let token = ObjectIdentifier(object)
      guard seen.insert(token).inserted else { return }
      if let view = object as? NSView {
        let id = view.accessibilityIdentifier()
        if !id.isEmpty { found.append(id) }
        view.subviews.forEach { walk($0, depth: depth + 1) }
      } else if let id = axString(object, "accessibilityIdentifier"), !id.isEmpty {
        found.append(id)
      }
      axChildren(object).forEach { walk($0, depth: depth + 1) }
    }
    walk(root, depth: 0)
    return found
  }

  private func viewClasses(in root: NSView) -> String {
    var lines: [String] = []
    func walk(_ view: NSView, depth: Int) {
      guard lines.count < 16, depth < 6 else { return }
      let id = view.accessibilityIdentifier()
      lines.append("\(String(describing: type(of: view))) \(Int(view.bounds.width))x\(Int(view.bounds.height)) \(id)")
      view.subviews.forEach { walk($0, depth: depth + 1) }
    }
    walk(root, depth: 0)
    return lines.joined(separator: ";")
  }

  private func axChildren(_ object: AnyObject) -> [AnyObject] {
    var kids: [AnyObject] = []
    if let view = object as? NSView {
      kids.append(contentsOf: (view.accessibilityChildren() ?? []).compactMap { $0 as? NSObject })
      kids.append(contentsOf: (view.accessibilityChildrenInNavigationOrder() ?? []).compactMap { $0 as? NSObject })
    }
    for name in ["accessibilityChildren", "accessibilityChildrenInNavigationOrder"] {
      let sel = NSSelectorFromString(name)
      guard let ns = object as? NSObject, ns.responds(to: sel),
            let raw = ns.perform(sel)?.takeUnretainedValue() as? [AnyObject] else { continue }
      kids.append(contentsOf: raw)
    }
    return kids
  }

  private func axString(_ object: AnyObject, _ name: String) -> String? {
    if let ns = object as? NSObject, let value = try? ns.value(forKey: name) {
      if let text = value as? String, !text.isEmpty { return text }
      if let text = value as? NSString, text.length > 0 { return text as String }
    }
    let sel = NSSelectorFromString(name)
    guard let ns = object as? NSObject, ns.responds(to: sel) else { return nil }
    guard let raw = ns.perform(sel)?.takeUnretainedValue() else { return nil }
    if let text = raw as? String, !text.isEmpty { return text }
    return nil
  }

  private func assertSearchHostStaysInactive(_ host: NSView) {
    XCTAssertFalse(host.window?.isVisible ?? true)
    XCTAssertFalse(host.window?.isKeyWindow ?? true)
    XCTAssertFalse(NSApp.keyWindow === host.window)
    XCTAssertLessThan(host.window?.frame.maxX ?? 0, 0)
    XCTAssertNil(Clipboard.shared.copyProbe)
  }

  private func sameStoredDefault(_ lhs: Any?, _ rhs: Any?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
      return true
    case let (left as NSObject, right as NSObject):
      return left.isEqual(right)
    default:
      return false
    }
  }

  private func frame(_ id: String, in root: NSView) throws -> CGRect {
    let view = try XCTUnwrap(find(id, in: root), "\(id) was not installed")
    return view.convert(view.bounds, to: root)
  }

  private func adjacentGap(_ a: CGRect, _ b: CGRect) -> CGFloat {
    if a.maxY <= b.minY { return b.minY - a.maxY }
    if b.maxY <= a.minY { return a.minY - b.maxY }
    return min(a.minY, b.minY) - max(a.maxY, b.maxY)
  }

  private func mouse(clickCount: Int, in host: NSView) throws -> NSEvent {
    try mouse(clickCount: clickCount, at: NSPoint(x: 8, y: 8), in: host)
  }

  private func mouse(clickCount: Int, at point: NSPoint, in host: NSView, type: NSEvent.EventType = .leftMouseDown) throws -> NSEvent {
    try XCTUnwrap(NSEvent.mouseEvent(
      with: type,
      location: point,
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: host.window?.windowNumber ?? 0,
      context: nil,
      eventNumber: clickCount,
      clickCount: clickCount,
      pressure: 1
    ))
  }

  private func visiblePrompt(in recorder: NSView) throws -> NSTextField {
    var found: NSTextField?
    func walk(_ view: NSView) {
      if let field = view as? NSTextField, field.accessibilityIdentifier() == "lab-shortcut-prompt" {
        found = field
      }
      view.subviews.forEach(walk)
    }
    walk(recorder)
    return try XCTUnwrap(found, "recording prompt was not a visible text field")
  }

  private func labStrings(_ language: String) -> String {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("WitsCopy/\(language).lproj/Localizable.strings")
      .path
  }

  private func payload(_ type: String, in item: HistoryItem) -> Data? {
    item.contents.first(where: { $0.type == type })?.value
  }

  private func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: flags,
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: probe?.windowNumber ?? 0,
      context: nil,
      characters: characters.isEmpty ? "\u{1b}" : characters,
      charactersIgnoringModifiers: characters.isEmpty ? "" : characters,
      isARepeat: false,
      keyCode: code
    ))
  }

  private func bitmap(_ view: NSView) -> NSBitmapImageRep? {
    guard view.bounds.width > 1, view.bounds.height > 1,
          let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(Int(view.bounds.width), 1),
            pixelsHigh: max(Int(view.bounds.height), 1),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
          ) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
  }

  private func drain(_ interval: TimeInterval) {
    let end = Date().addingTimeInterval(interval)
    while Date() < end {
      RunLoop.current.run(mode: .common, before: Date().addingTimeInterval(0.01))
    }
  }

  private struct WrapLayoutRead {
    var usedHeight: CGFloat = 0
    var usedWidth: CGFloat = 0
    var containerWidth: CGFloat = 0
    var lineHeight: CGFloat = 0
    var fragments: Int = 0
    var viewportWidth: CGFloat = 0

    func line(state: String) -> String {
      String(
        format: "state=%@ usedHeight=%.2f usedWidth=%.2f containerWidth=%.2f lineHeight=%.2f fragments=%d viewportWidth=%.2f",
        state, usedHeight, usedWidth, containerWidth, lineHeight, fragments, viewportWidth
      )
    }
  }

  /// Reads layout-manager geometry without rewriting the text container.
  private func readWrapLayout(_ view: NSTextView) -> WrapLayoutRead {
    for _ in 0..<3 {
      view.enclosingScrollView?.layoutSubtreeIfNeeded()
      view.layoutSubtreeIfNeeded()
    }
    var read = WrapLayoutRead()
    read.viewportWidth = view.enclosingScrollView?.contentSize.width ?? view.bounds.width
    guard let layout = view.layoutManager, let container = view.textContainer else { return read }
    layout.ensureLayout(for: container)
    let used = layout.usedRect(for: container)
    read.usedHeight = used.height
    read.usedWidth = used.width
    read.containerWidth = container.containerSize.width
    let glyphs = layout.numberOfGlyphs
    var index = 0
    while index < glyphs && read.fragments < 80 {
      var range = NSRange(location: 0, length: 0)
      let rect = layout.lineFragmentRect(forGlyphAt: index, effectiveRange: &range, withoutAdditionalLayout: true)
      if range.length == 0 { break }
      if read.fragments == 0 { read.lineHeight = rect.height }
      read.fragments += 1
      index = NSMaxRange(range)
    }
    return read
  }

  /// First glyph minX in the clip view, relative to the visible origin.
  /// Negative means the line-number prefix is outside the viewport.
  private func glyphMinXInViewport(_ view: NSTextView, scroll: NSScrollView) -> CGFloat {
    view.layoutSubtreeIfNeeded()
    scroll.contentView.layoutSubtreeIfNeeded()
    guard let layout = view.layoutManager, let container = view.textContainer, layout.numberOfGlyphs > 0 else {
      return -10_000
    }
    layout.ensureLayout(for: container)
    let glyph = layout.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: container)
    let inText = glyph.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
    let inClip = view.convert(inText, to: scroll.contentView)
    return inClip.minX - scroll.contentView.bounds.minX
  }

  private struct AppliedStyle {
    var fontName = ""
    var pointSize: CGFloat = -1
    var red: CGFloat = -1
    var green: CGFloat = -1
    var blue: CGFloat = -1
    var alignment: NSTextAlignment = .natural
    var lineSpacing: CGFloat = -1
    var headIndent: CGFloat = -1
    var hasParagraph = false

    func line(state: String) -> String {
      String(
        format: "state=%@ font=%@ pointSize=%.2f rgba=%.3f,%.3f,%.3f alignment=%d spacing=%.2f indent=%.2f paragraph=%@",
        state,
        fontName,
        pointSize,
        red,
        green,
        blue,
        alignment.rawValue,
        lineSpacing,
        headIndent,
        hasParagraph ? "true" : "false"
      )
    }
  }

  /// Reads the attributes NSTextStorage actually holds, not the input model.
  private func appliedStyle(_ view: NSTextView, at location: Int = 0) -> AppliedStyle {
    var read = AppliedStyle()
    guard let storage = view.textStorage, storage.length > location else { return read }
    if let font = storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont {
      read.fontName = font.fontName
      read.pointSize = font.pointSize
    }
    if let color = (storage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor)?
      .usingColorSpace(.sRGB) {
      read.red = color.redComponent
      read.green = color.greenComponent
      read.blue = color.blueComponent
    }
    if let paragraph = storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle {
      read.hasParagraph = true
      read.alignment = paragraph.alignment
      read.lineSpacing = paragraph.lineSpacing
      read.headIndent = paragraph.headIndent
    }
    return read
  }

  private func styleRender(
    _ text: String,
    size: CGFloat,
    color: NSColor,
    alignment: NSTextAlignment,
    spacing: CGFloat,
    indent: CGFloat,
    fixed: Bool
  ) -> PreviewTextRender {
    let font = fixed
      ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
      : NSFont.systemFont(ofSize: size)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineSpacing = spacing
    paragraph.headIndent = indent
    let attributed = NSAttributedString(string: text, attributes: [
      .font: font,
      .foregroundColor: color,
      .paragraphStyle: paragraph
    ])
    return PreviewTextRender(
      kind: fixed ? .code : .plain,
      languageLabel: fixed ? "Swift" : "Plain",
      monospace: fixed,
      display: text,
      full: text,
      truncated: false,
      lineCount: 1,
      attributed: attributed,
      structure: PreviewTextStructure(),
      lineNumbers: "1"
    )
  }

  private func fragmentCount(_ view: NSTextView) -> Int {
    view.layoutSubtreeIfNeeded()
    guard let layout = view.layoutManager, let container = view.textContainer else { return -1 }
    let width = view.enclosingScrollView?.contentSize.width ?? view.bounds.width
    if let tracks = view.textContainer?.widthTracksTextView, tracks, width > 1 {
      view.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    }
    layout.ensureLayout(for: container)
    let glyphs = layout.numberOfGlyphs
    if glyphs == 0 { return 0 }
    var count = 0
    var index = 0
    while index < glyphs && count < 80 {
      var range = NSRange(location: 0, length: 0)
      _ = layout.lineFragmentRect(forGlyphAt: index, effectiveRange: &range, withoutAdditionalLayout: true)
      if range.length == 0 { break }
      count += 1
      index = NSMaxRange(range)
    }
    return count
  }
}

private extension PinnedShortcutRecorder {
  func keyDownConsumed(_ event: NSEvent) -> Bool {
    keyDown(with: event)
    return true
  }
}

private final class SelectableWrapFlag: ObservableObject {
  @Published var wraps = true
  @Published var width: CGFloat = 448
}

private struct SelectableWrapHarness: View {
  var render: PreviewTextRender
  @ObservedObject var flag: SelectableWrapFlag
  var showsLineNumbers: Bool

  var body: some View {
    SelectableTextPreview(render: render, wraps: flag.wraps, showsLineNumbers: showsLineNumbers)
      .frame(width: flag.width, height: 160)
  }
}

private final class SelectableStyleFlag: ObservableObject {
  @Published var render: PreviewTextRender
  @Published var wraps: Bool

  init(render: PreviewTextRender, wraps: Bool) {
    self.render = render
    self.wraps = wraps
  }
}

private struct SelectableStyleHarness: View {
  @ObservedObject var flag: SelectableStyleFlag
  var showsLineNumbers: Bool

  var body: some View {
    SelectableTextPreview(render: flag.render, wraps: flag.wraps, showsLineNumbers: showsLineNumbers)
      .frame(width: 280, height: 120)
  }
}

private final class WrapFlag: ObservableObject {
  @Published var wraps = true
}

private struct WrapToggleHarness: View {
  var item: HistoryItemDecorator
  @ObservedObject var flag: WrapFlag

  var body: some View {
    OriginalTextEditSection(item: item, wraps: flag.wraps)
  }
}

private final class SealedShortcutPanel<Content: View>: FloatingPanel<Content> {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
  override func makeKey() {}
  override func becomeKey() {}
  override func makeMain() {}
  override func makeKeyAndOrderFront(_ sender: Any?) {}
  override func orderFront(_ sender: Any?) {}
  override func orderFrontRegardless() {}
  override func orderBack(_ sender: Any?) {}
  override func orderOut(_ sender: Any?) {}
  override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {}
}

private final class SealedEditPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  override func makeMain() {}
  override func makeKeyAndOrderFront(_ sender: Any?) {}
  override func orderFront(_ sender: Any?) {}
  override func orderFrontRegardless() {}
  override func orderBack(_ sender: Any?) {}
  override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {}
}

/// Real row recorders plus the preview tag buttons. Identifiers
/// are per item so a cross-item press cannot hit the other row's control.
private struct EditorMutexHost: View {
  var first: HistoryItemDecorator
  var second: HistoryItemDecorator
  @Environment(AppState.self) private var appState

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HistoryItemView(item: first, previous: nil, next: second, index: 0)
        .frame(width: 440, height: 72)
      HistoryItemView(item: second, previous: first, next: nil, index: 1)
        .frame(width: 440, height: 72)
      corners(first)
      auxiliary(first)
      corners(second)
      auxiliary(second)
    }
    .frame(width: 460, height: 400, alignment: .topLeading)
  }

  private func corners(_ item: HistoryItemDecorator) -> some View {
    HStack(spacing: 4) {
      ImmediateIconButton(
        systemName: "tag",
        help: "Tag",
        identifier: "lab-mutex-tag-\(item.id.uuidString)",
        label: "Tag",
        action: { appState.performRowAction(.tag, on: item, anchor: .preview) }
      )
      .frame(width: 28, height: 24)
    }
  }

  @ViewBuilder
  private func auxiliary(_ item: HistoryItemDecorator) -> some View {
    if appState.presentsTagEditor(item, at: .preview) {
      TagEditorPopover(item: item, compact: true)
        .environment(appState)
        .accessibilityIdentifier("lab-preview-aux-\(item.id.uuidString)")
    }
  }
}

private struct SearchFieldProbeError: Error {}

private final class SearchQueryBox: ObservableObject {
  @Published var query: String

  init(_ query: String) {
    self.query = query
  }
}

private struct SearchFieldHarness: View {
  @ObservedObject var box: SearchQueryBox

  var body: some View {
    SearchFieldView(placeholder: "search_placeholder", query: $box.query)
  }
}
