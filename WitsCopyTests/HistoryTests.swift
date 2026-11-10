import XCTest
import AppKit
import ApplicationServices
import Defaults
import PDFKit
import Sauce
import SQLite3
import SwiftData
import SwiftUI
@testable import WitsCopy

private let standardPanelSplit = PanelSplit(
  listWidth: PanelSplit.defaultList,
  previewWidth: PanelSplit.defaultPreview,
  previewOpen: true,
  height: PanelSplit.defaultHeight
)

@MainActor
class HistoryTests: XCTestCase {
  let savedSize = Defaults[.size]
  let savedSortBy = Defaults[.sortBy]
  let savedPinTo = Defaults[.pinTo]
  let history = History.shared

  override func setUp() {
    super.setUp()
    history.clearAll()
    Defaults[.size] = 10
    Defaults[.sortBy] = .firstCopiedAt
    Defaults[.pinTo] = .bottom
    AppState.shared.windowPinned = false
    AppState.shared.workspaceSection = .all
    AppState.shared.panelPresented = false
    AppState.shared.managementRailVisible = true
    AppState.shared.tagEditorItem = nil
    AppState.shared.cancelPreviewRecognition = nil
    AppState.shared.preview.state = .open
    Clipboard.shared.copyProbe = nil
  }

  override func tearDown() {
    Storage.shared.saveImplementation = nil
    AppState.shared.storageError = nil
    AppState.shared.cancelPreviewRecognition = nil
    AppState.shared.closeOCR()
    super.tearDown()
    Defaults[.size] = savedSize
    Defaults[.sortBy] = savedSortBy
    Defaults[.pinTo] = savedPinTo
  }

  func testDefaultIsEmpty() {
    XCTAssertEqual(history.items, [])
  }

  func testAdding() {
    let first = history.add(historyItem("foo"))
    let second = history.add(historyItem("bar"))
    XCTAssertEqual(history.items, [second, first])
  }

  func testAddingSame() {
    let first = historyItem("foo")
    first.title = "xyz"
    first.application = "iTerm.app"
    history.add(first)
    first.pin = "f"

    let secondDecorator = history.add(historyItem("bar"))

    let third = historyItem("foo")
    third.application = "Xcode.app"
    let merged = history.add(third)

    // The duplicate merges into the existing entry instead of adding a new
    // one, and the merged item carries the original item's metadata.
    // With pinTo = .bottom the unpinned bar sorts first and the re-inserted
    // pinned merged item lands at the end of `all`.
    XCTAssertEqual(history.all, [secondDecorator, merged])
    XCTAssertTrue(merged.item.lastCopiedAt > merged.item.firstCopiedAt)
    XCTAssertEqual(merged.item.numberOfCopies, 2)
    XCTAssertEqual(merged.item.pin, "f")
    XCTAssertEqual(merged.item.title, "xyz")
    XCTAssertEqual(merged.item.application, "iTerm.app")
  }

  func testAddingItemThatIsSupersededByExisting() {
    let firstContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)!
      ),
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.rtf.rawValue,
        value: "two".data(using: .utf8)!
      )
    ]
    let firstItem = HistoryItem()
    Storage.shared.context.insert(firstItem)
    firstItem.application = "WitsCopy.app"
    firstItem.contents = firstContents
    firstItem.title = firstItem.generateTitle()
    history.add(firstItem)

    let secondContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)!
      )
    ]
    let secondItem = HistoryItem()
    Storage.shared.context.insert(secondItem)
    secondItem.application = "WitsCopy.app"
    secondItem.contents = secondContents
    secondItem.title = secondItem.generateTitle()
    let second = history.add(secondItem)

    XCTAssertEqual(history.items, [second])
    XCTAssertEqual(Set(history.items[0].item.contents), Set(firstContents))
  }

  func testAddingItemWithDifferentModifiedType() {
    let firstContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)!
      ),
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.modified.rawValue,
        value: "1".data(using: .utf8)!
      )
    ]
    let firstItem = HistoryItem()
    Storage.shared.context.insert(firstItem)
    firstItem.contents = firstContents
    history.add(firstItem)

    let secondContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)!
      ),
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.modified.rawValue,
        value: "2".data(using: .utf8)!
      )
    ]
    let secondItem = HistoryItem()
    Storage.shared.context.insert(secondItem)
    secondItem.contents = secondContents
    let second = history.add(secondItem)

    XCTAssertEqual(history.items, [second])
    XCTAssertEqual(Set(history.items[0].item.contents), Set(firstContents))
  }

  func testAddingItemFromWitsCopy() {
    let firstContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)
      )
    ]
    let first = HistoryItem()
    Storage.shared.context.insert(first)
    first.application = "Xcode.app"
    first.contents = firstContents
    history.add(first)

    let secondContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)
      ),
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.fromWitsCopy.rawValue,
        value: "".data(using: .utf8)
      )
    ]
    let second = HistoryItem()
    Storage.shared.context.insert(second)
    second.application = "WitsCopy.app"
    second.contents = secondContents
    let secondDecorator = history.add(second)

    XCTAssertEqual(history.items, [secondDecorator])
    XCTAssertEqual(history.items[0].item.application, "Xcode.app")
    XCTAssertEqual(Set(history.items[0].item.contents), Set(firstContents))
  }

  func testModifiedAfterCopying() {
    history.add(historyItem("foo"))

    let modifiedItem = historyItem("bar")
    modifiedItem.contents.append(HistoryItemContent(
      type: NSPasteboard.PasteboardType.modified.rawValue,
      value: String(Clipboard.shared.changeCount).data(using: .utf8)
    ))
    let modifiedItemDecorator = history.add(modifiedItem)

    XCTAssertEqual(history.items, [modifiedItemDecorator])
    XCTAssertEqual(history.items[0].text, "bar")
  }

  func testClearingUnpinned() {
    let pinned = history.add(historyItem("foo"))
    pinned.togglePin()
    history.add(historyItem("bar"))
    history.clear()
    XCTAssertEqual(history.items, [pinned])
  }

  func testClearingKeepsTagged() {
    let tagged = history.add(historyItem("keep"))
    tagged.item.tags = ["addr"]
    history.add(historyItem("drop"))
    history.clear()
    XCTAssertEqual(history.items, [tagged])
    XCTAssertEqual(history.items[0].item.tags, ["addr"])
  }

  func testClearingAll() {
    history.add(historyItem("foo"))
    history.clear()
    XCTAssertEqual(history.items, [])
  }

  func testMaxSize() {
    var items: [HistoryItemDecorator] = []
    for index in 0...10 {
      items.append(history.add(historyItem(String(index))))
    }

    XCTAssertEqual(history.items.count, 10)
    XCTAssertTrue(history.items.contains(items[10]))
    XCTAssertFalse(history.items.contains(items[0]))
  }

  func testMaxSizeIgnoresPinned() {
    var items: [HistoryItemDecorator] = []

    let item = history.add(historyItem("0"))
    items.append(item)
    item.togglePin()

    for index in 1...11 {
      items.append(history.add(historyItem(String(index))))
    }

    XCTAssertEqual(history.items.count, 11)
    XCTAssertTrue(history.items.contains(items[10]))
    XCTAssertTrue(history.items.contains(items[0]))
    XCTAssertFalse(history.items.contains(items[1]))
  }

  func testMaxSizeIsChanged() {
    var items: [HistoryItemDecorator] = []
    for index in 0...10 {
      items.append(history.add(historyItem(String(index))))
    }
    Defaults[.size] = 5
    history.add(historyItem("11"))

    XCTAssertEqual(history.items.count, 5)
    XCTAssertTrue(history.items.contains(items[10]))
    XCTAssertFalse(history.items.contains(items[5]))
  }

  func testReaddingBottomMostPinnedItemAtFullCapacity() {
    // Regression test for a crash when re-copying (invoking) the bottom-most
    // pinned item while history is at full capacity and pins are sorted to the
    // bottom. The stale insert index used to trap with an out-of-bounds insert.
    // Issue link: https://github.com/p0deje/Maccy/issues/1466
    // `pinTo` is restored to its default value(.top) in `tearDown`.
    Defaults[.pinTo] = .bottom

    // Pin an item; `history.togglePin` re-sorts `all`, so with `.bottom` the
    // pinned item ends up as the last element.
    let pinned = history.add(historyItem("pinned"))
    history.togglePin(pinned)

    // Fill unpinned history to full capacity.
    for index in 0..<Defaults[.size] {
      history.add(historyItem(String(index)))
    }

    XCTAssertEqual(history.all.last, pinned)

    // Re-copy the pinned item. It is detected as a duplicate, removed and
    // re-inserted while `limitHistorySize` trims an exceeding unpinned item.
    // Before the fix this inserted at a stale, out-of-bounds index and crashed.
    let readded = history.add(historyItem("pinned"))

    XCTAssertTrue(history.all.contains(readded))
    XCTAssertEqual(history.all.filter(\.isPinned).count, 1)
  }

  func testRemoving() {
    let foo = history.add(historyItem("foo"))
    let bar = history.add(historyItem("bar"))
    history.delete(foo)
    XCTAssertEqual(history.items, [bar])
  }

  private func storedContentCount() -> Int {
    (try? Storage.shared.context.fetchCount(FetchDescriptor<HistoryItemContent>())) ?? -1
  }

  /// Re-copying something already in history used to orphan the new copy's
  /// contents: the item adopted the stored contents and its own stayed behind.
  func testDuplicateMergeLeavesNoOrphanContents() {
    history.add(historyItem("same"))
    history.add(historyItem("same"))
    history.add(historyItem("same"))
    XCTAssertEqual(history.all.count, 1)
    XCTAssertEqual(storedContentCount(), 1, "only the surviving item's content remains")
  }

  /// A batch delete of HistoryItem skips the cascade rule; contents must go too.
  func testClearAllDeletesContents() {
    history.add(historyItem("foo"))
    history.add(historyItem("bar"))
    XCTAssertEqual(storedContentCount(), 2)
    history.clearAll()
    XCTAssertEqual(storedContentCount(), 0)
  }

  func testPurgeRemovesOnlyOrphanedContents() throws {
    history.add(historyItem("kept"))
    let orphan = HistoryItemContent(type: "public.tiff", value: Data(repeating: 1, count: 1024))
    Storage.shared.context.insert(orphan)
    try Storage.shared.context.save()
    XCTAssertEqual(storedContentCount(), 2)
    XCTAssertEqual(Storage.shared.purgeOrphanedContents(), 1)
    XCTAssertEqual(storedContentCount(), 1)
    XCTAssertEqual(history.all.first?.text, "kept")
    XCTAssertEqual(Storage.shared.purgeOrphanedContents(), 0)
  }

  /// SQLite never returns deleted pages to the disk on its own.
  func testStoreCompactorShrinksTheFileAfterDeletes() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("wits-compact-\(UUID().uuidString).sqlite")
    defer {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: url.path + suffix)
      }
    }
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
    sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE t(v BLOB);", nil, nil, nil)
    for _ in 0..<40 {
      sqlite3_exec(db, "INSERT INTO t VALUES (zeroblob(262144));", nil, nil, nil)
    }
    sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE); DELETE FROM t; PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
    sqlite3_close(db)
    let before = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
    XCTAssertGreaterThan(before, 8_000_000, "deleted rows still occupy the file")
    XCTAssertTrue(StoreCompactor.compact(path: url.path))
    let after = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
    XCTAssertLessThan(after, 100_000)
  }

  func testDuplicateKeepsTags() {
    let first = historyItem("same")
    first.tags = ["Addr"]
    history.add(first)

    let second = historyItem("same")
    second.tags = ["work"]
    let merged = history.add(second)

    XCTAssertEqual(merged.item.tags, ["Addr", "work"])
    XCTAssertEqual(history.all.filter { $0.item.title == "same" || $0.item.title == "xyz" }.count, 1)
    let stored = try? Storage.shared.context.fetch(FetchDescriptor<HistoryItem>())
    XCTAssertEqual(stored?.count, 1)
    XCTAssertEqual(stored?.first?.tags, ["Addr", "work"])
  }

  func testClearKeepsTaggedContentsAndDoesNotClearPasteboard() {
    let savedClear = Defaults[.clearSystemClipboard]
    Defaults[.clearSystemClipboard] = true
    defer { Defaults[.clearSystemClipboard] = savedClear }

    let before = Clipboard.shared.changeCount
    let tagged = history.add(historyItem("keep"))
    tagged.item.tags = ["addr"]
    let pinned = history.add(historyItem("pin"))
    pinned.togglePin()
    history.add(historyItem("drop"))
    history.clear()

    XCTAssertEqual(Clipboard.shared.changeCount, before)
    XCTAssertFalse(Clipboard.shared.isMonitoring)
    XCTAssertEqual(Set(history.all.map(\.item.title)), ["keep", "pin"])
    XCTAssertEqual(tagged.item.text, "keep")
    let stored = try? Storage.shared.context.fetch(FetchDescriptor<HistoryItem>())
    XCTAssertEqual(Set(stored?.map(\.title) ?? []), ["keep", "pin"])
    XCTAssertEqual(stored?.first { $0.title == "keep" }?.tags, ["addr"])
    XCTAssertEqual(stored?.first { $0.title == "keep" }?.text, "keep")
  }

  func testCapacityKeepsTaggedAndDropsOldestDisposable() {
    Defaults[.size] = 2
    Defaults[.sortBy] = .lastCopiedAt

    let old = history.add(historyItem("old"))
    old.item.lastCopiedAt = Date(timeIntervalSince1970: 10)

    let taggedItem = historyItem("tagged")
    taggedItem.tags = ["keep"]
    taggedItem.lastCopiedAt = Date(timeIntervalSince1970: 20)
    let tagged = history.add(taggedItem)

    let mid = history.add(historyItem("mid"))
    mid.item.lastCopiedAt = Date(timeIntervalSince1970: 30)
    let newest = history.add(historyItem("new"))
    newest.item.lastCopiedAt = Date(timeIntervalSince1970: 40)

    let titles = Set(history.all.map(\.item.title))
    XCTAssertTrue(titles.contains("tagged"))
    XCTAssertTrue(titles.contains("mid"))
    XCTAssertTrue(titles.contains("new"))
    XCTAssertFalse(titles.contains("old"))
    XCTAssertEqual(tagged.item.tags, ["keep"])
    XCTAssertEqual(tagged.item.text, "tagged")
  }

  func testAssignTagDoesNotNeedSearchTokenOrVisibleRow() {
    let plain = history.add(historyItem("plain"))
    let kept = historyItem("kept")
    kept.tags = ["addr"]
    history.add(kept)
    history.tagFilter = "addr"

    XCTAssertFalse(history.items.contains { $0.item.title == "plain" })
    XCTAssertEqual(history.searchQuery, "")
    XCTAssertTrue(history.assignTag(plain, named: "note"))
    XCTAssertEqual(plain.item.tags, ["note"])
    XCTAssertFalse(history.items.contains { $0.item.title == "plain" })

    history.tagFilter = nil
    XCTAssertTrue(history.items.contains { $0.item.title == "plain" })
    XCTAssertFalse(history.assignTag(plain, named: "   "))
    XCTAssertFalse(history.assignTag(plain, named: "two words"))
    XCTAssertFalse(history.assignTag(plain, named: String(repeating: "a", count: 33)))
    XCTAssertTrue(history.assignTag(plain, named: "NOTE"))
    XCTAssertEqual(plain.item.tags, ["note"])
    XCTAssertTrue(history.removeTag(plain, named: "Note"))
    XCTAssertEqual(plain.item.tags, [])
  }

  func testCreateSnippetDoesNotTouchPasteboard() {
    let before = Clipboard.shared.changeCount
    let snippet = history.createSnippet(title: "Wifi", text: "lab-guest")
    XCTAssertEqual(snippet?.item.title, "Wifi")
    XCTAssertEqual(snippet?.item.text, "lab-guest")
    XCTAssertNotNil(snippet?.item.pin)
    XCTAssertEqual(Clipboard.shared.changeCount, before)
    XCTAssertFalse(Clipboard.shared.isMonitoring)
    XCTAssertNil(history.createSnippet(title: "empty", text: "  "))
  }

  func testSnippetSourceIsNotARealApp() {
    let snippet = history.createSnippet(title: "常用", text: "body")
    XCTAssertEqual(snippet?.item.application, LabRuntime.snippetSource)
    XCTAssertNotEqual(snippet?.item.application, "com.apple.finder")
  }

  func testTypeFilterIsSeparateFromUnfilteredSearch() {
    _ = history.add(historyItem("alpha"))
    history.typeFilter = nil
    XCTAssertTrue(history.items.contains { $0.item.title == "alpha" })
    history.typeFilter = .image
    XCTAssertFalse(history.items.contains { $0.item.title == "alpha" })
    history.typeFilter = nil
    XCTAssertTrue(history.items.contains { $0.item.title == "alpha" })
  }

  func testSnippetWithoutShortcutSurvivesClearAndCapacity() throws {
    for letter in HistoryItem.supportedPins {
      let occupied = historyItem("occupied-\(letter)")
      occupied.pin = letter
      _ = history.add(occupied)
    }
    XCTAssertEqual(HistoryItem.randomAvailablePin, "")

    let body = "\t  indented\n\n"
    let snippet = history.createSnippet(title: "  常用  ", text: body)
    let created = try XCTUnwrap(snippet)
    XCTAssertEqual(created.item.pin, "")
    XCTAssertEqual(created.item.text, body)
    XCTAssertEqual(created.item.title, "常用")
    XCTAssertFalse(created.item.isDisposable)
    XCTAssertTrue(created.shortcuts.isEmpty)
    XCTAssertTrue(history.all.contains { $0.item.title == "常用" })

    history.clear()
    XCTAssertTrue(history.all.contains { $0.item.title == "常用" && $0.item.text == body })
    XCTAssertFalse(history.all.contains { $0.item.isDisposable })

    Defaults[.size] = 1
    _ = history.add(historyItem("disposable-a"))
    _ = history.add(historyItem("disposable-b"))
    XCTAssertTrue(history.all.contains { $0.item.title == "常用" && $0.item.pin == "" })
    XCTAssertLessThanOrEqual(history.all.filter(\.item.isDisposable).count, 1)
  }

  func testClearKeepsPinlessSnippetAndClearAllDeletesIt() {
    let snippet = history.createSnippet(title: "常用", text: "body")
    XCTAssertNotNil(snippet)
    XCTAssertTrue(history.all.contains { $0.item.title == "常用" })
    history.clear()
    XCTAssertEqual(history.all.map(\.item.title), ["常用"])
    history.clearAll()
    XCTAssertTrue(history.all.isEmpty)
  }

  func testAssignTagRestoresWhenSaveFails() {
    let plain = history.add(historyItem("plain"))
    Storage.shared.saveImplementation = { throw CocoaError(.fileWriteUnknown) }
    XCTAssertFalse(history.assignTag(plain, named: "地址"))
    XCTAssertEqual(plain.item.tags, [])
    XCTAssertEqual(AppState.shared.storageError, NSLocalizedString("save_failed", comment: ""))
  }

  func testRemoveTagRestoresWhenSaveFails() {
    let plain = history.add(historyItem("plain"))
    XCTAssertTrue(history.assignTag(plain, named: "地址"))
    Storage.shared.saveImplementation = { throw CocoaError(.fileWriteUnknown) }
    XCTAssertFalse(history.removeTag(plain, named: "地址"))
    XCTAssertEqual(plain.item.tags, ["地址"])
    XCTAssertNotNil(AppState.shared.storageError)
  }

  func testCreateSnippetReturnsNilWhenSaveFails() {
    Storage.shared.saveImplementation = { throw CocoaError(.fileWriteUnknown) }
    XCTAssertNil(history.createSnippet(title: "Wifi", text: "lab-guest"))
    XCTAssertFalse(history.all.contains { $0.item.title == "Wifi" })
    XCTAssertNotNil(AppState.shared.storageError)
  }

  func testDuplicateMergeSavesExplicitly() throws {
    let first = history.add(historyItem("dup-body"))
    first.item.tags = ["keep"]
    var calls = 0
    Storage.shared.saveImplementation = {
      calls += 1
      try Storage.shared.context.save()
    }
    _ = history.add(historyItem("dup-body"))
    XCTAssertGreaterThanOrEqual(calls, 2)
    let stored = try Storage.shared.context.fetch(FetchDescriptor<HistoryItem>())
    XCTAssertTrue(stored.contains { $0.tags.contains("keep") && $0.text == "dup-body" })
  }

  func testMultiSelectCategoryDropMovesTheSelectionOnly() {
    let kept = history.add(historyItem("keep-alone"))
    let one = history.add(historyItem("batch-one"))
    let two = history.add(historyItem("batch-two"))
    XCTAssertTrue(history.assignTag(kept, named: "stay"))
    XCTAssertTrue(history.assignTag(one, named: "old"))
    XCTAssertTrue(history.assignTag(two, named: "old"))
    let nav = AppState.shared.navigator
    defer { nav.select(item: nil) }

    nav.select(item: one)
    nav.addToSelection(item: two)
    XCTAssertEqual(Set(AppState.shared.actionTargets(for: one).map(\.id)), Set([one.id, two.id]))
    XCTAssertEqual(AppState.shared.actionTargets(for: kept).map(\.id), [kept.id])
    XCTAssertFalse(AppState.shared.applyCategoryDrop(itemID: UUID(), name: "dest"))

    XCTAssertTrue(AppState.shared.applyCategoryDrop(itemID: one.id, name: "dest"))
    XCTAssertEqual(one.item.tags, ["dest"])
    XCTAssertEqual(two.item.tags, ["dest"])
    XCTAssertEqual(kept.item.tags, ["stay"])

    nav.select(item: one)
    XCTAssertEqual(AppState.shared.actionTargets(for: one).map(\.id), [one.id])
    AppState.shared.dropOutsideWindow(itemID: one.id)
    XCTAssertEqual(one.item.tags, [])
    XCTAssertEqual(two.item.tags, ["dest"])
    XCTAssertEqual(kept.item.tags, ["stay"])
  }

  func testEveryFailedPasteExplainsItselfAndOffersCopy() {
    let item = history.add(historyItem("prompt-every-time"))
    var asked: [ExplicitPasteFailure] = []
    var copies = 0
    var answer = AppState.PasteFailureChoice.cancel
    AppState.pasteFailureChoiceProbe = { failure in asked.append(failure); return answer }
    Clipboard.shared.copyProbe = { _, _ in copies += 1 }
    defer {
      AppState.pasteFailureChoiceProbe = nil
      Clipboard.shared.copyProbe = nil
      AppState.shared.pasteFailureAlertPresented = false
    }
    // Asked again after a cancel: there is no "don't ask for this launch" state.
    AppState.shared.presentPasteFailure(.accessibilityDenied, item: item, removeFormatting: false)
    AppState.shared.presentPasteFailure(.accessibilityDenied, item: item, removeFormatting: false)
    XCTAssertEqual(asked, [.accessibilityDenied, .accessibilityDenied])
    XCTAssertEqual(copies, 0, "cancel must not copy")
    answer = .copyOnly
    AppState.shared.presentPasteFailure(.noTarget, item: item, removeFormatting: true)
    XCTAssertEqual(copies, 1, "copy-only copies so the user can press ⌘V")
    XCTAssertFalse(AppState.shared.pasteFailureAlertPresented)

    for failure in [ExplicitPasteFailure.accessibilityDenied, .noTarget, .targetInvalid] {
      let copy = PasteFailureCopy(failure)
      XCTAssertFalse(copy.title.isEmpty)
      XCTAssertFalse(copy.message.isEmpty)
      XCTAssertNotEqual(copy.title, copy.message, "title and message must not repeat each other")
    }
    let denied = PasteFailureCopy(.accessibilityDenied).message
    XCTAssertTrue(denied.contains(Accessibility.displayName))
    XCTAssertFalse(denied.contains("/"), "no file paths in user-facing copy")
  }

  func testTagCreateErrorGrowsTheFormAndReportsTheSize() {
    let size = WorkspaceTagCreatePlacement.formSize(showsError: false)
    let form = WorkspaceTagCreateFormView(frame: NSRect(origin: .zero, size: size))
    let before = form.preferredSize
    let popover = NSPopover()
    popover.contentSize = before
    form.onSizeChange = { popover.contentSize = $0 }
    form.show("taken")
    XCTAssertGreaterThan(form.preferredSize.height, before.height)
    XCTAssertEqual(form.frame.size, form.preferredSize)
    XCTAssertEqual(popover.contentSize, form.preferredSize)
  }

  private func historyItem(_ value: String) -> HistoryItem {
    let contents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: value.data(using: .utf8)
      )
    ]
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = contents
    item.numberOfCopies = 1
    item.title = item.generateTitle()

    return item
  }
}

@MainActor
final class StorageIsolationTests: XCTestCase {
  func testSharedStorageIsInMemoryAndNotUpstream() {
    XCTAssertTrue(LabRuntime.isIsolated)
    XCTAssertTrue(Storage.shared.isInMemory)
    XCTAssertFalse(LabRuntime.isUpstreamStore(Storage.shared.url))
    XCTAssertTrue(Storage.shared.url.path.contains("Wit's Copy"))
    XCTAssertFalse(Storage.shared.url.path.hasSuffix("/Maccy/Storage.sqlite"))
  }

  func testTagsSurviveContainerRestartOnTempFile() throws {
    let dir = FileManager.default.temporaryDirectory
      .appending(path: "witscopy-lab-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appending(path: "Storage.sqlite")
    XCTAssertFalse(LabRuntime.isUpstreamStore(url))
    XCTAssertFalse(url.path.contains("/Application Support/"))

    try writeSample(to: url)
    let reopened = Storage(inMemory: false, url: url)
    let fetched = try reopened.context.fetch(FetchDescriptor<HistoryItem>())
    XCTAssertEqual(fetched.map(\.title), ["kept"])
    XCTAssertEqual(fetched.first?.tags, ["addr"])
    XCTAssertEqual(fetched.first?.text, "kept")
  }

  func testPinlessSnippetSurvivesFileRestart() throws {
    let dir = FileManager.default.temporaryDirectory
      .appending(path: "witscopy-lab-pin-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appending(path: "Storage.sqlite")
    XCTAssertFalse(LabRuntime.isUpstreamStore(url))
    XCTAssertFalse(url.path.contains("/Application Support/"))

    let body = "\t  indented\n\n"
    let storage = Storage(inMemory: false, url: url)
    let item = try XCTUnwrap(History.makeSnippetItem(title: "常用", text: body, pin: ""))
    storage.context.insert(item)
    try storage.context.save()

    let reopened = Storage(inMemory: false, url: url)
    let fetched = try reopened.context.fetch(FetchDescriptor<HistoryItem>())
    XCTAssertEqual(fetched.map(\.title), ["常用"])
    XCTAssertEqual(fetched.first?.pin, "")
    XCTAssertEqual(fetched.first?.text, body)
    XCTAssertEqual(fetched.first?.isDisposable, false)
    XCTAssertTrue(fetched.filter(\.isDisposable).isEmpty)
  }

  func testIsolatedNotificationsAreNoOp() {
    XCTAssertTrue(LabRuntime.isIsolated)
    Notifier.authorize()
    Notifier.notify(body: "synthetic isolated notification", sound: nil)
  }

  func testIsolatedSessionDoesNotStartOrClearPasteboard() {
    XCTAssertTrue(LabRuntime.isIsolated)
    let before = Clipboard.shared.changeCount
    Clipboard.shared.start()
    Clipboard.shared.restart()
    let saved = Defaults[.clearSystemClipboard]
    Defaults[.clearSystemClipboard] = true
    Clipboard.shared.clear()
    Defaults[.clearSystemClipboard] = saved
    XCTAssertFalse(Clipboard.shared.isMonitoring)
    XCTAssertEqual(Clipboard.shared.changeCount, before)
  }

  private func writeSample(to url: URL) throws {
    let storage = Storage(inMemory: false, url: url)
    let item = HistoryItem(contents: [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: Data("kept".utf8)
      )
    ])
    item.title = "kept"
    item.tags = ["addr"]
    storage.context.insert(item)
    try storage.context.save()
  }
}

@MainActor
final class PanelFloorTests: XCTestCase {
  func testShortContentDoesNotCollapseBelowVisualFloor() {
    let saved = Defaults[.windowSize]
    Defaults[.windowSize] = NSSize(width: 620, height: 800)
    defer { Defaults[.windowSize] = saved }
    let popup = Popup()
    let height = popup.preferredHeight(for: 40)
    let screen = NSScreen.main?.visibleFrame.height ?? 900
    let floor = min(Popup.visualMinimumHeight, max(280, screen - 48))
    XCTAssertGreaterThanOrEqual(height, floor)
    XCTAssertGreaterThanOrEqual(height, 480)
    XCTAssertLessThanOrEqual(height, 800)
  }
}

@MainActor
final class PanelSplitTests: XCTestCase {
  func testWideScreenKeepsSavedSplit() {
    let fitted = standardPanelSplit.fitted(availableWidth: 1600, availableHeight: 1000)
    XCTAssertEqual(fitted.listWidth, PanelSplit.defaultList)
    XCTAssertEqual(fitted.previewWidth, 620)
    XCTAssertEqual(fitted.totalWidth, PanelSplit.defaultList + 620)
  }

  func testTightScreenScalesWithoutDroppingTheList() {
    let fitted = standardPanelSplit.fitted(availableWidth: 700, availableHeight: 800)
    XCTAssertGreaterThanOrEqual(fitted.listWidth, PanelSplit.minimumList)
    XCTAssertLessThan(fitted.totalWidth, 940)
    XCTAssertLessThanOrEqual(fitted.totalWidth, 700 - 32)
  }

  func testCollapsedWidthIsListOnly() {
    var split = standardPanelSplit
    split.previewOpen = false
    let fitted = split.fitted(availableWidth: 1600, availableHeight: 1000)
    XCTAssertEqual(fitted.totalWidth, PanelSplit.defaultList)
    XCTAssertFalse(fitted.previewOpen)
  }

  func testDividerDragKeepsOuterWidth() {
    let split = standardPanelSplit
    let moved = split.redistributed(previewDelta: 40, totalWidth: split.totalWidth)
    XCTAssertEqual(moved.totalWidth, split.totalWidth)
    XCTAssertEqual(moved.previewWidth, 660)
    XCTAssertEqual(moved.listWidth, PanelSplit.defaultList + 620 - 660)
    XCTAssertGreaterThanOrEqual(moved.previewWidth, PanelSplit.preferredPreviewFloor)
  }

  func testContentHeightDoesNotChangePreferredFrame() {
    Defaults[.windowSize] = NSSize(width: 320, height: 640)
    let popup = Popup()
    XCTAssertEqual(popup.preferredHeight(for: 40), popup.preferredHeight(for: 900))
  }

  func testSavedHeight500DoesNotJumpTo640() {
    let saved = geometryDefaults()
    defer { restore(saved) }
    Defaults[.windowSize] = NSSize(width: 320, height: 500)
    Defaults[.listColumnWidth] = 320
    Defaults[.previewColumnWidth] = 620
    Defaults[.openPreviewAutomatically] = true

    let controller = SlideoutController()
    XCTAssertEqual(controller.savedSplit().height, 500)
    controller.applyLayout(screen: nil)
    XCTAssertEqual(controller.currentHeight, 500)
    XCTAssertEqual(controller.layoutListWidth, 320)
    XCTAssertEqual(controller.layoutPreviewWidth, 620)
    controller.applyLayout(screen: nil)
    XCTAssertEqual(controller.currentHeight, 500)
    XCTAssertEqual(controller.layoutListWidth, 320)
    XCTAssertEqual(controller.layoutPreviewWidth, 620)
  }

  func testInvalidSavedHeightFallsBackToDefault() {
    let saved = geometryDefaults()
    defer { restore(saved) }
    Defaults[.windowSize] = NSSize(width: 320, height: 0)
    XCTAssertEqual(SlideoutController().savedSplit().height, 640)
    Defaults[.windowSize] = NSSize(width: 320, height: -20)
    XCTAssertEqual(SlideoutController().savedSplit().height, 640)
    Defaults[.windowSize] = NSSize(width: 320, height: 500)
    XCTAssertEqual(SlideoutController().savedSplit().height, 500)
  }

  func testFilterDoesNotChangeWidthOrHeight() {
    let saved = geometryDefaults()
    defer { restore(saved) }
    Defaults[.windowSize] = NSSize(width: 320, height: 500)
    let split = PanelSplit(listWidth: 320, previewWidth: 620, previewOpen: true, height: 500)
    let shown = split.fitted(availableWidth: 1600, availableHeight: 1000)
    XCTAssertEqual(shown.listWidth, 320)
    XCTAssertEqual(shown.previewWidth, 620)
    XCTAssertEqual(shown.height, 500)
    XCTAssertEqual(shown, split.fitted(availableWidth: 1600, availableHeight: 1000))

    let popup = Popup()
    let empty = popup.preferredHeight(for: 0)
    let filtered = popup.preferredHeight(for: 4000)
    XCTAssertEqual(empty, filtered)
    XCTAssertLessThan(empty, 640)
    XCTAssertLessThanOrEqual(empty, 500)
  }

  func testExpandingAtRightEdgeStaysOnScreen() {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let collapsed = CGRect(x: 1120, y: 200, width: 320, height: 500)
    let split = PanelSplit(listWidth: 320, previewWidth: 620, previewOpen: false, height: 500)
    let opened = split.frameAfterSettingPreview(open: true, from: collapsed, in: screen)
    XCTAssertEqual(opened.split.listWidth, 320)
    XCTAssertEqual(opened.split.previewWidth, 620)
    XCTAssertEqual(opened.split.height, 500)
    XCTAssertEqual(opened.frame, CGRect(x: 500, y: 200, width: 940, height: 500))
    XCTAssertLessThanOrEqual(opened.frame.maxX, screen.maxX)
    XCTAssertGreaterThanOrEqual(opened.frame.minX, screen.minX)
  }

  func testExpandedRailWidensWindowWithoutChangingListColumn() {
    let visible = Defaults[.managementRailVisible]
    let width = Defaults[.managementRailWidth]
    defer {
      Defaults[.managementRailVisible] = visible
      Defaults[.managementRailWidth] = width
    }
    Defaults[.managementRailVisible] = true
    Defaults[.managementRailWidth] = 108
    let extra = 108 - PanelSplit.navigationRailWidth
    let controller = SlideoutController()
    controller.layoutListWidth = 520
    controller.layoutPreviewWidth = 620
    XCTAssertEqual(controller.railExtraWidth, extra)
    // 左栏向外展开：窗口多出 72pt，条目列（layoutListWidth）不变。
    XCTAssertEqual(controller.contentWidth, 520 + extra)
    XCTAssertEqual(controller.layoutListWidth, 520, "content width baked the rail into the list")

    let screen = CGRect(x: 0, y: 0, width: 2000, height: 900)
    let collapsed = CGRect(x: 200, y: 200, width: 320 + extra, height: 500)
    let split = PanelSplit(listWidth: 320, previewWidth: 620, previewOpen: false, height: 500)
    let opened = split.frameAfterSettingPreview(open: true, from: collapsed, in: screen, railExtra: extra)
    XCTAssertEqual(opened.split.listWidth, 320)
    XCTAssertEqual(opened.frame.width, 320 + extra + 620)
    let closed = opened.split.frameAfterSettingPreview(open: false, from: opened.frame, in: screen, railExtra: extra)
    XCTAssertEqual(closed.split.listWidth, 320)
    XCTAssertEqual(closed.frame.width, 320 + extra)

    XCTAssertFalse(PanelLiveResize.absorbsSplit(inLiveResize: true, railVisible: true, minXDelta: -40))
    XCTAssertTrue(PanelLiveResize.absorbsSplit(inLiveResize: true, railVisible: true, minXDelta: 0))
    XCTAssertTrue(PanelLiveResize.absorbsSplit(inLiveResize: false, railVisible: true, minXDelta: -40))
    XCTAssertTrue(PanelLiveResize.absorbsSplit(inLiveResize: true, railVisible: false, minXDelta: -40))
  }

  func testExpandingAtNegativeScreenEdgeStaysInside() {
    let screen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    let collapsed = CGRect(x: -320, y: 100, width: 320, height: 500)
    let split = PanelSplit(listWidth: 320, previewWidth: 620, previewOpen: false, height: 500)
    let opened = split.frameAfterSettingPreview(open: true, from: collapsed, in: screen)
    XCTAssertEqual(opened.frame, CGRect(x: -940, y: 100, width: 940, height: 500))
    XCTAssertEqual(opened.split.height, 500)
    XCTAssertEqual(opened.split.listWidth, 320)
    XCTAssertLessThanOrEqual(opened.frame.maxX, screen.maxX)
    XCTAssertGreaterThanOrEqual(opened.frame.minX, screen.minX)
  }

  func testTinyScreenDoesNotExceedAvailableMargin() {
    let fitted = standardPanelSplit.fitted(availableWidth: 300, availableHeight: 200)
    XCTAssertLessThanOrEqual(fitted.totalWidth, 268)
    XCTAssertLessThanOrEqual(fitted.height, 168)
    XCTAssertGreaterThan(fitted.totalWidth, 0)
    XCTAssertGreaterThan(fitted.height, 0)

    let smallerThanMargin = standardPanelSplit.fitted(availableWidth: 20, availableHeight: 20)
    XCTAssertLessThanOrEqual(smallerThanMargin.totalWidth, 20)
    XCTAssertLessThanOrEqual(smallerThanMargin.height, 20)
  }

  func testResizeFloorMatchesFittedRule() {
    XCTAssertEqual(PanelSplit.previewFloor(availableWidth: 1600, listWidth: 320), 480)
    let raised = PanelSplit(listWidth: 320, previewWidth: 200, previewOpen: true, height: 500)
      .fitted(availableWidth: 1600, availableHeight: 1000)
    XCTAssertEqual(raised.previewWidth, 480)
    XCTAssertEqual(raised.listWidth, 320)

    XCTAssertEqual(PanelSplit.previewFloor(availableWidth: 700, listWidth: 320), 200)
    let compact = PanelSplit(listWidth: 320, previewWidth: 220, previewOpen: true, height: 500)
      .fitted(availableWidth: 700, availableHeight: 800)
    XCTAssertEqual(compact.previewWidth, 220)
    XCTAssertLessThan(compact.previewWidth, 480)

    let split = PanelSplit(listWidth: 320, previewWidth: 620, previewOpen: true, height: 500)
    let absorbed = split.absorbing(totalWidth: 900, previewFloor: 480)
    XCTAssertEqual(absorbed.totalWidth, 900)
    XCTAssertEqual(absorbed.listWidth, 320)
    XCTAssertEqual(absorbed.previewWidth, 580)
    XCTAssertEqual(absorbed.height, 500)
  }

  func testDividerDragRemembersPrefsWithoutChangingHeight() {
    let saved = geometryDefaults()
    defer { restore(saved) }
    let moved = PanelSplit(listWidth: 320, previewWidth: 620, previewOpen: true, height: 500)
      .redistributed(previewDelta: -40, totalWidth: 940)
    XCTAssertEqual(moved.totalWidth, 940)
    XCTAssertEqual(moved.listWidth, 360)
    XCTAssertEqual(moved.previewWidth, 580)
    XCTAssertEqual(moved.height, 500)

    Defaults[.listColumnWidth] = moved.listWidth
    Defaults[.previewColumnWidth] = moved.previewWidth
    Defaults[.windowSize] = NSSize(width: 320, height: 500)
    Defaults[.openPreviewAutomatically] = true
    let restored = SlideoutController().savedSplit()
    XCTAssertEqual(restored.listWidth, 360)
    XCTAssertEqual(restored.previewWidth, 580)
    XCTAssertEqual(restored.height, 500)
  }

  func testLastAnchorRoundTripDoesNotShiftByPreviewHalf() {
    let screen = CGRect(x: -1600, y: 0, width: 1600, height: 1024)
    let frame = CGRect(x: -960, y: 0, width: 940, height: 512)
    let anchor = PanelSplit.relativeAnchor(of: frame, listWidth: 320, in: screen)
    let restored = PanelSplit.constrainedFrame(
      size: frame.size,
      listWidth: 320,
      relativeAnchor: anchor,
      in: screen
    )
    XCTAssertEqual(restored, frame)

    let driftedX = screen.minX + screen.width * anchor.x - frame.width / 2
    XCTAssertEqual(frame.minX - driftedX, 310)
  }

  func testNegativeOriginScreenFitsAndPlaces() {
    let savedRail = Defaults[.managementRailVisible]
    Defaults[.managementRailVisible] = false
    defer { Defaults[.managementRailVisible] = savedRail }

    let main = PopupScreenBox(
      frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
      visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860)
    )
    let left = PopupScreenBox(
      frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
      visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    )
    var context = PopupPlacementContext(
      screens: [main, left],
      mouseLocation: CGPoint(x: -1500, y: 400),
      explicitScreen: 1,
      activeScreenIndex: 0,
      statusItemScreenIndex: nil,
      statusItemFrame: nil,
      frontmostWindowFrame: nil,
      savedAnchor: CGPoint(x: 0.5, y: 0.8)
    )

    let cursor = PopupPosition.cursor.layout(saved: standardPanelSplit, in: context)
    XCTAssertEqual(PopupPosition.cursor.targetScreen(in: context)?.frame.minX, -1920)
    let placedWidth = standardPanelSplit.totalWidth
    XCTAssertEqual(cursor.frame, CGRect(x: -1500, y: 0, width: placedWidth, height: 640))
    XCTAssertLessThan(cursor.frame.midX, 0)

    context.explicitScreen = 2
    context.mouseLocation = CGPoint(x: 200, y: 200)
    let center = PopupPosition.center.layout(saved: standardPanelSplit, in: context)
    XCTAssertEqual(PopupPosition.center.targetScreen(in: context)?.frame.minX, -1920)
    XCTAssertEqual(center.frame.origin, CGPoint(x: -1529, y: 221))
    XCTAssertEqual(center.frame.size, CGSize(width: placedWidth, height: 640))
    XCTAssertLessThanOrEqual(center.frame.maxX, left.visibleFrame.maxX)
    XCTAssertGreaterThanOrEqual(center.frame.minX, left.visibleFrame.minX)

    context.frontmostWindowFrame = CGRect(x: -400, y: 200, width: 500, height: 400)
    context.explicitScreen = 1
    let windowed = PopupPosition.window.layout(saved: standardPanelSplit, in: context)
    XCTAssertEqual(PopupPosition.window.targetScreen(in: context)?.frame.minX, -1920)
    XCTAssertEqual(windowed.frame, CGRect(x: -placedWidth, y: 81, width: placedWidth, height: 640))
    XCTAssertLessThanOrEqual(windowed.frame.maxX, 0)
    XCTAssertGreaterThanOrEqual(windowed.frame.minX, -1920)

    context.statusItemScreenIndex = 1
    context.statusItemFrame = CGRect(x: -100, y: 1080, width: 24, height: 24)
    context.mouseLocation = CGPoint(x: 120, y: 120)
    let status = PopupPosition.statusItem.layout(saved: standardPanelSplit, in: context)
    XCTAssertEqual(PopupPosition.statusItem.targetScreen(in: context)?.frame.minX, -1920)
    XCTAssertEqual(status.frame, CGRect(x: -placedWidth, y: 440, width: placedWidth, height: 640))
    XCTAssertLessThanOrEqual(status.frame.maxX, left.visibleFrame.maxX)

    let anchorScreen = CGRect(x: -1600, y: 0, width: 1600, height: 1024)
    let savedFrame = CGRect(x: -960, y: 0, width: 940, height: 512)
    context.screens[1] = PopupScreenBox(frame: anchorScreen, visibleFrame: anchorScreen)
    context.explicitScreen = 2
    context.savedAnchor = PanelSplit.relativeAnchor(of: savedFrame, listWidth: 320, in: anchorScreen)
    let last = PopupPosition.lastPosition.layout(
      saved: PanelSplit(listWidth: 320, previewWidth: 620, previewOpen: true, height: 512),
      in: context
    )
    XCTAssertEqual(last.frame, savedFrame)
    XCTAssertEqual(last.split.height, 512)
    XCTAssertEqual(last.split.listWidth, 320)
    XCTAssertEqual(last.split.previewWidth, 620)

    let huge = PanelSplit.constrainedFrame(
      size: CGSize(width: 4000, height: 3000),
      listWidth: 320,
      relativeAnchor: CGPoint(x: 1.4, y: 1.4),
      in: CGRect(x: -800, y: -100, width: 300, height: 200)
    )
    XCTAssertEqual(huge, CGRect(x: -800, y: -100, width: 300, height: 200))
  }

  func testCursorOnSmallNegativeScreenFitsThatScreen() {
    let main = PopupScreenBox(
      frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
      visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860)
    )
    let left = PopupScreenBox(
      frame: CGRect(x: -900, y: -20, width: 900, height: 500),
      visibleFrame: CGRect(x: -900, y: 0, width: 700, height: 360)
    )
    let context = PopupPlacementContext(
      screens: [main, left],
      mouseLocation: CGPoint(x: -500, y: 100),
      explicitScreen: 1,
      activeScreenIndex: 0,
      statusItemScreenIndex: nil,
      statusItemFrame: nil,
      frontmostWindowFrame: nil,
      savedAnchor: CGPoint(x: 0.5, y: 0.8)
    )
    let placed = PopupPosition.cursor.layout(saved: standardPanelSplit, in: context)
    XCTAssertEqual(PopupPosition.cursor.targetScreen(in: context)?.visibleFrame, left.visibleFrame)
    XCTAssertLessThanOrEqual(placed.split.totalWidth, 668)
    XCTAssertLessThanOrEqual(placed.split.height, 328)
    XCTAssertLessThan(placed.split.totalWidth, 940)
    XCTAssertLessThan(placed.split.height, 640)
    XCTAssertLessThanOrEqual(placed.frame.maxX, left.visibleFrame.maxX)
    XCTAssertGreaterThanOrEqual(placed.frame.minX, left.visibleFrame.minX)
    XCTAssertLessThanOrEqual(placed.frame.maxY, left.visibleFrame.maxY)
    XCTAssertGreaterThanOrEqual(placed.frame.minY, left.visibleFrame.minY)
  }

  private func geometryDefaults() -> (NSSize, CGFloat, CGFloat, Bool) {
    (
      Defaults[.windowSize],
      Defaults[.listColumnWidth],
      Defaults[.previewColumnWidth],
      Defaults[.openPreviewAutomatically]
    )
  }

  private func restore(_ saved: (NSSize, CGFloat, CGFloat, Bool)) {
    Defaults[.windowSize] = saved.0
    Defaults[.listColumnWidth] = saved.1
    Defaults[.previewColumnWidth] = saved.2
    Defaults[.openPreviewAutomatically] = saved.3
  }

  func testSavedLegacyListWidthIsNotMigrated() {
    let saved = geometryDefaults()
    defer { restore(saved) }
    Defaults[.listColumnWidth] = 320
    Defaults[.previewColumnWidth] = 620
    Defaults[.windowSize] = NSSize(width: 320, height: 500)
    let controller = SlideoutController()
    XCTAssertEqual(controller.savedSplit().listWidth, 320)
    controller.applyLayout(screen: nil)
    XCTAssertEqual(controller.layoutListWidth, 320)
    XCTAssertNotEqual(controller.layoutListWidth, PanelSplit.defaultList)
  }
}

final class IconPressProbe: NSObject {
  var fires = 0
  @objc func fire(_ sender: Any?) { fires += 1 }
}

@MainActor
final class WorkspacePolicyTests: XCTestCase {
  let history = History.shared

  override func setUp() {
    super.setUp()
    history.clearAll()
    AppState.shared.windowPinned = false
    AppState.shared.workspaceSection = .all
    AppState.shared.panelPresented = false
    AppState.shared.tagEditorItem = nil
    AppState.shared.preview.state = .open
    Clipboard.shared.copyProbe = nil
    history.searchQuery = ""
    history.tagFilter = nil
    history.typeFilter = nil
  }

  override func tearDown() {
    Clipboard.shared.copyProbe = nil
    AppState.shared.windowPinned = false
    AppState.shared.workspaceSection = .all
    AppState.shared.panelPresented = false
    AppState.shared.tagEditorItem = nil
    history.searchQuery = ""
    history.tagFilter = nil
    history.typeFilter = nil
    super.tearDown()
  }

  func testPanelOpenRestoresThePreviousSelection() {
    _ = history.add(historyItem("first"))
    let second = history.add(historyItem("second"))
    AppState.shared.navigator.select(item: second)

    AppState.shared.selectOnPanelOpen()
    XCTAssertEqual(AppState.shared.navigator.leadHistoryItem?.id, second.id)
  }

  func testPanelOpenFallsBackWhenThePreviousItemWasCleared() {
    let keep = history.add(historyItem("keep"))
    keep.item.pin = "k"
    let removed = history.add(historyItem("removed"))
    AppState.shared.navigator.select(item: removed)

    history.clear()
    XCTAssertFalse(history.items.contains { $0.id == removed.id })

    AppState.shared.selectOnPanelOpen()
    XCTAssertEqual(AppState.shared.navigator.leadHistoryItem?.id, keep.id)
  }

  func testSingleClickSelectsAndDoubleClickPastesWithoutPriorSelection() {
    XCTAssertNil(WorkspacePointer.bodyAction(clickCount: 0))
    XCTAssertEqual(WorkspacePointer.bodyAction(clickCount: 1), .select)
    XCTAssertEqual(WorkspacePointer.bodyAction(clickCount: 2), .commit)
    XCTAssertEqual(WorkspacePointer.bodyAction(clickCount: 3), .commit)
    XCTAssertNil(WorkspacePointer.hoverAction())

    let item = history.add(historyItem("alpha"))
    let other = history.add(historyItem("beta"))
    var copies: [ObjectIdentifier] = []
    Clipboard.shared.copyProbe = { id, _ in copies.append(id) }
    AppState.shared.panelPresented = true
    AppState.shared.navigator.select(item: nil)

    // A single click only selects: no copy, panel stays.
    AppState.shared.handleRowClick(item, clickCount: 1)
    XCTAssertEqual(copies.count, 0)
    XCTAssertTrue(AppState.shared.panelPresented)
    XCTAssertEqual(AppState.shared.navigator.leadHistoryItem?.id, item.id)

    // A double-click on a row that was never selected goes straight to paste.
    AppState.shared.navigator.select(item: nil)
    Clipboard.shared.lastExplicitPasteResult = nil
    AppState.shared.handleRowClick(other, clickCount: 2)
    XCTAssertTrue(LabRuntime.isIsolated)
    XCTAssertEqual(copies.count, 0, "isolated explicit paste must not copy or call history.select")
    XCTAssertEqual(Clipboard.shared.lastExplicitPasteResult, .suppressed)
    XCTAssertTrue(AppState.shared.panelPresented, "isolated suppression must not be treated as a verified paste or hide")
  }

  func testCrossRowSingleClicksSelectTheLastRowWithoutCommit() {
    let first = history.add(historyItem("row-a"))
    let second = history.add(historyItem("row-b"))
    let third = history.add(historyItem("row-c"))
    var copies = 0
    Clipboard.shared.copyProbe = { _, _ in copies += 1 }
    AppState.shared.panelPresented = true
    AppState.shared.navigator.select(item: nil)
    Clipboard.shared.lastExplicitPasteResult = nil

    AppState.shared.handleRowClick(first, clickCount: 1)
    AppState.shared.handleRowClick(second, clickCount: 1)
    AppState.shared.handleRowClick(third, clickCount: 1)
    XCTAssertEqual(copies, 0)
    XCTAssertNil(Clipboard.shared.lastExplicitPasteResult, "single clicks must never reach paste")
    XCTAssertTrue(AppState.shared.panelPresented)
    XCTAssertEqual(AppState.shared.navigator.leadHistoryItem?.id, third.id)
    XCTAssertFalse(first.isSelected)
    XCTAssertFalse(second.isSelected)
    XCTAssertTrue(third.isSelected)
  }

  func testRailTagSelectionFiltersWithoutTogglingOff() {
    let kept = history.add(historyItem("kept-body"))
    let other = history.add(historyItem("other-body"))
    XCTAssertTrue(history.assignTag(kept, named: "addr"))
    XCTAssertTrue(history.assignTag(other, named: "work"))
    AppState.shared.workspaceSection = .pins

    WorkspaceRailPolicy.selectTag("addr", in: AppState.shared)
    XCTAssertEqual(AppState.shared.workspaceSection, .all)
    XCTAssertEqual(history.tagFilter, "addr")
    XCTAssertEqual(Set(history.items.map(\.item.title)), ["kept-body"])

    WorkspaceRailPolicy.selectTag("addr", in: AppState.shared)
    XCTAssertEqual(history.tagFilter, "addr")
    XCTAssertEqual(Set(history.items.map(\.item.title)), ["kept-body"])

    WorkspaceRailPolicy.selectAll(AppState.shared)
    XCTAssertEqual(AppState.shared.workspaceSection, .all)
    XCTAssertNil(history.tagFilter)
    XCTAssertEqual(Set(history.items.map(\.item.title)), ["kept-body", "other-body"])
  }

  func testRepeatedAllPinsTagTransitionsKeepExpectedVisibleIdentities() {
    let pin = historyItem("transition-pin")
    pin.pin = "p"
    let pinned = history.add(pin)
    let tagged = history.add(historyItem("transition-tagged"))
    let loose = history.add(historyItem("transition-loose"))
    XCTAssertTrue(history.assignTag(tagged, named: "transition"))
    let allIDs = Set([pinned.id, tagged.id, loose.id])

    // Follow the rail's actual assignment order, without a manual refresh that
    // could conceal a missing observation or leave the old category in effect.
    for _ in 0..<12 {
      WorkspaceRailPolicy.selectAll(AppState.shared)
      XCTAssertEqual(Set(history.items.filter(\.isVisible).map(\.id)), allIDs)
      WorkspaceRailPolicy.selectTag("transition", in: AppState.shared)
      XCTAssertEqual(history.items.filter(\.isVisible).map(\.id), [tagged.id])
      AppState.shared.workspaceSection = .pins
      history.tagFilter = nil
      XCTAssertEqual(AppState.shared.workspaceSection, .all)
      XCTAssertEqual(Set(history.items.filter(\.isVisible).map(\.id)), allIDs)
      WorkspaceRailPolicy.selectTag("transition", in: AppState.shared)
      XCTAssertEqual(history.items.filter(\.isVisible).map(\.id), [tagged.id])
      XCTAssertEqual(Set(history.all.map(\.id)), allIDs)
    }
  }

  func testRailTagRenameMergeAndDeleteKeepItemsAndSelection() {
    let one = history.add(historyItem("keep-body"))
    let two = history.add(historyItem("other-body"))
    let loose = history.add(historyItem("untagged-body"))
    XCTAssertTrue(history.assignTag(one, named: "old"))
    XCTAssertTrue(history.assignTag(two, named: "old"))
    XCTAssertTrue(history.assignTag(two, named: "dest"))
    let count = history.all.count
    WorkspaceRailPolicy.selectTag("work", in: AppState.shared)

    XCTAssertFalse(WorkspaceRailPolicy.rename("old", to: "bad name", in: AppState.shared))
    XCTAssertEqual(history.tagFilter, "work")
    XCTAssertEqual(one.item.tags, ["old"])
    XCTAssertEqual(
      WorkspaceRailPolicy.editFailureMessage(storageError: nil),
      NSLocalizedString("tag_edit_failed", comment: "")
    )
    XCTAssertEqual(WorkspaceRailPolicy.editFailureMessage(storageError: "disk"), "disk")

    XCTAssertTrue(WorkspaceRailPolicy.rename("old", to: "fresh", in: AppState.shared))
    XCTAssertEqual(history.all.count, count)
    XCTAssertEqual(one.item.text, "keep-body")
    XCTAssertEqual(one.item.tags, ["fresh"])
    XCTAssertEqual(two.item.tags, ["fresh", "dest"])
    XCTAssertEqual(AppState.shared.workspaceSection, .all)
    XCTAssertEqual(history.tagFilter, "fresh")
    XCTAssertEqual(Set(history.items.map(\.item.title)), ["keep-body", "other-body"])

    XCTAssertTrue(WorkspaceRailPolicy.merge("fresh", into: "dest", in: AppState.shared))
    XCTAssertEqual(history.all.count, count)
    XCTAssertEqual(one.item.tags, ["dest"])
    XCTAssertEqual(two.item.tags, ["dest"])
    XCTAssertEqual(one.item.text, "keep-body")
    XCTAssertEqual(history.tagFilter, "dest")
    XCTAssertFalse(history.items.contains(loose))

    XCTAssertTrue(WorkspaceRailPolicy.delete("dest", in: AppState.shared))
    XCTAssertEqual(history.all.count, count)
    XCTAssertNil(history.tagFilter)
    XCTAssertEqual(AppState.shared.workspaceSection, .all)
    XCTAssertTrue(one.item.tags.isEmpty)
    XCTAssertTrue(two.item.tags.isEmpty)
    XCTAssertEqual(one.item.text, "keep-body")
    XCTAssertEqual(two.item.text, "other-body")
    XCTAssertEqual(loose.item.text, "untagged-body")
    XCTAssertTrue(history.items.contains(one))
    XCTAssertTrue(history.items.contains(loose))
  }

  func testRailTagGlyphKeepsTheFirstGraphemeAndCase() {
    XCTAssertEqual(WorkspaceRailPolicy.accessibilityIdentifier(for: "地址"), "lab-rail-tag-地址")
    XCTAssertTrue(WorkspaceRailPolicy.isTagSelected("Addr", tagFilter: "addr"))
    XCTAssertFalse(WorkspaceRailPolicy.isAllSelected(section: .all, tagFilter: "addr"))
    XCTAssertTrue(WorkspaceRailPolicy.isAllSelected(section: .all, tagFilter: nil))
    XCTAssertTrue(WorkspaceRailPolicy.isPinsSelected(section: .pins, tagFilter: nil))
    XCTAssertFalse(WorkspaceRailPolicy.isPinsSelected(section: .pins, tagFilter: "addr"))
    let section = AppState.shared.workspaceSection
    let filter = AppState.shared.history.tagFilter
    defer {
      AppState.shared.workspaceSection = section
      AppState.shared.history.tagFilter = filter
    }
    AppState.shared.workspaceSection = .pins
    WorkspaceRailPolicy.selectTag("addr", in: AppState.shared)
    XCTAssertEqual(AppState.shared.workspaceSection, .all)
    XCTAssertEqual(AppState.shared.history.tagFilter, "addr")
    XCTAssertFalse(
      WorkspaceRailPolicy.isPinsSelected(section: .pins, tagFilter: AppState.shared.history.tagFilter)
    )
    let zh = try? labSource("WitsCopy/zh-Hans.lproj/Localizable.strings")
    XCTAssertTrue(zh?.contains("重命名…") == true)
    XCTAssertTrue(zh?.contains("合并到…") == true)
    XCTAssertTrue(zh?.contains("删除标签…") == true)
    XCTAssertTrue(zh?.contains("只删除标签名，内容保留。") == true)
  }

  func testKeyboardCommitStillCopiesOnce() {
    let item = history.add(historyItem("keyed"))
    var copies = 0
    Clipboard.shared.copyProbe = { _, _ in copies += 1 }
    AppState.shared.navigator.select(item: item)
    AppState.shared.select(flags: [])
    XCTAssertEqual(copies, 1)
  }

  func testPinnedCopyStaysOpenAndKeepsQuery() {
    let item = history.add(historyItem("stay"))
    history.searchQuery = "stay"
    history.refreshVisibleItems(highlightFirst: false)
    AppState.shared.panelPresented = true
    AppState.shared.windowPinned = true
    var copies = 0
    Clipboard.shared.copyProbe = { _, _ in copies += 1 }

    history.select(item, flags: [])
    XCTAssertEqual(copies, 1)
    XCTAssertTrue(AppState.shared.panelPresented)
    XCTAssertEqual(history.searchQuery, "stay")

    history.select(item, flags: [])
    XCTAssertEqual(copies, 2)
    XCTAssertTrue(AppState.shared.panelPresented)
    XCTAssertEqual(history.searchQuery, "stay")
  }

  func testUnpinnedCopyCloses() {
    let item = history.add(historyItem("gone"))
    AppState.shared.panelPresented = true
    AppState.shared.windowPinned = false
    history.select(item, flags: [])
    XCTAssertFalse(AppState.shared.panelPresented)
  }

  func testFocusCloseTable() {
    let plain = PanelFocusContext()
    let pinned = PanelFocusContext(windowPinned: true)
    let popover = PanelFocusContext(tagPopoverPresented: true)
    let confirmation = PanelFocusContext(confirmationPresented: true)
    let rows: [(PanelDismissReason, PanelFocusContext, PanelCloseDecision)] = [
      (.resignKey, plain, .close),
      (.resignKey, pinned, .stay),
      (.resignKey, popover, .stay),
      (.resignKey, confirmation, .stay),
      (.externalClick, plain, .close),
      (.externalClick, pinned, .stay),
      (.copyCommit, plain, .close),
      (.copyCommit, pinned, .stay),
      (.externalHandoff, plain, .close),
      (.externalHandoff, pinned, .stay),
      (.escape, pinned, .close),
      (.explicit, pinned, .close),
      (.settings, plain, .close),
      (.settings, pinned, .stayAndYieldToSettings)
    ]
    XCTAssertTrue(PanelEventOrdering.defersWindowOrdering(.mouseEvent(
      with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
    )))
    XCTAssertFalse(PanelEventOrdering.defersWindowOrdering(nil))
    for row in rows {
      XCTAssertEqual(PanelClosePolicy.decide(row.0, context: row.1), row.2, "\(row.0) \(row.1)")
    }
    XCTAssertFalse(PanelClosePolicy.clearsSearchOnBackground(windowPinned: true, panelPresented: true))
    XCTAssertTrue(PanelClosePolicy.clearsSearchOnBackground(windowPinned: true, panelPresented: false))
    XCTAssertFalse(PanelClosePolicy.treatsResignAsBackground(windowPinned: true, panelPresented: true))
  }

  func testRowActionsHitTheTargetAndDoNotCopy() {
    let selected = history.add(historyItem("selected"))
    let target = history.add(historyItem("target"))
    AppState.shared.navigator.select(item: selected)
    var copies = 0
    Clipboard.shared.copyProbe = { _, _ in copies += 1 }
    AppState.shared.panelPresented = true

    AppState.shared.performRowAction(.pin, on: target)
    XCTAssertTrue(target.isPinned)
    XCTAssertFalse(selected.isPinned)
    XCTAssertEqual(copies, 0)
    XCTAssertTrue(AppState.shared.panelPresented)
    XCTAssertEqual(history.searchQuery, "")
    XCTAssertEqual(AppState.shared.workspaceSection, .all)

    AppState.shared.performRowAction(.tag, on: target)
    XCTAssertEqual(AppState.shared.tagEditorItem?.id, target.id)
    XCTAssertEqual(AppState.shared.tagEditorAnchor, .row)
    XCTAssertTrue(AppState.shared.presentsTagEditor(target, at: .row))
    XCTAssertFalse(AppState.shared.presentsTagEditor(target, at: .preview))
    XCTAssertEqual(copies, 0)

    let savedDeletePrompt = DeleteItemConfirmationStore.isSuppressed
    DeleteItemConfirmationStore.isSuppressed = true
    defer { DeleteItemConfirmationStore.isSuppressed = savedDeletePrompt }
    AppState.shared.performRowAction(.delete, on: target)
    XCTAssertNil(AppState.shared.tagEditorItem)
    XCTAssertFalse(history.all.contains { $0.id == target.id })
    XCTAssertTrue(history.all.contains { $0.id == selected.id })
    XCTAssertEqual(copies, 0)
    XCTAssertTrue(AppState.shared.panelPresented)
  }

  func testEmptyPinStringStaysPinnedAndDedupCopiesIt() {
    let item = historyItem("pin-body")
    item.pin = ""
    item.title = "kept-title"
    let original = history.add(item)
    XCTAssertEqual(original.item.pin, "")
    XCTAssertTrue(original.isPinned, "empty shortcut is still a pin")

    let incoming = historyItem("pin-body")
    incoming.pin = nil
    incoming.title = "incoming"
    let survivor = history.add(incoming)
    XCTAssertEqual(survivor.item.pin, "")
    XCTAssertEqual(survivor.item.title, "kept-title")
    XCTAssertTrue(original.isRemoved)
  }

  func testPinKeepsTheActiveFilter() {
    let alpha = history.add(historyItem("alpha"))
    _ = history.add(historyItem("beta"))
    history.searchQuery = "alpha"
    history.refreshVisibleItems(highlightFirst: false)
    AppState.shared.workspaceSection = .all
    history.togglePin(alpha)
    XCTAssertEqual(history.searchQuery, "alpha")
    XCTAssertEqual(AppState.shared.workspaceSection, .all)
    XCTAssertTrue(alpha.isPinned)
    XCTAssertTrue(history.items.contains { $0.item.title == "alpha" })
    XCTAssertFalse(history.items.contains { $0.item.title == "beta" })
    XCTAssertTrue(history.all.contains { $0.item.title == "beta" })
  }

  func testSectionQueryAndTypeComposeWithoutInventingIgnoredHistory() {
    let text = history.add(historyItem("alpha note"))
    XCTAssertTrue(history.assignTag(text, named: "addr"))
    let pinned = history.add(historyItem("alpha pin"))
    pinned.togglePin()
    _ = history.add(historyItem("beta"))
    _ = history.add(imageItem())

    AppState.shared.workspaceSection = .tags
    history.tagFilter = "addr"
    history.typeFilter = .text
    history.searchQuery = "alpha"
    history.refreshVisibleItems(highlightFirst: false)
    XCTAssertEqual(history.items.map(\.item.title), ["alpha note"])

    AppState.shared.workspaceSection = .pins
    history.tagFilter = nil
    history.typeFilter = nil
    history.searchQuery = "alpha"
    history.refreshVisibleItems(highlightFirst: false)
    XCTAssertEqual(AppState.shared.workspaceSection, .all)
    XCTAssertEqual(Set(history.items.map(\.item.title)), ["alpha note", "alpha pin"])

    let before = history.all.count
    AppState.shared.panelPresented = true
    AppState.shared.preview.state = .open
    AppState.shared.workspaceSection = .ignore
    XCTAssertEqual(AppState.shared.workspaceSection, .all)
    XCTAssertEqual(history.all.count, before)
    XCTAssertTrue(AppState.shared.previewAllowed)
  }

  func testTagRenameMergeAndDeleteKeepItems() {
    let one = history.add(historyItem("keep-body"))
    let two = history.add(historyItem("other-body"))
    XCTAssertTrue(history.assignTag(one, named: "old"))
    XCTAssertTrue(history.assignTag(two, named: "old"))
    XCTAssertTrue(history.assignTag(two, named: "dest"))
    let count = history.all.count

    XCTAssertTrue(history.renameTag(from: "old", to: "fresh"))
    XCTAssertEqual(history.all.count, count)
    XCTAssertEqual(one.item.text, "keep-body")
    XCTAssertEqual(one.item.tags, ["fresh"])
    XCTAssertEqual(two.item.tags, ["fresh", "dest"])

    XCTAssertTrue(history.renameTag(from: "fresh", to: "dest"))
    XCTAssertEqual(history.all.count, count)
    XCTAssertEqual(one.item.tags, ["dest"])
    XCTAssertEqual(two.item.tags, ["dest"])
    XCTAssertEqual(one.item.text, "keep-body")

    XCTAssertTrue(history.deleteTag(named: "dest"))
    XCTAssertEqual(history.all.count, count)
    XCTAssertTrue(one.item.tags.isEmpty)
    XCTAssertEqual(one.item.text, "keep-body")
    XCTAssertEqual(two.item.text, "other-body")
  }

  func testFileRowLabelDoesNotRewriteCopyData() {
    let url = URL(fileURLWithPath: "/tmp/lab/report.pdf")
    let item = history.add(fileItem(url))
    let before = item.item.contents.map(\.value)
    let label = WorkspaceItemLabel.make(
      storedTitle: item.item.title,
      filePaths: item.item.fileURLs.map(\.path)
    )
    XCTAssertEqual(label.rowTitle, "report.pdf")
    XCTAssertEqual(label.tooltip, url.path)
    XCTAssertFalse(label.rowTitle.contains("file://"))
    XCTAssertEqual(item.item.contents.map(\.value), before)

    let fromTitle = WorkspaceItemLabel.make(
      storedTitle: "file:///Users/me/Docs/notes.txt",
      filePaths: []
    )
    XCTAssertEqual(fromTitle.rowTitle, "notes.txt")
    XCTAssertTrue(fromTitle.tooltip?.hasPrefix("file://") == true)
  }

  func testPreviewAllowedIsTheOnlyStructuralGate() throws {
    let app = AppState.shared
    app.panelPresented = true
    app.preview.state = .open
    app.workspaceSection = .all
    XCTAssertTrue(app.previewAllowed)
    app.workspaceSection = .ignore
    XCTAssertEqual(app.workspaceSection, .all)
    XCTAssertTrue(app.previewAllowed)
    app.workspaceSection = .pins
    app.preview.state = .closed
    XCTAssertFalse(app.previewAllowed)
    app.preview.state = .open
    app.panelPresented = false
    XCTAssertFalse(app.previewAllowed)

    let content = try labSource("WitsCopy/Views/ContentView.swift")
    XCTAssertEqual(content.components(separatedBy: "SlideoutContentView()").count - 1, 1)
    XCTAssertTrue(content.contains("if appState.previewAllowed"))
    let header = try labSource("WitsCopy/Views/HeaderView.swift")
    XCTAssertFalse(header.contains("SlideoutContentView"))
    XCTAssertFalse(header.contains("QLPreview"))
    let slideout = try labSource("WitsCopy/Views/SlideoutView.swift")
    XCTAssertTrue(slideout.contains("if controller.state.isOpen"))
    let row = try labSource("WitsCopy/Views/HistoryItemView.swift")
    XCTAssertTrue(row.contains("handleRowClick"))
    XCTAssertFalse(row.contains("history.select"))
    let keys = try labSource("WitsCopy/Views/KeyHandlingView.swift")
    XCTAssertTrue(keys.contains("appState.select(flags:"))
  }

  func testRowEndHasNoEllipsisButtonAndMenuLivesOnRightClick() throws {
    let rowSource = try labSource("WitsCopy/Views/HistoryItemView.swift")
    // ⋯ 按钮撤掉，菜单挂整行右键；删除仍能走右下角预览区。
    XCTAssertFalse(rowSource.contains("ImmediateMenuButton("))
    XCTAssertTrue(rowSource.contains(".contextMenu { rowContextMenu }"))
    XCTAssertTrue(rowSource.contains("lab-row-delete-"))
    // Only the close button is visible, so the band matches the rail width.
    XCTAssertEqual(PanelSplit.trafficLightReserve, PanelSplit.navigationRailWidth)
    let source = try? labSource("WitsCopy/Views/HistoryItemView.swift")
    XCTAssertTrue(source?.contains("drawsSelectionBackground: false") == true)
    XCTAssertFalse(source?.contains("systemName: \"ellipsis\"") == true)
  }

  func testInsertKeepsWorkspaceSectionAndQuery() throws {
    AppState.shared.workspaceSection = .pins
    XCTAssertEqual(AppState.shared.workspaceSection, .all)
    AppState.shared.history.searchQuery = ""
    let pinned = history.add(historyItem("stays pinned"))
    pinned.item.pin = "s"
    let loose = history.add(historyItem("must stay out of pins"))
    XCTAssertNil(loose.item.pin)
    history.refreshVisibleItems()
    XCTAssertTrue(AppState.shared.history.items.contains(pinned))
    XCTAssertTrue(AppState.shared.history.items.contains(loose))
    let snippet = try XCTUnwrap(history.createSnippet(title: "section survives", text: "body"))
    XCTAssertTrue(history.items.contains(snippet))
    XCTAssertTrue(history.items.contains(loose))
    AppState.shared.workspaceSection = .all
  }

  func testQueuedObserversDoNotReadRemovedModels() async throws {
    let item = history.add(historyItem("observer source"))
    item.item.title = "live title"
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(item.title, "live title")
    item.item.pin = "r"
    item.item.title = "queued after removal"
    history.delete(item)
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertTrue(item.isRemoved)
    XCTAssertEqual(item.title, "live title")
  }

  func testRemovedRowsCannotStartCopyOrPreview() async {
    let item = history.add(historyItem("retained transition row"))
    var copies = 0
    Clipboard.shared.copyProbe = { _, _ in copies += 1 }
    history.delete(item)
    XCTAssertTrue(item.isRemoved)
    AppState.shared.handleRowClick(item, clickCount: 2)
    XCTAssertEqual(copies, 0)
    let session = PreviewSession()
    let model = PreviewModel()
    await model.load(item: item, fileIndex: 0, session: session, mode: nil)
    XCTAssertEqual(session.metrics.snapshot().previewStarts, 0)
  }

  func testPrivacyPageCombinesCaptureProtectionAndApplicationRules() throws {
    let settings = try labSource("WitsCopy/Settings/LabSettingsWindow.swift")
    let pages = ["settings-general", "settings-storage", "settings-privacy", "settings-appearance", "settings-advanced"]
    let pageRanges = try pages.map { try XCTUnwrap(settings.range(of: "page(\"\($0)\"")) }
    for index in 1..<pageRanges.count {
      XCTAssertLessThan(pageRanges[index - 1].lowerBound, pageRanges[index].lowerBound)
    }
    XCTAssertTrue(settings.contains("PrivacySettingsPane()"))
    XCTAssertTrue(settings.contains("with: \"settings-pane-\""))
    let privacy = try labSource("WitsCopy/Settings/PrivacySettingsPane.swift")
    for contract in [
      "Defaults.Toggle(key: .protectSensitiveContent)", "Defaults.Toggle(key: .ignoreAllAppsExceptListed)",
      "@Default(.ignoredApps)", "List(selection:", "allowedContentTypes: [.application]",
      "ignoredApps.contains(bundle)", "ignoredApps.removeAll", "applicationName(url:",
      ".accessibilityLabel(Text(\"AddApplication\"", ".accessibilityLabel(Text(\"RemoveApplication\""
    ] {
      XCTAssertTrue(privacy.contains(contract), contract)
    }
    XCTAssertFalse(settings.contains("PinsSettingsPane"))
    XCTAssertTrue(settings.contains("stayAndYieldToSettings"))
    let header = try labSource("WitsCopy/Views/HeaderView.swift")
    let type = try XCTUnwrap(header.range(of: "lab-type-button"))
    let rail = try XCTUnwrap(header.range(of: "lab-rail-button"))
    let preview = try XCTUnwrap(header.range(of: "lab-preview-button"))
    let pin = try XCTUnwrap(header.range(of: "lab-window-pin"))
    XCTAssertLessThan(type.lowerBound, rail.lowerBound)
    XCTAssertLessThan(rail.lowerBound, preview.lowerBound)
    XCTAssertLessThan(preview.lowerBound, pin.lowerBound)
    let railFile = try labSource("WitsCopy/WorkspaceManagementView.swift")
    XCTAssertFalse(railFile.contains("lab-rail-button"))
    XCTAssertTrue(railFile.contains("WorkspaceOptionsButton"))
    XCTAssertFalse(railFile.contains("PrivacySettingsPane"))
    XCTAssertFalse(railFile.contains("pinDroppedItem"))
    XCTAssertEqual(WorkspaceSection.primaryRail.map(\.rawValue), ["all"])
  }

  func testPopupDefaultsAndPointerContracts() throws {
    XCTAssertEqual(PopupPosition.center.rawValue, "center")
    XCTAssertEqual(PanelWindowLevel.popup(pinned: true), .floating)
    XCTAssertEqual(PanelWindowLevel.popup(pinned: false), .popUpMenu)
    let help = Int(CGWindowLevelForKey(.helpWindow))
    XCTAssertLessThan(PanelWindowLevel.popup(pinned: false).rawValue, help)
    XCTAssertLessThan(PanelWindowLevel.popup(pinned: true).rawValue, help)
    XCTAssertNotEqual(PanelWindowLevel.popup(pinned: false), .screenSaver)
    XCTAssertNotEqual(PanelWindowLevel.popup(pinned: true), .screenSaver)

    let symbols = [
      WorkspaceSymbols.windowPin,
      WorkspaceSymbols.itemPin,
      WorkspaceSymbols.pinManagement
    ]
    XCTAssertEqual(Set(symbols).count, 3)
    XCTAssertEqual(WorkspaceSymbols.windowPin, "macwindow")
    XCTAssertEqual(WorkspaceSymbols.itemPinFilled, "pin.fill")
    XCTAssertEqual(WorkspaceSymbols.pinManagement, "bookmark.square")
    XCTAssertNotEqual(WorkspaceHelp.windowPin(on: true), WorkspaceHelp.windowPin(on: false))

    let keys = try labSource("WitsCopy/Extensions/Defaults.Keys+Names.swift")
    XCTAssertTrue(keys.contains("\"popupPosition\", default: .center"))
    let row = try labSource("WitsCopy/Views/HistoryItemView.swift")
    XCTAssertTrue(row.contains("handleRowClick"))
    XCTAssertTrue(row.contains("currentEvent?.clickCount"))
    let panel = try labSource("WitsCopy/FloatingPanel.swift")
    XCTAssertTrue(panel.contains("PanelWindowLevel.popup"))
  }

  func testUnpinRestoresPositionAndNumericShortcut() async {
    Defaults[.sortBy] = .lastCopiedAt
    Defaults[.pinTo] = .top
    let older = history.add(historyItem("C"))
    older.item.lastCopiedAt = Date(timeIntervalSince1970: 10)
    let middle = history.add(historyItem("B"))
    middle.item.lastCopiedAt = Date(timeIntervalSince1970: 20)
    let newest = history.add(historyItem("A"))
    newest.item.lastCopiedAt = Date(timeIntervalSince1970: 30)
    history.refreshVisibleItems()

    history.togglePin(newest)
    XCTAssertNotNil(newest.item.pin)
    history.togglePin(newest)

    XCTAssertNil(newest.item.pin)
    XCTAssertEqual(history.items.filter(\.isUnpinned).map(\.item.title), ["A", "B", "C"])
    XCTAssertEqual(newest.shortcuts.first?.key, Key(character: "1", virtualKeyCode: nil))
    XCTAssertEqual(middle.shortcuts.first?.key, Key(character: "2", virtualKeyCode: nil))

    let drained = expectation(description: "pin observer")
    DispatchQueue.main.async { drained.fulfill() }
    await fulfillment(of: [drained], timeout: 1)
    XCTAssertEqual(newest.shortcuts.first?.key, Key(character: "1", virtualKeyCode: nil))
    XCTAssertFalse(newest.shortcuts.isEmpty)
  }

  func testPinsAreNotAPrimaryRailEntry() throws {
    XCTAssertEqual(WorkspaceSection.primaryRail.map(\.rawValue), ["all"])
    XCTAssertFalse(WorkspaceSection.primaryRail.contains(.tags))
    XCTAssertFalse(WorkspaceSection.primaryRail.contains(.pins))
    XCTAssertFalse(WorkspaceSection.primaryRail.contains(.ignore))
    XCTAssertEqual(WorkspaceSection.resolvedForOpen(.all), .all)
    XCTAssertEqual(WorkspaceSection.resolvedForOpen(.tags), .all)
    XCTAssertEqual(WorkspaceSection.resolvedForOpen(.pins), .all)
    XCTAssertEqual(WorkspaceSection.resolvedForOpen(.ignore), .all)
    AppState.shared.workspaceSection = .pins
    XCTAssertEqual(AppState.shared.workspaceSection, .all)
    let rail = try labSource("WitsCopy/WorkspaceManagementView.swift")
    XCTAssertTrue(rail.contains("lab-options-button"))
    XCTAssertTrue(rail.contains("accessibilityIdentifier(for:"))
    let policy = try labSource("WitsCopy/WorkspaceModel.swift")
    XCTAssertTrue(policy.contains("lab-rail-tag-"))
  }

  func testQuitConfirmationDoesNotShareClearSuppression() throws {
    let savedClear = Defaults[.suppressClearAlert]
    let savedQuit = Defaults[.suppressQuitAlert]
    defer {
      Defaults[.suppressClearAlert] = savedClear
      Defaults[.suppressQuitAlert] = savedQuit
    }
    Defaults[.suppressClearAlert] = true
    Defaults[.suppressQuitAlert] = false
    XCTAssertTrue(Defaults[.suppressClearAlert])
    XCTAssertFalse(Defaults[.suppressQuitAlert])

    let footer = try labSource("WitsCopy/Observables/Footer.swift")
    XCTAssertFalse(footer.contains("title: \"clear\""))
    XCTAssertTrue(footer.contains("suppressQuitAlert"))
    XCTAssertTrue(footer.contains("clear_all_alert_comment"))
    XCTAssertTrue(footer.contains("commitQuit"))
    let app = try labSource("WitsCopy/Observables/AppState.swift")
    XCTAssertFalse(app.contains("Defaults[.suppressClearAlert]"))
    XCTAssertTrue(app.contains("item.suppressConfirmation"))
    let about = try labSource("WitsCopy/About.swift")
    XCTAssertTrue(about.contains("about_summary"))
    XCTAssertTrue(about.contains("CFBundleShortVersionString"))
  }

  func testTagEditorAnchorIsExclusiveAndPreviewCloseKeepsTheRow() {
    let row = history.add(historyItem("row-host"))
    let other = history.add(historyItem("other-host"))
    var copies = 0
    Clipboard.shared.copyProbe = { _, _ in copies += 1 }
    AppState.shared.panelPresented = true
    AppState.shared.preview.state = .open

    AppState.shared.performRowAction(.tag, on: row, anchor: .preview)
    XCTAssertTrue(AppState.shared.presentsTagEditor(row, at: .preview))
    XCTAssertFalse(AppState.shared.presentsTagEditor(row, at: .row))
    XCTAssertEqual(copies, 0)
    XCTAssertTrue(AppState.shared.panelPresented)

    AppState.shared.dismissTagEditor(itemID: row.id, anchor: .row)
    XCTAssertTrue(AppState.shared.presentsTagEditor(row, at: .preview))

    AppState.shared.performRowAction(.tag, on: row, anchor: .row)
    XCTAssertTrue(AppState.shared.presentsTagEditor(row, at: .row))
    XCTAssertFalse(AppState.shared.presentsTagEditor(row, at: .preview))

    AppState.shared.preview.state = .closed
    XCTAssertTrue(AppState.shared.presentsTagEditor(row, at: .row))

    AppState.shared.preview.state = .open
    AppState.shared.performRowAction(.tag, on: row, anchor: .preview)
    AppState.shared.navigator.select(item: other)
    XCTAssertNil(AppState.shared.tagEditorItem)
    XCTAssertTrue(AppState.shared.presentsTagEditor(other, at: .row) == false)

    AppState.shared.performRowAction(.tag, on: other, anchor: .row)
    AppState.shared.navigator.select(item: row)
    XCTAssertTrue(AppState.shared.presentsTagEditor(other, at: .row))

    AppState.shared.panelPresented = false
    XCTAssertNil(AppState.shared.tagEditorItem)
    XCTAssertNil(AppState.shared.tagEditorAnchor)
    XCTAssertEqual(copies, 0)
  }

  func testListToolbarStaysInsideTheListColumn() {
    XCTAssertEqual(
      ListToolbarLayout.constrainedWidth(listWidth: 400, previewColumnVisible: true),
      400
    )
    XCTAssertNotEqual(
      ListToolbarLayout.constrainedWidth(listWidth: 400, previewColumnVisible: true),
      400 + 620
    )
    XCTAssertNil(ListToolbarLayout.constrainedWidth(listWidth: 400, previewColumnVisible: false))
    XCTAssertEqual(PanelSplit.navigationRailWidth, 36)
    XCTAssertTrue((24...28).contains(PanelSplit.railHitSize))
  }

  func testReloadKeepsDecoratorIdentity() async throws {
    let item = history.add(historyItem("stable-row"))
    let before = item.id
    try await history.load()
    XCTAssertEqual(history.items.first { $0.item.title == "stable-row" }?.id, before)
    XCTAssertTrue(history.items.contains { $0 === item })
  }

  func testOCRReadingOrderKeepsColumnsAndParagraphs() {
    let boxes = [
      OCRObservationBox(text: "left-a", minX: 0.05, minY: 0.70, maxX: 0.30, maxY: 0.80),
      OCRObservationBox(text: "left-b", minX: 0.05, minY: 0.20, maxX: 0.30, maxY: 0.30),
      OCRObservationBox(text: "right-a", minX: 0.60, minY: 0.70, maxX: 0.90, maxY: 0.80)
    ]
    let blocks = OCRReadingOrder.blocks(from: boxes)
    XCTAssertEqual(blocks.count, 3)
    XCTAssertEqual(blocks.map(\.lines), [["left-a"], ["left-b"], ["right-a"]])
    AppState.shared.panelPresented = true
    let item = history.add(historyItem("ocr-host"))
    AppState.shared.beginOCR(for: item)
    let generation = AppState.shared.ocrGeneration
    AppState.shared.commitOCR(blocks, generation: generation, itemID: item.id)
    var copied: [String] = []
    AppState.shared.ocrCopyHook = { copied.append($0) }
    AppState.shared.copyOCRText()
    XCTAssertEqual(copied.count, 1)
    XCTAssertTrue(copied[0].contains("left-a"))
    XCTAssertTrue(copied[0].contains("\n\n"))
    AppState.shared.closeOCR()
    XCTAssertNil(AppState.shared.ocrItemID)
    AppState.shared.commitOCR(blocks, generation: generation, itemID: item.id)
    XCTAssertNotEqual(AppState.shared.ocrPhase, .ready)
  }

  func testOCRReadingOrderIsIndependentOfObservationInputOrder() {
    let a = OCRObservationBox(text: "A", minX: 0, minY: 0.1, maxX: 0.08, maxY: 0.2)
    let b = OCRObservationBox(text: "B", minX: 0.1, minY: 0.5, maxX: 0.18, maxY: 0.6)
    let c = OCRObservationBox(text: "C", minX: 0.2, minY: 0.8, maxX: 0.28, maxY: 0.9)
    let variants = [[a, b, c], [a, c, b], [b, a, c], [b, c, a], [c, a, b], [c, b, a]]
    let expected = OCRReadingOrder.blocks(from: variants[0])
    for input in variants {
      XCTAssertEqual(OCRReadingOrder.blocks(from: input), expected)
    }
  }

  func testIconPressFiresOncePerPathAndRoleIsButton() {
    let button = ImmediateActionButton()
    let target = IconPressProbe()
    button.setAccessibilityElement(true)
    button.setAccessibilityRole(.button)
    button.target = target
    button.action = #selector(IconPressProbe.fire(_:))
    button.onMouseDown = { [weak target] in
      target?.fire(nil)
    }
    XCTAssertEqual(button.accessibilityRole(), .button)
    let event = NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: .zero,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      eventNumber: 1,
      clickCount: 1,
      pressure: 1
    )
    if let event {
      button.mouseDown(with: event)
    } else {
      button.onMouseDown?()
    }
    XCTAssertEqual(target.fires, 1)
    XCTAssertTrue(button.accessibilityPerformPress())
    XCTAssertEqual(target.fires, 2)
    button.menuProvider = { (NSMenu(), []) }
    button.setAccessibilityRole(.popUpButton)
    XCTAssertEqual(button.accessibilityRole(), .popUpButton)
  }

  func testCloseDuringLiveResizeStillHidesThePanelAndClearsPresentation() {
    let panel = LiveResizeClosePanel(
      contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 300),
      onClose: {},
      view: { EmptyView() }
    )
    panel.orderFront(nil)
    panel.isPresented = true
    AppState.shared.panelPresented = true
    defer {
      panel.orderOut(nil)
      panel.isPresented = false
      AppState.shared.panelPresented = false
    }

    XCTAssertTrue(panel.inLiveResize)
    XCTAssertTrue(panel.isVisible)
    panel.close()

    XCTAssertFalse(panel.isVisible, "deferred close left an empty glass frame on screen")
    XCTAssertFalse(panel.isPresented)
    XCTAssertFalse(AppState.shared.panelPresented)
  }

  func testActionButtonHitPrefersTheButtonOverAScroller() {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
    let button = ImmediateActionButton(frame: NSRect(x: 40, y: 20, width: 26, height: 24))
    button.isEnabled = true
    let scroller = NSScroller(frame: NSRect(x: 58, y: 0, width: 8, height: 80))
    root.addSubview(button)
    root.addSubview(scroller)
    let panel = NSPanel(
      contentRect: NSRect(x: -20000, y: -20000, width: 200, height: 80),
      styleMask: [.borderless],
      backing: .buffered,
      defer: true
    )
    panel.contentView = root
    let overlap = NSPoint(x: 60, y: 30)
    let center = NSPoint(x: 50, y: 32)
    XCTAssertTrue(button.frame.contains(overlap))
    XCTAssertTrue(scroller.frame.contains(overlap))
    XCTAssertEqual(FloatingPanel<ContentView>.actionButton(in: root, at: overlap), button)
    XCTAssertEqual(FloatingPanel<ContentView>.actionButton(in: root, at: center), button)
    let outside = NSPoint(x: 10, y: 10)
    XCTAssertNil(FloatingPanel<ContentView>.actionButton(in: root, at: outside))
  }

  func testOCRFitStaysInsideTheScreenAndCloseRestoresTheBase() {
    let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let rightEdge = CGRect(x: 700, y: 254, width: 1020, height: 640)
    let shifted = OCRFramePlanner.fit(
      window: rightEdge,
      screen: screen,
      listWidth: 400,
      previewWidth: 620,
      previewOpen: true
    )
    XCTAssertLessThanOrEqual(shifted.frame.maxX, screen.maxX)
    XCTAssertGreaterThanOrEqual(shifted.frame.minX, screen.minX)
    XCTAssertLessThan(shifted.frame.minX, rightEdge.minX)
    XCTAssertEqual(shifted.listWidth, 400)
    XCTAssertEqual(shifted.previewWidth, 620)
    XCTAssertGreaterThan(shifted.ocrWidth, 0)
    XCTAssertLessThanOrEqual(shifted.ocrWidth, OCRColumnLayout.width)
    XCTAssertEqual(OCRFramePlanner.restored(base: rightEdge, screen: screen), rightEdge)

    let wide = CGRect(x: 0, y: 254, width: 1728, height: 640)
    let squeezed = OCRFramePlanner.fit(
      window: wide,
      screen: screen,
      listWidth: 400,
      previewWidth: 1328,
      previewOpen: true
    )
    XCTAssertLessThanOrEqual(squeezed.frame.maxX, screen.maxX)
    XCTAssertGreaterThanOrEqual(squeezed.frame.minX, screen.minX)
    XCTAssertLessThanOrEqual(squeezed.frame.width, screen.width)
    XCTAssertEqual(squeezed.listWidth, 400)
    XCTAssertLessThan(squeezed.previewWidth, 1328)
    XCTAssertGreaterThanOrEqual(
      squeezed.previewWidth,
      PanelSplit.previewFloor(availableWidth: screen.width, listWidth: 400)
    )
    XCTAssertGreaterThan(squeezed.ocrWidth, 0)
    XCTAssertEqual(OCRColumnLayout.widthThatFits(availableWidth: 1000, occupiedWidth: 1000), 0)
    XCTAssertLessThan(OCRColumnLayout.widthThatFits(availableWidth: 100, occupiedWidth: 0), OCRColumnLayout.minimumWidth)

    let savedPreview = Defaults[.previewColumnWidth]
    let savedList = Defaults[.listColumnWidth]
    defer {
      Defaults[.previewColumnWidth] = savedPreview
      Defaults[.listColumnWidth] = savedList
    }
    Defaults[.previewColumnWidth] = 620
    Defaults[.listColumnWidth] = 400
    let controller = SlideoutController()
    controller.layoutListWidth = 400
    controller.layoutPreviewWidth = 620
    controller.temporaryOCRWidth = shifted.ocrWidth
    controller.ocrBaseFrame = rightEdge
    XCTAssertEqual(controller.persistedFrame(fallback: shifted.frame), rightEdge)
    controller.absorbWidth(rightEdge.width + shifted.ocrWidth)
    XCTAssertEqual(controller.layoutPreviewWidth, 620)
    XCTAssertEqual(controller.layoutListWidth, 400)
    controller.applyDividerDrag(
      translation: -24,
      windowWidth: shifted.frame.width,
      visualSlideoutWidth: 620 + shifted.ocrWidth
    )
    XCTAssertEqual(controller.layoutPreviewWidth, 596)
    XCTAssertNotEqual(controller.layoutPreviewWidth, 620 + shifted.ocrWidth)
    controller.commitWidths()
    XCTAssertEqual(Defaults[.previewColumnWidth], 596)
    XCTAssertNotEqual(Defaults[.previewColumnWidth], 620 + shifted.ocrWidth)

    controller.layoutListWidth = 400
    controller.layoutPreviewWidth = 1328
    controller.temporaryOCRWidth = squeezed.ocrWidth
    controller.temporaryPreviewBorrow = 1328 - squeezed.previewWidth
    controller.absorbWidth(wide.width)
    XCTAssertEqual(controller.layoutPreviewWidth, 1328)
    XCTAssertEqual(controller.layoutListWidth, 400)
  }

  /// 左栏展开的那几十点也是窗口宽度的一部分。漏掉它，窗口会比内容窄一截：
  /// 右栏被裁，整窗还会被推到屏幕边上。
  func testOCRFitCountsTheExpandedRailWidth() {
    let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let base = CGRect(x: 0, y: 254, width: 400 + 72 + 620, height: 640)
    let withRail = OCRFramePlanner.fit(
      window: base,
      screen: screen,
      listWidth: 400,
      railWidth: 72,
      previewWidth: 620,
      previewOpen: true
    )
    XCTAssertGreaterThan(withRail.ocrWidth, 0)
    XCTAssertEqual(withRail.frame.width, 400 + 72 + 620 + withRail.ocrWidth, accuracy: 0.5)
    XCTAssertLessThanOrEqual(withRail.frame.maxX, screen.maxX)

    let withoutRail = OCRFramePlanner.fit(
      window: base,
      screen: screen,
      listWidth: 400,
      railWidth: 0,
      previewWidth: 620,
      previewOpen: true
    )
    XCTAssertEqual(
      withRail.frame.width - withoutRail.frame.width,
      72,
      accuracy: 0.5,
      "展开的左栏没有计入窗口宽度"
    )
  }

  func testCloseOCRCancelsRecognitionWithoutStoppingPreview() {
    let item = history.add(historyItem("ocr-cancel"))
    let session = PreviewSession()
    let token = session.begin(allowed: true, identity: item.id.uuidString)!
    var mediaStops = 0
    session.mediaStop = { mediaStops += 1 }
    var commits = 0
    session.startRecognition(data: Data([0x89, 0x50, 0x4E, 0x47]), token: token) { _ in
      commits += 1
    }
    let before = session.recognitionCancelCount
    session.startRecognition(data: Data([0x89, 0x50, 0x4E, 0x47]), token: token) { _ in
      commits += 1
    }
    XCTAssertGreaterThan(session.recognitionCancelCount, before)
    XCTAssertEqual(mediaStops, 0)
    XCTAssertTrue(session.isCurrent(token))

    AppState.shared.beginOCR(for: item)
    let generation = AppState.shared.ocrGeneration
    AppState.shared.cancelPreviewRecognition = { session.cancelRecognition() }
    let running = session.recognitionCancelCount
    AppState.shared.closeOCR()
    XCTAssertGreaterThan(session.recognitionCancelCount, running)
    XCTAssertNil(AppState.shared.ocrItemID)
    XCTAssertEqual(AppState.shared.ocrPhase, .idle)
    XCTAssertEqual(mediaStops, 0)
    XCTAssertTrue(session.isCurrent(token))
    AppState.shared.commitOCR(
      [OCRBlock(id: 0, lines: ["late"])],
      generation: generation,
      itemID: item.id
    )
    XCTAssertNotEqual(AppState.shared.ocrPhase, .ready)
    XCTAssertEqual(commits, 0)
  }

  func testSwitchingPreviewFileClearsOCRThroughLoad() async {
    let item = history.add(multiFileItem())
    AppState.shared.beginOCR(for: item)
    AppState.shared.ocrBlocks = [OCRBlock(id: 0, lines: ["stale file"])]
    AppState.shared.ocrPhase = .ready
    let session = PreviewSession()
    let token = session.begin(allowed: true, identity: item.id.uuidString)!
    session.startRecognition(data: Data([0x89, 0x50, 0x4E, 0x47]), token: token) { _ in }
    AppState.shared.cancelPreviewRecognition = { session.cancelRecognition() }
    let generation = AppState.shared.ocrGeneration
    let before = session.recognitionCancelCount
    let model = PreviewModel()
    await model.load(item: item, fileIndex: 1, session: session, mode: nil)
    XCTAssertNil(AppState.shared.ocrItemID)
    XCTAssertTrue(AppState.shared.ocrBlocks.isEmpty)
    XCTAssertEqual(AppState.shared.ocrPhase, .idle)
    XCTAssertGreaterThan(session.recognitionCancelCount, before)
    AppState.shared.commitOCR(
      [OCRBlock(id: 1, lines: ["late file"])],
      generation: generation,
      itemID: item.id
    )
    XCTAssertNotEqual(AppState.shared.ocrPhase, .ready)

    await model.load(item: item, fileIndex: 0, session: session, mode: nil)
    XCTAssertNil(AppState.shared.ocrItemID)
    XCTAssertEqual(AppState.shared.ocrPhase, .idle)
  }

  func testDeletingOpenOCRItemCancelsBeforeUnload() {
    let item = history.add(historyItem("ocr-delete"))
    AppState.shared.beginOCR(for: item)
    let session = PreviewSession()
    let token = session.begin(allowed: true, identity: item.id.uuidString)!
    var mediaStops = 0
    session.mediaStop = { mediaStops += 1 }
    session.startRecognition(data: Data([0x89, 0x50, 0x4E, 0x47]), token: token) { _ in }
    AppState.shared.cancelPreviewRecognition = { session.cancelRecognition() }
    let generation = AppState.shared.ocrGeneration
    let before = session.recognitionCancelCount
    history.delete(item)
    XCTAssertTrue(item.isRemoved)
    XCTAssertNil(AppState.shared.ocrItemID)
    XCTAssertEqual(AppState.shared.ocrPhase, .idle)
    XCTAssertGreaterThan(session.recognitionCancelCount, before)
    XCTAssertEqual(mediaStops, 0)
    XCTAssertTrue(session.isCurrent(token))
    AppState.shared.commitOCR(
      [OCRBlock(id: 0, lines: ["deleted late"])],
      generation: generation,
      itemID: item.id
    )
    XCTAssertNotEqual(AppState.shared.ocrPhase, .ready)
  }

  func testRowMenuHitGridFiresOnceWithoutBubbling() {
    let counters = RowHitCounters()
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 120))
    let hosting = NSHostingView(rootView: RowMenuHitProbe(onRow: { counters.row += 1 })
      .environment(AppState.shared))
    hosting.frame = NSRect(x: 0, y: 40, width: 280, height: 36)
    hosting.sizingOptions = []
    root.addSubview(hosting)
    let panel = HitProbePanel(
      contentRect: NSRect(x: -20000, y: -20000, width: 280, height: 120),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isReleasedWhenClosed = false
    panel.contentView = root
    hosting.layoutSubtreeIfNeeded()
    root.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    hosting.layoutSubtreeIfNeeded()
    let button = immediateButtons(in: hosting).first { $0.accessibilityIdentifier() == "lab-row-menu-probe" }
      ?? immediateButtons(in: hosting).first
    let menuButton = try? XCTUnwrap(button)
    guard let menuButton else {
      XCTFail("row menu button was not installed")
      return
    }
    XCTAssertGreaterThanOrEqual(menuButton.bounds.width, 20)
    XCTAssertGreaterThanOrEqual(menuButton.bounds.height, 20)
    menuButton.menuProvider = nil
    menuButton.onMouseDown = { counters.button += 1 }
    let windowBounds = menuButton.convert(menuButton.bounds, to: nil)
    let inset: CGFloat = 1
    let xs = [windowBounds.minX + inset, windowBounds.midX, windowBounds.maxX - inset]
    let ys = [windowBounds.minY + inset, windowBounds.midY, windowBounds.maxY - inset]
    var eventNumber = 1
    for x in xs {
      for y in ys {
        let before = counters.button
        sendMouseDown(panel, at: NSPoint(x: x, y: y), eventNumber: eventNumber)
        eventNumber += 1
        XCTAssertEqual(counters.button, before + 1, "missed \(x),\(y) in \(windowBounds)")
        XCTAssertEqual(counters.row, 0)
      }
    }

    let hidden = ImmediateActionButton(frame: NSRect(x: 8, y: 8, width: 24, height: 24))
    hidden.isHidden = true
    hidden.onMouseDown = { counters.button += 1 }
    root.addSubview(hidden)
    sendMouseDown(panel, at: NSPoint(x: 16, y: 16), eventNumber: eventNumber)
    eventNumber += 1
    XCTAssertEqual(counters.button, 9)

    let clip = NSView(frame: NSRect(x: 40, y: 4, width: 16, height: 16))
    clip.clipsToBounds = true
    let clipped = ImmediateActionButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
    clipped.onMouseDown = { counters.button += 1 }
    clip.addSubview(clipped)
    root.addSubview(clip)
    sendMouseDown(panel, at: NSPoint(x: 60, y: 12), eventNumber: eventNumber)
    eventNumber += 1
    XCTAssertEqual(counters.button, 9)
    XCTAssertNil(FloatingPanel<ContentView>.actionButton(in: root, at: NSPoint(x: 60, y: 12)))

    let scroller = NSScroller(frame: NSRect(x: windowBounds.maxX - 6, y: windowBounds.minY, width: 10, height: windowBounds.height))
    root.addSubview(scroller)
    let overlap = NSPoint(x: windowBounds.maxX - 2, y: windowBounds.midY)
    XCTAssertTrue(scroller.frame.contains(overlap))
    sendMouseDown(panel, at: overlap, eventNumber: eventNumber)
    XCTAssertEqual(counters.button, 10)
    XCTAssertEqual(counters.row, 0)
  }

  private func sendMouseDown(_ panel: NSPanel, at point: NSPoint, eventNumber: Int) {
    guard let event = NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: point,
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: panel.windowNumber,
      context: nil,
      eventNumber: eventNumber,
      clickCount: 1,
      pressure: 1
    ) else {
      XCTFail("could not build mouse event")
      return
    }
    panel.sendEvent(event)
  }

  private func immediateButtons(in root: NSView) -> [ImmediateActionButton] {
    var found: [ImmediateActionButton] = []
    func walk(_ view: NSView) {
      if let button = view as? ImmediateActionButton {
        found.append(button)
      }
      view.subviews.forEach(walk)
    }
    walk(root)
    return found
  }

  private func labSource(_ relative: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(contentsOf: root.appending(path: relative), encoding: .utf8)
  }

  private func multiFileItem() -> HistoryItem {
    let first = URL(fileURLWithPath: "/tmp/maccy-v033-a.txt")
    let second = URL(fileURLWithPath: "/tmp/maccy-v033-b.txt")
    let item = HistoryItem(contents: [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.fileURL.rawValue,
        value: first.dataRepresentation
      ),
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.fileURL.rawValue,
        value: second.dataRepresentation
      )
    ])
    item.title = "two-files"
    Storage.shared.context.insert(item)
    return item
  }

  private func historyItem(_ value: String) -> HistoryItem {
    let contents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: value.data(using: .utf8)
      )
    ]
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = contents
    item.numberOfCopies = 1
    item.title = item.generateTitle()
    return item
  }

  private func imageItem() -> HistoryItem {
    let item = HistoryItem(contents: [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.png.rawValue,
        value: Data([0x89, 0x50, 0x4e, 0x47])
      )
    ])
    item.title = "pixel"
    Storage.shared.context.insert(item)
    return item
  }

  private func fileItem(_ url: URL) -> HistoryItem {
    let item = HistoryItem(contents: [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.fileURL.rawValue,
        value: url.dataRepresentation
      )
    ])
    item.title = url.absoluteString
    Storage.shared.context.insert(item)
    return item
  }
}

private final class RowHitCounters {
  var button = 0
  var row = 0
}

private struct RowMenuHitProbe: View {
  var onRow: () -> Void

  var body: some View {
    HStack(spacing: 0) {
      Text("row")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(count: 1) { onRow() }
        .simultaneousGesture(TapGesture(count: 2).onEnded { onRow() })
      ImmediateMenuButton(
        systemName: "ellipsis",
        help: "more",
        identifier: "lab-row-menu-probe",
        label: "more",
        entries: [
          ImmediateMenuEntry(title: "tag", identifier: "lab-row-tag-probe", action: {})
        ]
      )
      .frame(width: 24, height: 24)
      .modifier(LabToolbarChrome(compact: true))
      .padding(.trailing, 2)
      .frame(width: 28)
    }
    .frame(width: 280, height: 36)
  }
}

private final class HitProbePanel: NSPanel {
  override func sendEvent(_ event: NSEvent) {
    if event.type == .leftMouseDown,
       let content = contentView,
       let button = FloatingPanel<ContentView>.actionButton(in: content, at: event.locationInWindow) {
      button.mouseDown(with: event)
      return
    }
    super.sendEvent(event)
  }
}

/// Independent pixel-axis reference. Do not infer bitmap orientation from the
/// image being tested: an upside-down image would otherwise pass by construction.
private final class PixelAxisReferenceView: NSView {
  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.red.setFill()
    NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height / 3).fill()
    NSColor.blue.setFill()
    NSRect(x: bounds.minX, y: bounds.maxY - bounds.height / 3,
           width: bounds.width, height: bounds.height / 3).fill()
  }
}

/// Offscreen host. Refuses key, activation, and ordering so a SwiftUI focus
/// request cannot surface the probe or the user's windows.
private final class OffscreenLayoutPanel: NSPanel {
  var allowsLocalKey = false
  override var canBecomeKey: Bool { allowsLocalKey }
  override var canBecomeMain: Bool { false }
  override func makeKey() { if allowsLocalKey { super.makeKey() } }
  override func becomeKey() { if allowsLocalKey { super.becomeKey() } }
  override func makeMain() {}
  override func makeKeyAndOrderFront(_ sender: Any?) {}
  override func orderFront(_ sender: Any?) {}
  override func orderFrontRegardless() {}
  override func orderBack(_ sender: Any?) {}
  override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {}
}

private struct RowPitchHost: View {
  @State private var query = ""
  @FocusState private var focused: Bool

  var body: some View {
    HistoryListView(searchQuery: $query, searchFocused: $focused)
      .frame(width: 380)
      .environment(AppState.shared)
      .environment(ModifierFlags())
  }
}

@MainActor
final class PreviewViewportLayoutTests: XCTestCase {
  private let history = History.shared
  private var savedSize = 0
  private let savedSortBy = Defaults[.sortBy]
  private let savedWindowPinned = AppState.shared.windowPinned
  private let savedRailVisible = AppState.shared.managementRailVisible
  private let savedWorkspaceSection = AppState.shared.workspaceSection
  private var savedSplit = standardPanelSplit
  private var probe: OffscreenLayoutPanel?
  private var detachedContent: NSView?
  private var appPanel: NSWindow?

  override func setUp() {
    super.setUp()
    savedSize = Defaults[.size]
    savedSplit = AppState.shared.preview.currentSplit
    history.clearAll()
    Defaults[.size] = 20
    Defaults[.sortBy] = .firstCopiedAt
    AppState.shared.windowPinned = false
    AppState.shared.workspaceSection = .all
    AppState.shared.panelPresented = false
    AppState.shared.managementRailVisible = true
    AppState.shared.closeOCR()
    AppState.shared.navigator.select(item: nil)
    Clipboard.shared.copyProbe = nil
  }

  override func tearDown() {
    AppState.shared.panelPresented = false
    AppState.shared.navigator.select(item: nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    if let appPanel {
      appPanel.contentView = detachedContent
    }
    detachedContent = nil
    appPanel = nil
    probe?.close()
    probe = nil
    history.clearAll()
    AppState.shared.preview.applyLayout(split: savedSplit)
    AppState.shared.closeOCR()
    Defaults[.size] = savedSize
    Defaults[.sortBy] = savedSortBy
    AppState.shared.windowPinned = savedWindowPinned
    AppState.shared.managementRailVisible = savedRailVisible
    AppState.shared.workspaceSection = savedWorkspaceSection
    Clipboard.shared.copyProbe = nil
    super.tearDown()
  }

  func testLandscapeAndPortraitStayInsideTheProductPreview() async {
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let appWindow = AppState.shared.appDelegate?.panel
    let appWasVisible = appWindow?.isVisible ?? false
    let appWasKey = appWindow?.isKeyWindow ?? false
    detachAppPanel()
    // SwiftUI does not publish preview AX identifiers until this process has
    // touched the accessibility server. This does not order or activate a window.
    let axApp = AXUIElementCreateApplication(getpid())
    var axWindows: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &axWindows)

    let landscapePixels = NSSize(width: 240, height: 150)
    let portraitPixels = NSSize(width: 90, height: 240)
    XCTAssertEqual(landscapePixels.height / landscapePixels.width, 1500.0 / 2400.0, accuracy: 0.0001)
    XCTAssertEqual(portraitPixels.height / portraitPixels.width, 2400.0 / 900.0, accuracy: 0.0001)
    let landscape = history.add(imageItem(pixels: landscapePixels, title: "layout-landscape"))
    let portrait = history.add(imageItem(pixels: portraitPixels, title: "layout-portrait"))
    let split = PanelSplit(listWidth: PanelSplit.minimumList, previewWidth: 480, previewOpen: true, height: 360)
    XCTAssertGreaterThanOrEqual(split.height, PanelSplit.minimumHeight)
    XCTAssertGreaterThanOrEqual(split.listWidth, PanelSplit.minimumList)
    XCTAssertGreaterThan(split.previewWidth, 0)
    AppState.shared.preview.applyLayout(split: split)
    AppState.shared.workspaceSection = .all
    AppState.shared.navigator.select(item: landscape)

    let probe = makeProbe(size: NSSize(width: split.totalWidth, height: split.height))
    guard probe.frame.maxX < 0, probe.frame.maxY < 0, !probe.isVisible, !probe.isKeyWindow else {
      XCTFail("refusing visible probe \(probe.frame) visible=\(probe.isVisible) key=\(probe.isKeyWindow)")
      return
    }
    let hosting = NSHostingView(rootView: ContentView())
    hosting.sizingOptions = []
    probe.contentView = hosting
    AppState.shared.panelPresented = true

    let landscapeFrames = await waitForPreview(in: hosting, dimension: "240×150", previous: nil)
    assertContained(landscapeFrames, aspect: landscapePixels.height / landscapePixels.width, label: "landscape")
    let windowSize = probe.frame.size

    XCTAssertNotNil(landscapeFrames?.list, "list frame must be present")
    AppState.shared.navigator.select(item: portrait)
    let portraitFrames = await waitForPreview(in: hosting, dimension: "90×240", previous: landscapeFrames?.image)
    assertContained(portraitFrames, aspect: portraitPixels.height / portraitPixels.width, label: "portrait")

    if let landscapeFrames, let portraitFrames,
       let left = landscapeFrames.preview, let right = portraitFrames.preview {
      XCTAssertEqual(left.minX, right.minX, accuracy: 1, "preview column moved")
      XCTAssertEqual(left.width, right.width, accuracy: 1, "preview column resized")
      XCTAssertEqual(left.height, right.height, accuracy: 1, "preview column resized")
      if let a = landscapeFrames.divider, let b = portraitFrames.divider {
        XCTAssertEqual(a.minX, b.minX, accuracy: 1, "divider moved")
      }
      if let a = landscapeFrames.list, let b = portraitFrames.list {
        XCTAssertEqual(a.minX, b.minX, accuracy: 1, "list column moved")
        XCTAssertEqual(a.width, b.width, accuracy: 1, "list column resized")
      }
    }
    XCTAssertNotNil(portraitFrames?.list, "list frame must be present")
    XCTAssertEqual(probe.frame.size, windowSize)
    XCTAssertEqual(AppState.shared.preview.layoutListWidth, split.listWidth, accuracy: 0.5)
    XCTAssertEqual(AppState.shared.preview.layoutPreviewWidth, split.previewWidth, accuracy: 0.5)
    XCTAssertFalse(probe.isVisible)
    XCTAssertFalse(probe.isKeyWindow)
    XCTAssertEqual(appWindow?.isVisible ?? false, appWasVisible)
    XCTAssertEqual(appWindow?.isKeyWindow ?? false, appWasKey)
    XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, front)
    XCTAssertLessThan(probe.frame.maxX, 0)
  }

  func testPlayingGIFStaysInsideTheProductPreview() async throws {
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    detachAppPanel()
    let axApp = AXUIElementCreateApplication(getpid())
    var axWindows: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &axWindows)
    let gif = try XCTUnwrap(LabSmokeCanvas.gif(pixels: NSSize(width: 240, height: 720), frames: 3))
    let url = try XCTUnwrap(LabSmokeCanvas.write(gif, name: "viewport.gif"))
    defer { LabSmokeCanvas.cleanup() }
    let item = HistoryItem(contents: [
      HistoryItemContent(type: NSPasteboard.PasteboardType.fileURL.rawValue, value: url.dataRepresentation),
      HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data("viewport.gif".utf8))
    ])
    item.title = "layout-gif"
    Storage.shared.context.insert(item)
    let decorator = history.add(item)
    let split = PanelSplit(listWidth: PanelSplit.minimumList, previewWidth: 480, previewOpen: true, height: 360)
    AppState.shared.preview.applyLayout(split: split)
    AppState.shared.navigator.select(item: decorator)
    let panel = makeProbe(size: NSSize(width: split.totalWidth, height: split.height))
    let hosting = NSHostingView(rootView: ContentView())
    hosting.sizingOptions = []
    panel.contentView = hosting
    AppState.shared.panelPresented = true
    let frames = await waitForPreview(
      in: hosting, dimension: "240×720", previous: nil,
      leadTitle: "layout-gif", imageIdentifier: "lab-gif-preview"
    )
    if let frames {
      let preview = try XCTUnwrap(frames.preview)
      let metadata = try XCTUnwrap(frames.metadata)
      XCTAssertTrue(contains(preview, frames.image), "playing GIF escapes preview")
      XCTAssertTrue(contains(panel.frame, frames.image), "playing GIF escapes window")
      let overlap = frames.image.intersection(metadata)
      XCTAssertFalse(overlap.width > 1 && overlap.height > 1, "playing GIF overlaps metadata")
      XCTAssertNotNil(frames.list)
    }
    XCTAssertEqual(AppState.shared.preview.layoutListWidth, split.listWidth, accuracy: 0.5)
    XCTAssertEqual(
      panel.frame.width,
      split.totalWidth + AppState.shared.preview.railExtraWidth,
      accuracy: 0.5
    )
    XCTAssertFalse(panel.isVisible)
    XCTAssertFalse(panel.isKeyWindow)
    XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, front)
  }

  func testImageRowShowsAnEditedTitleAlongsideItsThumbnail() async throws {
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let item = imageItem(pixels: NSSize(width: 32, height: 32), title: "row-image-before")
    item.pin = "s"
    let decorator = history.add(item)
    decorator.thumbnailImage = try XCTUnwrap(item.image)
    let panel = makeProbe(size: NSSize(width: 320, height: 80))
    let hosting = NSHostingView(rootView:
      HistoryItemView(item: decorator, previous: nil, next: nil, index: 0)
        .environment(AppState.shared)
        .environment(ModifierFlags())
        .frame(width: 320, height: 80)
    )
    hosting.sizingOptions = []
    panel.contentView = hosting
    let axApp = AXUIElementCreateApplication(getpid())
    var windows: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windows)
    pump(0.15)
    hosting.layoutSubtreeIfNeeded()
    XCTAssertTrue(accessibilityNodes(from: hosting).contains { $0.text.contains("row-image-before") },
                  "named image row hides its title while a thumbnail exists")
    item.title = "row-image-after"
    try Storage.shared.save()
    await Task.yield()
    pump(0.15)
    hosting.layoutSubtreeIfNeeded()
    let nodes = accessibilityNodes(from: hosting)
    XCTAssertTrue(nodes.contains { $0.text.contains("row-image-after") }, "edited image alias is not visible in the row")
    XCTAssertFalse(nodes.contains { $0.text.contains("row-image-before") }, "stale alias remains in the row")
    XCTAssertNotNil(decorator.thumbnailImage)
    XCTAssertEqual(item.pin, "s")
    XCTAssertFalse(panel.isVisible)
    XCTAssertFalse(panel.isKeyWindow)
    XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, front)
  }

  func testHistoryRowFixedEndsLetCenterAbsorbWidth() async throws {
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let savedCompact = Defaults[.compactRows]
    Defaults[.compactRows] = false
    defer {
      Defaults[.compactRows] = savedCompact
    }

    let pinnedItem = imageItem(pixels: NSSize(width: 80, height: 48), title: "slot-pinned")
    pinnedItem.pin = "s"
    let pinned = history.add(pinnedItem)
    pinned.thumbnailImage = try XCTUnwrap(pinnedItem.image)
    let blankItem = HistoryItem(contents: [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: Data("alpha beta gamma delta.\nsecond line of the copied note stays readable.".utf8)
      )
    ])
    blankItem.title = "slot-blank"
    Storage.shared.context.insert(blankItem)
    let blank = history.add(blankItem)

    let narrowPinned = await mountedRowSlots(pinned, width: 340)
    let widePinned = await mountedRowSlots(pinned, width: 520)
    let blankSlots = await mountedRowSlots(blank, width: 340)
    let narrow = try XCTUnwrap(narrowPinned)
    let wide = try XCTUnwrap(widePinned)
    let emptyShortcut = try XCTUnwrap(blankSlots)

    XCTAssertEqual(narrow.shortcuts.width, wide.shortcuts.width, accuracy: 1, "shortcut slot resized with the row")
    XCTAssertEqual(narrow.shortcuts.width, emptyShortcut.shortcuts.width, accuracy: 1, "blank shortcut slot collapsed")
    XCTAssertGreaterThan(narrow.shortcuts.width, 24)
    let narrowPin = try XCTUnwrap(narrow.menu, "pinned row lost its pin slot")
    let widePin = try XCTUnwrap(wide.menu)
    XCTAssertEqual(narrowPin.width, widePin.width, accuracy: 1, "pin slot resized")
    XCTAssertEqual(narrowPin.width, HistoryRowMetrics.pinWidth, accuracy: 2)
    let grown = wide.window.width - narrow.window.width
    XCTAssertGreaterThan(grown, 100)
    XCTAssertEqual(wide.preview.width - narrow.preview.width, grown, accuracy: 8, "center slot did not absorb the extra width")
    XCTAssertEqual(wide.shortcuts.width, narrow.shortcuts.width, accuracy: 1)
    let narrowShortcutFromEdge = narrow.window.maxX - narrow.shortcuts.maxX
    let wideShortcutFromEdge = wide.window.maxX - wide.shortcuts.maxX
    XCTAssertEqual(narrowShortcutFromEdge, wideShortcutFromEdge, accuracy: 4, "shortcut slot did not translate with the row edge")
    let narrowMenuFromEdge = narrow.window.maxX - narrowPin.maxX
    let wideMenuFromEdge = wide.window.maxX - widePin.maxX
    XCTAssertEqual(narrowMenuFromEdge, wideMenuFromEdge, accuracy: 4, "action slot did not translate with the row edge")
    XCTAssertLessThanOrEqual(narrow.preview.maxX, narrow.shortcuts.minX + 1)
    // 图钉与快捷键是同级按钮：相邻，只留 pinShortcutGap。
    XCTAssertLessThanOrEqual(narrowPin.maxX, narrow.shortcuts.minX + 1)
    XCTAssertEqual(narrow.shortcuts.minX - narrowPin.maxX, HistoryRowMetrics.pinShortcutGap, accuracy: 1.5)
    XCTAssertEqual(narrow.shortcuts.height, HistoryRowMetrics.contentHeight, accuracy: 2,
                   "the whole row must keep its fixed height")
    XCTAssertEqual(narrow.preview.height, HistoryRowMetrics.thumbnailHeight, accuracy: 2,
                   "image rows reserve the metadata line inside the existing row height")
    XCTAssertEqual(emptyShortcut.preview.height, HistoryRowMetrics.contentHeight, accuracy: 1)
    XCTAssertNotNil(narrow.sourceBox, "image rows must keep their tag/source metadata")
    XCTAssertGreaterThan(narrow.preview.width, 120, "center slot is still a decorative thumbnail")
    XCTAssertTrue(narrow.texts.contains { $0.contains("slot-pinned") }, "image alias is not readable in the row")
    XCTAssertTrue(emptyShortcut.texts.contains { $0.contains("second line") }, "text row does not show a useful excerpt")
    XCTAssertTrue(emptyShortcut.texts.contains { $0.contains(blank.rowCaption) },
                  "body excerpt hides the source and content-kind caption")
    let sourceBox = try XCTUnwrap(emptyShortcut.sourceBox, "source caption has no layout frame")
    XCTAssertGreaterThan(sourceBox.height, 6)
    XCTAssertTrue(contains(emptyShortcut.preview, sourceBox), "source caption is clipped below the fixed row")
    if let icon = narrow.icon {
      XCTAssertEqual(icon.width, 15, accuracy: 1)
      XCTAssertEqual(icon.height, 15, accuracy: 1)
      if let wideIcon = wide.icon {
        XCTAssertEqual(icon.minX - narrow.window.minX, wideIcon.minX - wide.window.minX, accuracy: 1)
      }
    }

    Defaults[.compactRows] = true
    let compactSlots = await mountedRowSlots(blank, width: 340)
    let compact = try XCTUnwrap(compactSlots)
    XCTAssertLessThan(compact.preview.height, 40, "compact preference was ignored")
    XCTAssertEqual(compact.shortcuts.width, narrow.shortcuts.width, accuracy: 1)
    XCTAssertFalse(probe?.isVisible ?? true)
    XCTAssertFalse(probe?.isKeyWindow ?? true)
    XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, front)
  }

  func testRowDecorationsDoNotInterceptPointerHitTesting() async throws {
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let image = imageItem(pixels: NSSize(width: 80, height: 80), title: "passive-image-caption")
    let decorator = history.add(image)
    decorator.thumbnailImage = try XCTUnwrap(image.image)
    _ = await mountedRowSlots(decorator, width: 360)
    let root = try XCTUnwrap(probe?.contentView)
    let thumbnail = try XCTUnwrap(view(in: root, identifier: "lab-row-preview-\(decorator.id.uuidString)"))
    let caption = try XCTUnwrap(textFields(in: root).first { $0.stringValue == "passive-image-caption" })
    for decoration in [thumbnail, caption] {
      XCTAssertNil(decoration.hitTest(NSPoint(x: decoration.frame.midX, y: decoration.frame.midY)),
                   "passive preview decoration intercepts the row's pointer path")
    }
    // The shortcut lane is an interactive row control, not a decoration: it may
    // intercept, but a click there must select the row and never copy it.
    let recorder = try XCTUnwrap(
      view(in: root, identifier: "lab-pin-shortcut-\(decorator.id.uuidString)") as? PinnedShortcutRecorder
    )
    let cell = NSPoint(x: recorder.bounds.midX, y: recorder.bounds.midY)
    let laneHit = root.hitTest(recorder.convert(cell, to: root.superview))
    XCTAssertNotNil(laneHit, "interactive shortcut lane lost its pointer path")
    var copies = 0
    Clipboard.shared.copyProbe = { _, _ in copies += 1 }
    let event = try XCTUnwrap(NSEvent.mouseEvent(
      with: .leftMouseDown, location: cell, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: probe?.windowNumber ?? 0,
      context: nil, eventNumber: 1, clickCount: 1, pressure: 1
    ))
    recorder.mouseDown(with: event)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    XCTAssertEqual(AppState.shared.navigator.leadHistoryItem?.id, decorator.id, "lane click did not select the row")
    XCTAssertEqual(copies, 0, "lane click committed a copy")
    Clipboard.shared.copyProbe = nil
    let text = HistoryItem(contents: [
      HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data("passive text row".utf8))
    ])
    text.title = "passive text row"
    Storage.shared.context.insert(text)
    let note = history.add(text)
    _ = await mountedRowSlots(note, width: 360)
    let textSlot = try XCTUnwrap(view(in: probe?.contentView, identifier: "lab-row-preview-\(note.id.uuidString)"))
    XCTAssertNil(textSlot.hitTest(NSPoint(x: textSlot.frame.midX, y: textSlot.frame.midY)),
                 "empty native text-slot host intercepts row clicks")
    XCTAssertFalse(probe?.isVisible ?? true)
    XCTAssertFalse(probe?.isKeyWindow ?? true)
    XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, front)
  }

  func testRowMiniViewportCropsOverflowAndFadesOnlyThen() async throws {
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let savedCompact = Defaults[.compactRows]
    Defaults[.compactRows] = false
    defer { Defaults[.compactRows] = savedCompact }

    let tallItem = imageItem(pixels: NSSize(width: 40, height: 200), title: "")
    let tall = history.add(tallItem)
    tall.thumbnailImage = try XCTUnwrap(NSImage(data: LabSmokeCanvas.png(pixels: NSSize(width: 40, height: 200)) ?? Data()))
    // 元信息占用底部 18pt 后，横图样本仍需真正落在缩略图槽内，才能检测“不该淡出”。
    let wideItem = imageItem(pixels: NSSize(width: 320, height: 40), title: "")
    let wide = history.add(wideItem)
    wide.thumbnailImage = try XCTUnwrap(NSImage(data: LabSmokeCanvas.png(pixels: NSSize(width: 320, height: 40)) ?? Data()))
    let namedItem = imageItem(pixels: NSSize(width: 80, height: 80), title: "visible-alias")
    let named = history.add(namedItem)
    named.thumbnailImage = try XCTUnwrap(namedItem.image)

    let tallMeasured = await mountedRowSlots(tall, width: 360)
    let tallSlots = try XCTUnwrap(tallMeasured)
    let tallView = try XCTUnwrap(view(in: probe?.contentView, identifier: "lab-row-preview-\(tall.id.uuidString)"))
    let tallPixels = try XCTUnwrap(renderedPixels(of: tallView))
    let wideMeasured = await mountedRowSlots(wide, width: 360)
    let wideSlots = try XCTUnwrap(wideMeasured)
    let wideView = try XCTUnwrap(view(in: probe?.contentView, identifier: "lab-row-preview-\(wide.id.uuidString)"))
    let widePixels = try XCTUnwrap(renderedPixels(of: wideView))
    let namedMeasured = await mountedRowSlots(named, width: 360)
    let namedSlots = try XCTUnwrap(namedMeasured)
    XCTAssertEqual(tallSlots.preview.height, wideSlots.preview.height, accuracy: 1)
    XCTAssertEqual(tallSlots.preview.height, HistoryRowMetrics.thumbnailHeight, accuracy: 2)
    XCTAssertEqual(tallSlots.shortcuts.height, HistoryRowMetrics.contentHeight, accuracy: 2)
    let tallAspect = 200.0 / 40.0
    let unboundedTall = tallSlots.preview.width * tallAspect
    XCTAssertGreaterThan(unboundedTall, tallSlots.preview.height + 24, "portrait fixture does not overflow the slot")
    XCTAssertLessThan(tallSlots.preview.height, unboundedTall / 2, "portrait row adopted unbounded height")
    XCTAssertGreaterThan(tallPixels.topAlpha, 180, "cropped image top is not opaque")
    XCTAssertLessThan(tallPixels.bottomAlpha, tallPixels.topAlpha - 80, "overflow did not fade the clip edge")
    XCTAssertFalse(tallPixels.bottomIsSourceBlue, "portrait row shows the source bottom instead of cropping from the top")
    XCTAssertGreaterThan(widePixels.imageBottomAlpha, 180, "fitting image was faded")
    XCTAssertTrue(widePixels.topIsSourceRed, "fitting image is not top-anchored")
    XCTAssertTrue(namedSlots.texts.contains { $0.contains("visible-alias") })
    let titleBox = try XCTUnwrap(namedSlots.titleBox, "alias has no measurable text frame")
    XCTAssertGreaterThan(titleBox.height, 8)
    XCTAssertLessThan(titleBox.height, namedSlots.preview.height * 0.45, "alias covers most of the preview")
    let titleAlpha = try XCTUnwrap(opaqueTextAlpha(in: probe?.contentView, containing: "visible-alias"))
    XCTAssertGreaterThan(titleAlpha, 0.45, "alias text is transparent")
    XCTAssertFalse(probe?.isVisible ?? true)
    XCTAssertFalse(probe?.isKeyWindow ?? true)
    XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, front)
  }

  func testPreviewCanvasCentersMediaAndFitsPDF() async throws {
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    detachAppPanel()
    let axApp = AXUIElementCreateApplication(getpid())
    var axWindows: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &axWindows)

    let small = history.add(imageItem(pixels: NSSize(width: 48, height: 48), title: "canvas-small"))
    let tall = history.add(imageItem(pixels: NSSize(width: 60, height: 240), title: "canvas-tall"))
    let note = HistoryItem(contents: [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: Data(String(repeating: "readable line\n", count: 30).utf8)
      )
    ])
    note.title = "canvas-text"
    Storage.shared.context.insert(note)
    let textItem = history.add(note)
    let pdfURL = try pdfFixture()
    defer { LabSmokeCanvas.cleanup() }
    let pdfItem = HistoryItem(contents: [
      HistoryItemContent(type: NSPasteboard.PasteboardType.fileURL.rawValue, value: pdfURL.dataRepresentation),
      HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data("page.pdf".utf8))
    ])
    pdfItem.title = "canvas-pdf"
    Storage.shared.context.insert(pdfItem)
    let pdf = history.add(pdfItem)

    let split = PanelSplit(listWidth: PanelSplit.minimumList, previewWidth: 480, previewOpen: true, height: 360)
    AppState.shared.preview.applyLayout(split: split)
    AppState.shared.navigator.select(item: small)
    let panel = makeProbe(size: NSSize(width: split.totalWidth, height: split.height))
    let hosting = NSHostingView(rootView: ContentView())
    hosting.sizingOptions = []
    panel.contentView = hosting
    AppState.shared.panelPresented = true

    let smallMeasured = await waitForCanvas(in: hosting, lead: "canvas-small", contentID: "lab-image-preview")
    let smallFrames = try XCTUnwrap(smallMeasured)
    assertCanvasInset(smallFrames)
    assertCentered(smallFrames, aspect: 1, label: "small")
    let metadataBottom = try XCTUnwrap(smallFrames.metadata).minY - smallFrames.window.minY
    XCTAssertLessThan(metadataBottom, 28, "metadata left the bottom anchor")

    AppState.shared.navigator.select(item: tall)
    let tallMeasured = await waitForCanvas(in: hosting, lead: "canvas-tall", contentID: "lab-image-preview")
    let tallFrames = try XCTUnwrap(tallMeasured)
    assertCanvasInset(tallFrames)
    assertCentered(tallFrames, aspect: 240.0 / 60.0, label: "tall")
    XCTAssertEqual(tallFrames.canvas.minX, smallFrames.canvas.minX, accuracy: 1)
    XCTAssertEqual(tallFrames.canvas.width, smallFrames.canvas.width, accuracy: 1)

    AppState.shared.navigator.select(item: textItem)
    let textMeasured = await waitForCanvas(in: hosting, lead: "canvas-text", contentID: "lab-preview-body")
    let textFrames = try XCTUnwrap(textMeasured)
    let canvas = textFrames.canvas
    let text = textFrames.content
    XCTAssertNil(
      view(in: hosting, identifier: "lab-preview-title"),
      "text preview still has a title field"
    )
    XCTAssertLessThan(abs(text.minX - canvas.minX), 12, "body is not at the canvas leading edge")
    XCTAssertLessThan(abs(text.maxY - canvas.maxY), 24, "body is not top-aligned in the canvas")
    let metadata = try XCTUnwrap(textFrames.metadata, "text footer was not installed")
    let footerOverlap = text.intersection(metadata)
    XCTAssertFalse(footerOverlap.width > 1 && footerOverlap.height > 1, "text overlaps the footer")
    let scrolls = scrollViews(in: hosting).filter {
      canvas.insetBy(dx: -4, dy: -4).contains(CGPoint(x: $0.accessibilityFrame().midX, y: $0.accessibilityFrame().midY))
    }
    XCTAssertEqual(scrolls.count, 1, "text preview has nested unbounded scroll views")
    XCTAssertTrue(scrolls.first?.documentView is NSTextView)
    XCTAssertTrue((scrolls.first?.documentView as? NSTextView)?.isSelectable ?? false)
    XCTAssertFalse((scrolls.first?.documentView as? NSTextView)?.isEditable ?? true, "body started in edit mode")
    XCTAssertNil(view(in: hosting, identifier: "lab-preview-edit-save"))
    XCTAssertNil(view(in: hosting, identifier: "lab-preview-edit-cancel"))

    AppState.shared.navigator.select(item: pdf)
    let pdfMeasured = await waitForCanvas(in: hosting, lead: "canvas-pdf", contentID: "lab-pdf-preview")
    let pdfFrames = try XCTUnwrap(pdfMeasured)
    assertCanvasInset(pdfFrames)
    XCTAssertTrue(contains(pdfFrames.canvas, pdfFrames.content), "PDF escapes the canvas")
    let overlap = pdfFrames.content.intersection(try XCTUnwrap(pdfFrames.metadata))
    XCTAssertFalse(overlap.width > 1 && overlap.height > 1, "PDF overlaps metadata")
    XCTAssertLessThanOrEqual(pdfFrames.content.height, pdfFrames.canvas.height + 1)
    let pdfView = try XCTUnwrap(firstPDFView(in: hosting), "PDF view was not installed")
    let fit = pdfView.scaleFactorForSizeToFit
    XCTAssertGreaterThan(fit, 0.05)
    XCTAssertEqual(pdfView.scaleFactor, fit, accuracy: max(0.05, fit * 0.12), "PDF is not fit to the canvas")
    XCTAssertLessThan(pdfView.scaleFactor, 1, "letter page was left at an uncapped scale")
    XCTAssertFalse(panel.isVisible)
    XCTAssertFalse(panel.isKeyWindow)
    XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, front)
  }

  /// A body edit in the preview must keep the item's pin and stored title.
  func testPreviewBodyEditKeepsPinAndTitle() throws {
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let item = HistoryItem(contents: [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: Data("pin body".utf8)
      )
    ])
    item.title = "合成标题原"
    item.pin = "s"
    Storage.shared.context.insert(item)
    let decorator = history.add(item)
    XCTAssertEqual(decorator.item.pin, "s")
    let root = OriginalTextEditSection(item: decorator)
      .environment(AppState.shared)
      .frame(width: 320, height: 220)
    let probe = makeProbe(size: NSSize(width: 320, height: 220))
    let hosting = NSHostingView(rootView: root)
    hosting.sizingOptions = []
    probe.contentView = hosting
    probe.allowsLocalKey = true
    guard !probe.isVisible else {
      XCTFail("editor probe became visible")
      return
    }

    var editor: OriginalTextBodyView?
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      pump(0.05)
      hosting.layoutSubtreeIfNeeded()
      editor = bodyView("lab-preview-edit-body", in: hosting)
      if editor != nil { break }
    }
    let body = try XCTUnwrap(editor, "the live body editor was not installed")
    XCTAssertNil(view(in: hosting, identifier: "lab-preview-title"))
    XCTAssertEqual(body.string, "pin body")
    XCTAssertFalse(body.isEditable)
    XCTAssertNil(view(in: hosting, identifier: "lab-preview-edit-save"))
    body.mouseDown(with: try mouseDown(in: body))
    XCTAssertTrue(body.isEditable, "click did not enter body edit")
    XCTAssertTrue(probe.makeFirstResponder(body))
    body.insertText("pin body 续", replacementRange: NSRange(location: 0, length: body.string.utf16.count))
    pump(0.05)
    body.keyDown(with: try keyDown(code: 36, characters: "\n"))
    pump(0.15)
    _ = probe.makeFirstResponder(nil)
    probe.resignKey()

    XCTAssertEqual(decorator.item.title, "合成标题原", "body edit rewrote the title")
    XCTAssertEqual(decorator.item.text, "pin body 续")
    XCTAssertEqual(decorator.item.pin, "s", "body edit cleared pin")
    XCTAssertFalse(probe.isVisible)
    XCTAssertFalse(probe.isKeyWindow)
    XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, front)
  }

  private func bodyView(_ id: String, in root: NSView) -> OriginalTextBodyView? {
    if let view = view(in: root, identifier: id) as? OriginalTextBodyView { return view }
    if let scroll = view(in: root, identifier: id) as? NSScrollView {
      return scroll.documentView as? OriginalTextBodyView
    }
    return nil
  }

  private func mouseDown(in view: NSView) throws -> NSEvent {
    try XCTUnwrap(NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: NSPoint(x: 4, y: 4),
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: view.window?.windowNumber ?? 0,
      context: nil,
      eventNumber: 1,
      clickCount: 1,
      pressure: 1
    ))
  }

  private func keyDown(code: UInt16, characters: String) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: probe?.windowNumber ?? 0,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: characters,
      isARepeat: false,
      keyCode: code
    ))
  }

  private struct RowSlotFrames {
    var preview: CGRect
    var shortcuts: CGRect
    var menu: CGRect? // 行尾图钉槽；⋯ 已撤
    var window: CGRect
    var texts: [String]
    var icon: CGRect?
    var titleBox: CGRect?
    var sourceBox: CGRect?
  }

  private struct CanvasFrames {
    var canvas: CGRect
    var content: CGRect
    var metadata: CGRect?
    var column: CGRect
    var window: CGRect
  }

  private struct SampledPixels {
    var topAlpha: CGFloat
    var bottomAlpha: CGFloat
    var imageBottomAlpha: CGFloat
    var topIsSourceRed: Bool
    var bottomIsSourceBlue: Bool
  }

  private func mountedRowSlots(_ decorator: HistoryItemDecorator, width: CGFloat) async -> RowSlotFrames? {
    probe?.close()
    probe = nil
    let panel = makeProbe(size: NSSize(width: width, height: 96))
    let root = HistoryItemView(item: decorator, previous: nil, next: nil, index: 0)
      .environment(AppState.shared)
      .environment(ModifierFlags())
      .frame(width: width, height: 96)
    let hosting = NSHostingView(rootView: root)
    hosting.sizingOptions = []
    hosting.frame = NSRect(x: 0, y: 0, width: width, height: 96)
    panel.contentView = hosting
    let axApp = AXUIElementCreateApplication(getpid())
    var windows: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windows)
    let previewID = "lab-row-preview-\(decorator.id.uuidString)"
    let shortcutID = "lab-row-shortcuts-\(decorator.id.uuidString)"
    let menuID = "lab-row-pin-button-\(decorator.id.uuidString)"
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      pump(0.05)
      hosting.layoutSubtreeIfNeeded()
      let nodes = accessibilityNodes(from: hosting)
      guard let preview = nodes.last(where: { $0.id == previewID && $0.frame.width > 8 && $0.frame.height > 8 }),
            let shortcuts = nodes.last(where: { $0.id == shortcutID && $0.frame.width > 8 })
      else { continue }
      let menu = nodes.last(where: { $0.id == menuID && $0.frame.width > 8 })
      let icon = nodes.map(\.frame).first { abs($0.width - 15) < 1.5 && abs($0.height - 15) < 1.5 }
      let titleBox = nodes.first { $0.text.contains(decorator.title) && !$0.text.isEmpty && $0.frame.height > 4 }?.frame
      return RowSlotFrames(
        preview: preview.frame,
        shortcuts: shortcuts.frame,
        menu: menu?.frame,
        window: panel.frame,
        texts: nodes.map(\.text),
        icon: icon,
        titleBox: titleBox,
        sourceBox: nodes.last { $0.id == "lab-row-source-\(decorator.id.uuidString)" && $0.frame.height > 0 }?.frame
      )
    }
    XCTFail("row slots missing for \(decorator.title) ids=\(accessibilityNodes(from: hosting).map(\.id))")
    return nil
  }

  private func waitForCanvas(in hosting: NSView, lead: String, contentID: String) async -> CanvasFrames? {
    let deadline = Date().addingTimeInterval(8)
    var stable: CanvasFrames?
    var stableCount = 0
    while Date() < deadline {
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(40))
      hosting.layoutSubtreeIfNeeded()
      guard AppState.shared.navigator.leadHistoryItem?.title == lead else { continue }
      let nodes = accessibilityNodes(from: hosting)
      let contentFrame = view(in: hosting, identifier: contentID)?.accessibilityFrame()
      guard let canvasView = view(in: hosting, identifier: "lab-preview-canvas"),
            canvasView.accessibilityFrame().width > 20,
            let content = contentFrame ?? nodes.last(where: { $0.id == contentID && $0.frame.width > 8 && $0.frame.height > 8 })?.frame,
            content.width > 8,
            let column = nodes.last(where: { $0.id == "lab-preview-column" && $0.frame.width > 20 })?.frame
      else { continue }
      let frames = CanvasFrames(
        canvas: canvasView.accessibilityFrame(),
        content: content,
        metadata: nodes.last { $0.id == "lab-preview-metadata" && $0.frame.height > 8 }?.frame,
        column: column,
        window: probe?.frame ?? .zero
      )
      if let stable,
         abs(stable.content.width - frames.content.width) < 0.5,
         abs(stable.content.height - frames.content.height) < 0.5 {
        stableCount += 1
        if stableCount >= 2 { return frames }
      } else {
        stable = frames
        stableCount = 0
      }
    }
    XCTFail("canvas did not settle for \(lead) ids=\(accessibilityNodes(from: hosting).map(\.id))")
    return nil
  }

  private func assertCanvasInset(_ frames: CanvasFrames) {
    guard let canvasView = view(in: probe?.contentView, identifier: "lab-preview-canvas"),
          let host = canvasView.superview else {
      XCTFail("real canvas host is missing")
      return
    }
    XCTAssertEqual(canvasView.frame.minX - host.bounds.minX, 16, accuracy: 0.5)
    XCTAssertEqual(host.bounds.maxX - canvasView.frame.maxX, 16, accuracy: 0.5)
    XCTAssertEqual(canvasView.frame.minY - host.bounds.minY, 16, accuracy: 0.5)
    XCTAssertEqual(host.bounds.maxY - canvasView.frame.maxY, 16, accuracy: 0.5,
                   "canvas content touches the footer edge instead of keeping its inset")
    let leading = frames.canvas.minX - frames.column.minX
    let trailing = frames.column.maxX - frames.canvas.maxX
    XCTAssertGreaterThanOrEqual(leading, 14, "canvas leading inset \(leading)")
    XCTAssertGreaterThanOrEqual(trailing, 14, "canvas trailing inset \(trailing)")
    XCTAssertLessThan(abs(leading - trailing), 16, "canvas insets are lopsided \(leading)/\(trailing)")
    XCTAssertTrue(contains(frames.column, frames.canvas), "canvas escapes the preview column")
    if let metadata = frames.metadata {
      XCTAssertLessThanOrEqual(metadata.maxY, frames.canvas.minY + 1, "canvas overlaps metadata")
    }
  }

  private func assertCentered(_ frames: CanvasFrames, aspect: CGFloat, label: String) {
    XCTAssertEqual(frames.content.midX, frames.canvas.midX, accuracy: 8, "\(label) not centered horizontally")
    XCTAssertEqual(frames.content.midY, frames.canvas.midY, accuracy: 8, "\(label) not centered vertically")
    XCTAssertTrue(contains(frames.canvas.insetBy(dx: -2, dy: -2), frames.content), "\(label) escapes canvas")
    let displayed = frames.content.height / max(frames.content.width, 1)
    XCTAssertEqual(displayed, aspect, accuracy: max(0.08, aspect * 0.08), "\(label) aspect was stretched or cropped")
  }

  private func pdfFixture() throws -> URL {
    let document = PDFDocument()
    document.insert(PDFPage(), at: 0)
    let data = try XCTUnwrap(document.dataRepresentation())
    return try XCTUnwrap(LabSmokeCanvas.write(data, name: "page.pdf"))
  }

  private func view(in root: NSView?, identifier: String) -> NSView? {
    guard let root else { return nil }
    if root.accessibilityIdentifier() == identifier { return root }
    for child in root.subviews {
      if let found = view(in: child, identifier: identifier) { return found }
    }
    return nil
  }

  private func scrollViews(in root: NSView?) -> [NSScrollView] {
    guard let root else { return [] }
    var found: [NSScrollView] = []
    func walk(_ view: NSView) {
      if let scroll = view as? NSScrollView { found.append(scroll) }
      view.subviews.forEach(walk)
    }
    walk(root)
    return found
  }

  private func firstPDFView(in root: NSView) -> PDFView? {
    if let pdf = root as? PDFView { return pdf }
    for child in root.subviews {
      if let found = firstPDFView(in: child) { return found }
    }
    return nil
  }

  private func nearestView(_ object: AnyObject) -> NSView? {
    if let view = object as? NSView { return view }
    let sel = NSSelectorFromString("accessibilityParent")
    guard let ns = object as? NSObject, ns.responds(to: sel),
          let parent = ns.perform(sel)?.takeUnretainedValue() else { return nil }
    return nearestView(parent)
  }

  private func opaqueTextAlpha(in root: NSView?, containing needle: String) -> CGFloat? {
    guard let root else { return nil }
    var best: CGFloat?
    func walk(_ object: AnyObject?, depth: Int) {
      guard let object, depth < 40 else { return }
      let value = axString(object, "accessibilityValue") ?? ""
      let label = axString(object, "accessibilityLabel") ?? ""
      let title = (object as? NSTextField)?.stringValue ?? ""
      if value.contains(needle) || label.contains(needle) || title.contains(needle) {
        if let view = object as? NSView {
          best = min(best ?? 1, view.alphaValue)
        } else if let view = nearestView(object) {
          best = min(best ?? 1, view.alphaValue)
        }
      }
      if let view = object as? NSView {
        view.subviews.forEach { walk($0, depth: depth + 1) }
        axKids(view).forEach { walk($0, depth: depth + 1) }
      }
    }
    walk(root, depth: 0)
    return best
  }

  private func renderedPixels(of view: NSView) -> SampledPixels? {
    let bounds = view.bounds
    guard bounds.width > 8, bounds.height > 8 else { return nil }
    let scale: CGFloat = 2
    let pixelsWide = max(1, Int((bounds.width * scale).rounded()))
    let pixelsHigh = max(1, Int((bounds.height * scale).rounded()))
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
    ), NSGraphicsContext(bitmapImageRep: rep) != nil else { return nil }
    rep.size = bounds.size
    view.wantsLayer = false
    view.cacheDisplay(in: bounds, to: rep)

    struct Pixel { var r, g, b, a: CGFloat; var y: Int }
    var pixels: [Pixel] = []
    let strideX = max(1, pixelsWide / 24)
    for y in 0..<pixelsHigh {
      for x in Swift.stride(from: 0, to: pixelsWide, by: strideX) {
        guard let color = rep.colorAt(x: x, y: y) else { continue }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.usingColorSpace(.deviceRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        pixels.append(Pixel(r: r, g: g, b: b, a: a, y: y))
      }
    }
    func isRed(_ pixel: Pixel) -> Bool { pixel.r > 0.75 && pixel.g < 0.25 && pixel.b < 0.25 && pixel.a > 0.4 }
    func isBlue(_ pixel: Pixel) -> Bool { pixel.b > 0.75 && pixel.r < 0.25 && pixel.g < 0.25 && pixel.a > 0.2 }
    guard let reference = rep.copy() as? NSBitmapImageRep else { return nil }
    let axisView = PixelAxisReferenceView(frame: bounds)
    axisView.cacheDisplay(in: axisView.bounds, to: reference)
    guard let low = reference.colorAt(x: pixelsWide / 2, y: 2)?.usingColorSpace(.deviceRGB),
          let high = reference.colorAt(x: pixelsWide / 2, y: pixelsHigh - 3)?.usingColorSpace(.deviceRGB),
          abs(low.redComponent - high.redComponent) > 0.5 else { return nil }
    let topIsHighY = high.redComponent > low.redComponent
    func viewTop(_ y: Int) -> Bool {
      topIsHighY ? y >= pixelsHigh - 8 : y <= 8
    }
    func viewBottom(_ y: Int) -> Bool {
      topIsHighY ? y <= 6 : y >= pixelsHigh - 6
    }
    let bottomMin = pixels.filter { viewBottom($0.y) }.map(\.a).min() ?? 1
    let topAlpha = pixels.filter { viewTop($0.y) }.map(\.a).max() ?? 0
    let blue = pixels.filter(isBlue)
    return SampledPixels(
      topAlpha: topAlpha * 255,
      bottomAlpha: bottomMin * 255,
      imageBottomAlpha: (blue.map(\.a).max() ?? 0) * 255,
      topIsSourceRed: pixels.contains { isRed($0) && viewTop($0.y) },
      bottomIsSourceBlue: pixels.contains { isBlue($0) && viewBottom($0.y) }
    )
  }

  private func detachAppPanel() {
    guard let panel = AppState.shared.appDelegate?.panel else { return }
    appPanel = panel
    detachedContent = panel.contentView
    panel.contentView = NSView(frame: panel.contentView?.frame ?? .zero)
    pump(0.05)
  }

  /// 每一行都必须是同一个高度：缩略图、两行摘要、长标题都不能把某一行撑高。
  func testEveryHistoryRowHasTheSameHeightInBothSections() async throws {
    var seeded: [HistoryItemDecorator] = []
    for index in 0..<3 {
      let item = HistoryItem(contents: [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: Data((
            "用于行高核对的正文摘要，这一行要足够长，长到在列表宽度里必然折成两行，"
            + "这样摘要区的高度才真正被测到，而不是靠短文本侥幸通过。\(index)"
          ).utf8)
        )
      ])
      item.title = "统一行高文本\(index)"
      item.application = "com.apple.TextEdit"
      Storage.shared.context.insert(item)
      seeded.append(history.add(item))
    }
    seeded[0].item.pin = "a"
    let image = imageItem(pixels: NSSize(width: 80, height: 60), title: "统一行高图片")
    image.pin = "b"
    _ = history.add(image)
    history.refreshVisibleItems()

    let panel = makeProbe(size: NSSize(width: 420, height: 560))
    let hosting = NSHostingView(rootView: RowPitchHost())
    hosting.sizingOptions = []
    panel.contentView = hosting
    AppState.shared.panelPresented = true
    pump(0.4)
    hosting.needsLayout = true
    hosting.layoutSubtreeIfNeeded()

    let rows = rowPlates(in: hosting)
    XCTAssertEqual(rows.count, 4, "全部 rows=\(rowSummary(rows))")
    assertOneRowHeight(rows, label: "全部")
    // 这 4 行里最后两行是置顶块（pinTo 在下），它们和上面的普通行必须一样高。
    XCTAssertTrue(rows.suffix(2).allSatisfy { $0.pinned }, "常用块应排在列表末尾：\(rowSummary(rows))")
  }

  private struct RowPlate {
    var identifier: String
    var y: CGFloat
    var height: CGFloat
    var pinned: Bool
  }

  /// The highlight plate is the row's own bounds (content + vertical inset),
  /// so its height is the row height the user actually sees.
  private func rowPlates(in root: NSView) -> [RowPlate] {
    var plates: [RowPlate] = []
    func walk(_ view: NSView) {
      let id = view.accessibilityIdentifier()
      if id.hasPrefix("lab-row-highlight-") {
        let frame = view.convert(view.bounds, to: nil)
        let identifier = String(id.dropFirst("lab-row-highlight-".count))
        plates.append(RowPlate(
          identifier: identifier,
          y: frame.minY,
          height: frame.height,
          pinned: history.all.first { $0.id.uuidString == identifier }?.isPinned ?? false
        ))
      }
      view.subviews.forEach(walk)
    }
    walk(root)
    return plates.sorted { $0.y < $1.y }
  }

  private func rowSummary(_ rows: [RowPlate]) -> String {
    rows.map { row in
      let decorator = history.all.first { $0.id.uuidString == row.identifier }
      return "\(decorator?.title ?? "?")\(decorator?.isPinned == true ? "[pin]" : "") h=\(row.height)"
    }.joined(separator: ", ")
  }

  private func assertOneRowHeight(_ rows: [RowPlate], label: String) {
    guard let first = rows.first?.height else {
      XCTFail("\(label): no rows")
      return
    }
    for row in rows {
      XCTAssertEqual(row.height, first, accuracy: 0.5,
                     "\(label): row heights differ; rows=\(rowSummary(rows))")
    }
  }

  private func makeProbe(size: NSSize) -> OffscreenLayoutPanel {
    let panel = OffscreenLayoutPanel(
      contentRect: NSRect(x: -24000, y: -24000, width: size.width, height: size.height),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isReleasedWhenClosed = false
    panel.level = .normal
    panel.collectionBehavior = [.stationary, .ignoresCycle]
    panel.hidesOnDeactivate = true
    probe = panel
    return panel
  }

  private func waitForPreview(
    in hosting: NSView, dimension: String, previous: CGRect?,
    leadTitle: String? = nil, imageIdentifier: String = "lab-image-preview"
  ) async -> PreviewFrames? {
    let deadline = Date().addingTimeInterval(8)
    var stable: PreviewFrames?
    var stableCount = 0
    while Date() < deadline {
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(40))
      hosting.layoutSubtreeIfNeeded()
      let nodes = accessibilityNodes(from: hosting)
      let lead = AppState.shared.navigator.leadHistoryItem?.title
      let expectedLead = leadTitle ?? (dimension == "240×150" ? "layout-landscape" : "layout-portrait")
      guard lead == expectedLead else { continue }
      guard let image = nodes.last(where: { $0.id == imageIdentifier && $0.frame.width > 8 && $0.frame.height > 8 })?.frame,
            let preview = nodes.last(where: { $0.id == "lab-preview-column" && $0.frame.width > 8 })?.frame,
            let metadata = nodes.last(where: { $0.id == "lab-preview-metadata" && $0.frame.height > 8 })?.frame
      else { continue }
      if let previous, abs(image.width - previous.width) < 1, abs(image.height - previous.height) < 1 {
        continue
      }
      let frames = PreviewFrames(
        image: image,
        preview: preview,
        metadata: metadata,
        list: nodes.last { $0.id == "history-scroll-view" }?.frame,
        divider: nodes.last { $0.id == "lab-split-divider" }?.frame,
        window: probe?.frame ?? .zero,
        seen: nodes.map(\.id).sorted().joined(separator: ",")
      )
      if let stable, abs(stable.image.width - frames.image.width) < 0.5, abs(stable.image.height - frames.image.height) < 0.5 {
        stableCount += 1
        if stableCount >= 2 { return frames }
      } else {
        stable = frames
        stableCount = 0
      }
    }
    XCTFail("preview did not settle for \(dimension); ids=\(accessibilityNodes(from: hosting).map(\.id))")
    return nil
  }

  private func assertContained(_ frames: PreviewFrames?, aspect: CGFloat, label: String) {
    guard let frames else { return }
    let window = frames.window
    let image = frames.image
    let preview = frames.preview!
    let metadata = frames.metadata!
    let relativeX = image.minX - window.minX
    XCTAssertGreaterThan(image.width, 8, label)
    XCTAssertGreaterThan(image.height, 8, label)
    XCTAssertGreaterThanOrEqual(relativeX, -0.5, "\(label) image x is negative \(image) window \(window)")
    XCTAssertTrue(contains(window, image), "\(label) image escapes window \(image) \(window)")
    XCTAssertTrue(contains(preview, image), "\(label) image escapes preview \(image) \(preview) seen \(frames.seen)")
    let overlap = image.intersection(metadata)
    XCTAssertFalse(overlap.width > 1 && overlap.height > 1, "\(label) overlaps metadata \(image) \(metadata)")
    XCTAssertGreaterThanOrEqual(preview.minX - window.minX, -0.5, "\(label) preview x \(preview)")
    XCTAssertLessThanOrEqual(preview.maxX, window.maxX + 1, "\(label) preview overflows \(preview)")
    let widthScaled = max(image.width, preview.width) * aspect
    XCTAssertGreaterThan(widthScaled, image.height + 8, "\(label) adopted unbounded height \(image.height); baseline \(widthScaled)")
    for corner in corners(of: image) {
      XCTAssertTrue(window.insetBy(dx: -1, dy: -1).contains(corner), "\(label) corner \(corner) outside window")
      XCTAssertTrue(preview.insetBy(dx: -1, dy: -1).contains(corner), "\(label) corner \(corner) outside preview")
    }
  }

  private func contains(_ outer: CGRect, _ inner: CGRect) -> Bool {
    corners(of: inner).allSatisfy { outer.insetBy(dx: -1, dy: -1).contains($0) }
  }

  private func corners(of rect: CGRect) -> [CGPoint] {
    [
      CGPoint(x: rect.minX, y: rect.minY),
      CGPoint(x: rect.maxX, y: rect.minY),
      CGPoint(x: rect.minX, y: rect.maxY),
      CGPoint(x: rect.maxX, y: rect.maxY)
    ]
  }

  private func pump(_ interval: TimeInterval) {
    let end = Date().addingTimeInterval(interval)
    while Date() < end {
      RunLoop.current.run(mode: .common, before: Date().addingTimeInterval(0.02))
    }
  }

  private func textFields(in root: NSView) -> [NSTextField] {
    var found: [NSTextField] = []
    func walk(_ view: NSView) {
      if let field = view as? NSTextField { found.append(field) }
      view.subviews.forEach(walk)
    }
    walk(root)
    return found
  }

  private func accessibilityNodes(from root: AnyObject?) -> [AccessNode] {
    var found: [AccessNode] = []
    var seen = Set<ObjectIdentifier>()
    func walk(_ object: AnyObject?, depth: Int) {
      guard let object, depth < 40 else { return }
      let token = ObjectIdentifier(object)
      guard seen.insert(token).inserted else { return }
      if let view = object as? NSView {
        record(object, id: view.accessibilityIdentifier(), frame: view.accessibilityFrame(), into: &found)
        var children: [AnyObject] = view.subviews
        children.append(contentsOf: axKids(view))
        children.forEach { walk($0, depth: depth + 1) }
        return
      }
      record(
        object,
        id: axString(object, "accessibilityIdentifier") ?? "",
        frame: axRect(object),
        into: &found
      )
      axKids(object).forEach { walk($0, depth: depth + 1) }
    }
    walk(root, depth: 0)
    return found
  }

  private func record(_ object: AnyObject, id: String, frame: CGRect, into found: inout [AccessNode]) {
    let text = [axString(object, "accessibilityValue"), axString(object, "accessibilityLabel")]
      .compactMap { $0 }
      .joined(separator: " ")
    let resolved = frame.width > 1 ? frame : axRect(object)
    if !id.isEmpty || text.contains("×") || text.contains("240") || text.contains("90") {
      found.append(AccessNode(id: id.isEmpty ? "text" : id, frame: resolved, text: text))
    }
  }

  private func axKids(_ object: AnyObject) -> [AnyObject] {
    let sel = NSSelectorFromString("accessibilityChildren")
    guard let ns = object as? NSObject, ns.responds(to: sel) else { return [] }
    return (ns.perform(sel)?.takeUnretainedValue() as? [AnyObject]) ?? []
  }

  private func axString(_ object: AnyObject, _ name: String) -> String? {
    let sel = NSSelectorFromString(name)
    guard let ns = object as? NSObject, ns.responds(to: sel) else { return nil }
    let raw = ns.perform(sel)?.takeUnretainedValue()
    if let text = raw as? String { return text }
    return raw?.description
  }

  private func axRect(_ object: AnyObject) -> CGRect {
    guard let ns = object as? NSObject else { return .zero }
    if ns.responds(to: NSSelectorFromString("accessibilityFrame")),
       let value = try? ns.value(forKey: "accessibilityFrame") as? NSValue {
      return value.rectValue
    }
    return .zero
  }

  private func imageItem(pixels: NSSize, title: String) -> HistoryItem {
    let data = LabSmokeCanvas.png(pixels: pixels) ?? Data()
    let item = HistoryItem(contents: [
      HistoryItemContent(type: NSPasteboard.PasteboardType.png.rawValue, value: data)
    ])
    item.title = title
    item.application = "com.apple.Preview"
    Storage.shared.context.insert(item)
    return item
  }
}

private struct PreviewFrames {
  var image: CGRect
  var preview: CGRect?
  var metadata: CGRect?
  var list: CGRect?
  var divider: CGRect?
  var window: CGRect
  var seen: String
}

private struct AccessNode {
  var id: String
  var frame: CGRect
  var text: String
}

private final class LiveResizeClosePanel: FloatingPanel<EmptyView> {
  override var inLiveResize: Bool { true }
}

/// Real FloatingPanel, full product root, offscreen. Ordering and key are refused
/// so the public resize delegate can run without surfacing a window.
private final class OffscreenResizePanel: FloatingPanel<ContentView> {
  var orderAttempts = 0

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
  override func makeKey() { orderAttempts += 1 }
  override func becomeKey() { orderAttempts += 1 }
  override func makeMain() { orderAttempts += 1 }
  override func makeKeyAndOrderFront(_ sender: Any?) { orderAttempts += 1 }
  override func orderFront(_ sender: Any?) { orderAttempts += 1 }
  override func orderFrontRegardless() { orderAttempts += 1 }
  override func orderBack(_ sender: Any?) { orderAttempts += 1 }
  override func orderOut(_ sender: Any?) { orderAttempts += 1 }
  override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) { orderAttempts += 1 }

  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}

/// Non-live resize goes through NSWindow.setFrame and the public delegate.
/// Calling absorbWidth directly missed the AX/setFrame bypass.
@MainActor
final class PanelFrameResizeTests: XCTestCase {
  private var probe: OffscreenResizePanel?
  private var savedPanel: FloatingPanel<ContentView>?
  private var savedContent: NSView?
  private var savedSplit = standardPanelSplit
  private var savedPresented = false
  private var savedDefaults: (NSSize, CGFloat, CGFloat, Bool, NSPoint) = (.zero, 0, 0, true, .zero)
  private var frontPID: pid_t = 0
  private var hostWasVisible = false
  private var savedRailVisible = false
  private var savedRailDefaultsVisible = false

  override func setUp() {
    super.setUp()
    savedRailVisible = AppState.shared.managementRailVisible
    AppState.shared.managementRailVisible = false
    // SlideoutController 直接读 Defaults；本机偏好展开着左栏时会把 72pt 算进窗口。
    savedRailDefaultsVisible = Defaults[.managementRailVisible]
    Defaults[.managementRailVisible] = false
    frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    savedPresented = AppState.shared.panelPresented
    savedSplit = AppState.shared.preview.currentSplit
    savedDefaults = (
      Defaults[.windowSize],
      Defaults[.listColumnWidth],
      Defaults[.previewColumnWidth],
      Defaults[.openPreviewAutomatically],
      Defaults[.windowPosition]
    )
    AppState.shared.closeOCR()
    AppState.shared.panelPresented = false
    savedPanel = AppState.shared.appDelegate?.panel
    hostWasVisible = savedPanel?.isVisible ?? false
    savedContent = savedPanel?.contentView
    savedPanel?.contentView = NSView(frame: savedPanel?.contentView?.frame ?? .zero)
    let panel = OffscreenResizePanel(
      contentRect: NSRect(x: -24000, y: -24000, width: 400, height: 640),
      onClose: {},
      view: { ContentView() }
    )
    panel.isReleasedWhenClosed = false
    panel.level = .normal
    panel.collectionBehavior = [.stationary, .ignoresCycle, .auxiliary]
    panel.hidesOnDeactivate = true
    probe = panel
  }

  override func tearDown() {
    AppState.shared.panelPresented = false
    AppState.shared.closeOCR()
    probe?.close()
    probe = nil
    if let savedPanel {
      AppState.shared.appDelegate?.panel = savedPanel
      savedPanel.contentView = savedContent
    }
    savedContent = nil
    savedPanel = nil
    AppState.shared.preview.applyLayout(split: savedSplit)
    AppState.shared.preview.temporaryOCRWidth = 0
    AppState.shared.preview.temporaryPreviewBorrow = 0
    AppState.shared.preview.ocrBaseFrame = nil
    AppState.shared.preview.suppressesFramePersistence = false
    AppState.shared.panelPresented = savedPresented
    AppState.shared.managementRailVisible = savedRailVisible
    Defaults[.managementRailVisible] = savedRailDefaultsVisible
    Defaults[.windowSize] = savedDefaults.0
    Defaults[.listColumnWidth] = savedDefaults.1
    Defaults[.previewColumnWidth] = savedDefaults.2
    Defaults[.openPreviewAutomatically] = savedDefaults.3
    Defaults[.windowPosition] = savedDefaults.4
    super.tearDown()
  }

  func testNonLiveSetFrameTracksClosedListFromWideDownToMinimum() {
    let preview = AppState.shared.preview
    preview.layoutPreviewWidth = 620
    preview.layoutListWidth = 400
    preview.currentHeight = 640
    preview.state = .closed
    preview.temporaryOCRWidth = 0
    preview.temporaryPreviewBorrow = 0
    seedUnsavedSplit(list: 400, preview: 620, open: false)
    install()
    resize(to: 400)
    AppState.shared.panelPresented = true
    pump(0.25)
    guard let probe else { return }
    XCTAssertFalse(probe.isVisible)
    XCTAssertLessThan(probe.frame.maxX, 0)
    XCTAssertEqual(preview.layoutListWidth, 400, accuracy: 0.5)

    resize(to: 640)
    XCTAssertEqual(probe.frame.width, 640, accuracy: 0.5, "wide setFrame did not stick")
    XCTAssertEqual(
      preview.layoutListWidth, 640, accuracy: 0.5,
      "closed non-live widen left the list at \(preview.layoutListWidth)"
    )

    let immediate = resizeReturningImmediate(to: 320)
    XCTAssertEqual(
      probe.frame.width, 320, accuracy: 0.5,
      "wide 640 → 320 settled at \(probe.frame.width) immediate=\(immediate) list=\(preview.layoutListWidth); old controller width must not clamp the window"
    )
    XCTAssertEqual(preview.layoutListWidth, 320, accuracy: 0.5)
    XCTAssertEqual(preview.layoutPreviewWidth, 620, accuracy: 0.5, "closed resize smashed the remembered preview")
    assertUnsaved(list: 400, preview: 620, open: false)
    assertStayedOffscreen()
  }

  func testNonLiveSetFrameAbsorbsOpenPreviewWithoutSavingOCRWidth() {
    let preview = AppState.shared.preview
    preview.applyLayout(split: PanelSplit(listWidth: 400, previewWidth: 620, previewOpen: true, height: 640))
    seedUnsavedSplit(list: 400, preview: 620, open: true)
    install()
    resize(to: 1020)
    AppState.shared.panelPresented = true
    pump(0.2)
    XCTAssertEqual(preview.layoutListWidth, 400, accuracy: 0.5)
    XCTAssertEqual(preview.layoutPreviewWidth, 620, accuracy: 0.5, "opening frame smashed the stored preview")

    resize(to: 1180)
    XCTAssertEqual(probe?.frame.width ?? 0, 1180, accuracy: 0.5)
    XCTAssertEqual(preview.layoutListWidth, 400, accuracy: 0.5, "open resize moved the list")
    XCTAssertEqual(preview.layoutPreviewWidth, 780, accuracy: 0.5, "open non-live widen left preview at \(preview.layoutPreviewWidth)")
    assertUnsaved(list: 400, preview: 620, open: true)

    preview.temporaryOCRWidth = 180
    preview.temporaryPreviewBorrow = 0
    preview.suppressesFramePersistence = true
    resize(to: 1360)
    preview.suppressesFramePersistence = false
    XCTAssertEqual(probe?.frame.width ?? 0, 1360, accuracy: 0.5)
    XCTAssertEqual(preview.layoutListWidth, 400, accuracy: 0.5)
    XCTAssertEqual(preview.layoutPreviewWidth, 780, accuracy: 0.5, "OCR frame was written into the preview split")
    XCTAssertEqual(preview.temporaryOCRWidth, 180, accuracy: 0.5)
    assertUnsaved(list: 400, preview: 620, open: true)

    preview.layoutPreviewWidth = 620
    preview.temporaryPreviewBorrow = 40
    resize(to: 1160)
    XCTAssertEqual(preview.layoutListWidth, 400, accuracy: 0.5)
    XCTAssertEqual(preview.layoutPreviewWidth, 620, accuracy: 0.5, "borrowed OCR frame smashed the stored preview")
    assertUnsaved(list: 400, preview: 620, open: true)
    assertStayedOffscreen()
  }

  private func install() {
    guard let probe, let delegate = AppState.shared.appDelegate else {
      XCTFail("app panel is required so setFrame reaches the product delegate")
      return
    }
    delegate.panel = probe
  }

  private func resize(to width: CGFloat) {
    _ = resizeReturningImmediate(to: width)
  }

  @discardableResult
  private func resizeReturningImmediate(to width: CGFloat) -> CGFloat {
    guard let probe else { return 0 }
    probe.setFrame(NSRect(x: -24000, y: -24000, width: width, height: 640), display: true)
    let immediate = probe.frame.width
    pump(0.2)
    return immediate
  }

  private func seedUnsavedSplit(list: CGFloat, preview: CGFloat, open: Bool) {
    Defaults[.listColumnWidth] = list
    Defaults[.previewColumnWidth] = preview
    Defaults[.openPreviewAutomatically] = open
    Defaults[.windowSize] = NSSize(width: list, height: 500)
    Defaults[.windowPosition] = NSPoint(x: 0.42, y: 0.73)
  }

  private func assertUnsaved(list: CGFloat, preview: CGFloat, open: Bool) {
    XCTAssertEqual(Defaults[.listColumnWidth], list, accuracy: 0.5)
    XCTAssertEqual(Defaults[.previewColumnWidth], preview, accuracy: 0.5)
    XCTAssertEqual(Defaults[.openPreviewAutomatically], open)
    XCTAssertEqual(Defaults[.windowSize].height, 500, accuracy: 0.5)
    XCTAssertEqual(Defaults[.windowPosition].x, 0.42, accuracy: 0.001)
    XCTAssertEqual(Defaults[.windowPosition].y, 0.73, accuracy: 0.001)
  }

  private func assertStayedOffscreen() {
    guard let probe else { return }
    XCTAssertFalse(probe.isVisible)
    XCTAssertFalse(probe.isKeyWindow)
    XCTAssertFalse(probe.isMainWindow)
    XCTAssertEqual(probe.orderAttempts, 0)
    XCTAssertLessThan(probe.frame.maxX, 0)
    XCTAssertLessThan(probe.frame.maxY, 0)
    XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontPID)
    XCTAssertEqual(savedPanel?.isVisible ?? false, hostWasVisible)
  }

  private func pump(_ interval: TimeInterval) {
    let end = Date().addingTimeInterval(interval)
    while Date() < end {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
  }
}

/// Real FloatingPanel + ContentView, offscreen. Ordering and key are refused.
private final class OffscreenTagPanel: FloatingPanel<ContentView> {
  var orderAttempts = 0

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
  override func makeKey() { orderAttempts += 1 }
  override func becomeKey() { orderAttempts += 1 }
  override func makeMain() { orderAttempts += 1 }
  override func makeKeyAndOrderFront(_ sender: Any?) { orderAttempts += 1 }
  override func orderFront(_ sender: Any?) { orderAttempts += 1 }
  override func orderFrontRegardless() { orderAttempts += 1 }
  override func orderBack(_ sender: Any?) { orderAttempts += 1 }
  override func orderOut(_ sender: Any?) { orderAttempts += 1 }
  override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) { orderAttempts += 1 }

  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}

/// Preview tag mouseDown must keep the editor through a run-loop turn, then drop it on lead change.
@MainActor
final class PreviewTagEditorClickTests: XCTestCase {
  private var panel: OffscreenTagPanel?
  private var savedPresented = false
  private var savedPinned = false
  private var savedSplit = standardPanelSplit
  private var savedDelegate: AppDelegate?
  private var savedDelegatePanel: FloatingPanel<ContentView>?
  private var frontPID: pid_t = 0

  override func setUp() {
    super.setUp()
    XCTAssertTrue(LabRuntime.isIsolated, "refusing a tag-editor probe that is not isolated")
    XCTAssertTrue(Storage.shared.isInMemory)
    frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    savedPresented = AppState.shared.panelPresented
    savedPinned = AppState.shared.windowPinned
    savedSplit = AppState.shared.preview.currentSplit
    savedDelegate = AppState.shared.appDelegate
    savedDelegatePanel = savedDelegate?.panel
    History.shared.clearAll()
    AppState.shared.windowPinned = false
    AppState.shared.workspaceSection = .all
    AppState.shared.panelPresented = false
    AppState.shared.clearTagEditor()
    AppState.shared.preview.applyLayout(
      split: PanelSplit(listWidth: 360, previewWidth: 520, previewOpen: true, height: 520)
    )
    Clipboard.shared.copyProbe = nil
  }

  override func tearDown() {
    panel?.close()
    panel = nil
    AppState.shared.panelPresented = false
    AppState.shared.clearTagEditor()
    AppState.shared.navigator.select(item: nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    if let savedDelegate {
      savedDelegate.panel = savedDelegatePanel
    }
    AppState.shared.appDelegate = savedDelegate
    AppState.shared.preview.applyLayout(split: savedSplit)
    AppState.shared.windowPinned = savedPinned
    AppState.shared.panelPresented = savedPresented
    History.shared.clearAll()
    Clipboard.shared.copyProbe = nil
    super.tearDown()
  }

  func testPreviewTagMouseDownKeepsTheEditorThroughTheRunLoop() {
    let first = textItem("tag-click-first")
    let second = textItem("tag-click-second")
    AppState.shared.navigator.select(item: first)
    let hostPanel = makePanel()
    let delegate = AppDelegate()
    AppState.shared.appDelegate = delegate
    delegate.panel = hostPanel
    AppState.shared.panelPresented = true

    let axApp = AXUIElementCreateApplication(getpid())
    var axWindows: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &axWindows)
    hostPanel.contentView?.layoutSubtreeIfNeeded()
    pump(0.2)

    let ids = identifiers(in: hostPanel.contentView)
    XCTAssertFalse(ids.contains("lab-preview-tag"), "preview tag is read-only, not an editor ids=\(ids)")
    XCTAssertTrue(ids.contains("lab-preview-delete"), "preview delete was not installed ids=\(ids)")
    XCTAssertNil(AppState.shared.tagEditorItem)

    AppState.shared.beginTagEdit(for: first, anchor: .row)
    let immediate = AppState.shared.tagEditorItem?.id
    pump(0.35)
    hostPanel.contentView?.layoutSubtreeIfNeeded()
    let afterIDs = identifiers(in: hostPanel.contentView)
    XCTAssertEqual(immediate, first.id, "row tag entry did not set the editor")
    XCTAssertTrue(AppState.shared.presentsTagEditor(first, at: .row), "editor did not survive the run loop")
    XCTAssertFalse(AppState.shared.presentsTagEditor(first, at: .preview))
    XCTAssertFalse(afterIDs.contains("lab-preview-tag"))

    AppState.shared.navigator.select(item: second)
    pump(0.25)
    hostPanel.contentView?.layoutSubtreeIfNeeded()
    let switched = identifiers(in: hostPanel.contentView)
    XCTAssertEqual(AppState.shared.tagEditorItem?.id, first.id, "row editor must stay with the item that opened it")
    XCTAssertTrue(AppState.shared.presentsTagEditor(first, at: .row))
    XCTAssertFalse(AppState.shared.presentsTagEditor(second, at: .row))
    XCTAssertFalse(AppState.shared.presentsTagEditor(first, at: .preview))
    XCTAssertFalse(AppState.shared.presentsTagEditor(second, at: .preview))
    XCTAssertFalse(switched.contains("lab-preview-tag"), "preview must not grow an editor after the lead changes")
    XCTAssertFalse(hostPanel.isVisible)
    XCTAssertFalse(hostPanel.isKeyWindow)
    XCTAssertEqual(hostPanel.orderAttempts, 0)
    XCTAssertLessThan(hostPanel.frame.maxX, 0)
    XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontPID)
  }

  private func textItem(_ value: String) -> HistoryItemDecorator {
    let item = HistoryItem(contents: [
      HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data(value.utf8))
    ])
    item.title = value
    Storage.shared.context.insert(item)
    return History.shared.add(item)
  }

  private func makePanel() -> OffscreenTagPanel {
    let split = AppState.shared.preview.currentSplit
    let panel = OffscreenTagPanel(
      contentRect: NSRect(x: -24000, y: -24000, width: split.totalWidth, height: split.height),
      identifier: "lab-tag-click-probe",
      onClose: {}
    ) { ContentView() }
    panel.collectionBehavior = [.stationary, .ignoresCycle]
    panel.setFrame(NSRect(x: -24000, y: -24000, width: split.totalWidth, height: split.height), display: false)
    panel.isReleasedWhenClosed = false
    self.panel = panel
    return panel
  }

  private func identifiers(in root: NSView?) -> [String] {
    var found: [String] = []
    var seen = Set<ObjectIdentifier>()
    func walk(_ object: AnyObject?, depth: Int) {
      guard let object, depth < 40 else { return }
      let token = ObjectIdentifier(object)
      guard seen.insert(token).inserted else { return }
      if let view = object as? NSView {
        let id = view.accessibilityIdentifier()
        if !id.isEmpty { found.append(id) }
        view.subviews.forEach { walk($0, depth: depth + 1) }
        axChildren(view).forEach { walk($0, depth: depth + 1) }
        return
      }
      if let id = axString(object, "accessibilityIdentifier"), !id.isEmpty {
        found.append(id)
      }
      axChildren(object).forEach { walk($0, depth: depth + 1) }
    }
    walk(root, depth: 0)
    return found
  }

  private func axChildren(_ object: AnyObject) -> [AnyObject] {
    let sel = NSSelectorFromString("accessibilityChildren")
    guard let ns = object as? NSObject, ns.responds(to: sel) else { return [] }
    return (ns.perform(sel)?.takeUnretainedValue() as? [AnyObject]) ?? []
  }

  private func axString(_ object: AnyObject, _ name: String) -> String? {
    let sel = NSSelectorFromString(name)
    guard let ns = object as? NSObject, ns.responds(to: sel) else { return nil }
    return ns.perform(sel)?.takeUnretainedValue() as? String
  }

  private func pump(_ interval: TimeInterval) {
    let end = Date().addingTimeInterval(interval)
    while Date() < end {
      RunLoop.current.run(mode: .common, before: Date().addingTimeInterval(0.02))
    }
  }
}

