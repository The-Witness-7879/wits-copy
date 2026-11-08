import AppKit
import XCTest
@testable import WitsCopy

final class WorkspaceTagDirectoryTests: XCTestCase {
  private let kept = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

  func testEmptyTagStaysInCreationOrderAboveLaterNames() {
    XCTAssertEqual(WorkspaceTagDirectory.ordered(stored: ["zeta"], itemTags: []), ["zeta"])
    let saved = try? WorkspaceTagDirectory.inserting("alpha", into: ["zeta"], itemTags: []).get()
    XCTAssertEqual(saved, ["zeta", "alpha"] as [String]?)
    XCTAssertNotEqual(saved, ["alpha", "zeta"] as [String]?)
  }

  func testUnionKeepsCatalogOrderAndAdoptsItemTagsWithoutSorting() {
    XCTAssertEqual(
      WorkspaceTagDirectory.ordered(stored: ["zeta", "alpha"], itemTags: ["mid", "alpha", "zzz"]),
      ["zeta", "alpha", "mid", "zzz"]
    )
    XCTAssertEqual(
      WorkspaceTagDirectory.ordered(stored: ["Work"], itemTags: ["work"]),
      ["Work"]
    )
  }

  func testDeletingTheLastItemDoesNotDropTheDirectory() {
    XCTAssertEqual(WorkspaceTagDirectory.ordered(stored: ["keep"], itemTags: []), ["keep"])
  }

  func testCreateAdoptsExistingItemTagsThenAppendsTheNewName() {
    var saved: [String]?
    let result = WorkspaceTagDirectoryActions.apply(
      .commit("solo"),
      stored: [],
      itemTags: ["work"],
      save: {
        saved = $0
        return true
      }
    )
    XCTAssertEqual(try result.get(), ["work", "solo"])
    XCTAssertEqual(saved, ["work", "solo"])
  }

  func testCreateRejectsBlankSpaceAndOverlongNamesWithoutSaving() {
    var saves = 0
    let save: ([String]) -> Bool = { _ in
      saves += 1
      return true
    }
    XCTAssertEqual(
      WorkspaceTagDirectoryActions.apply(.commit("   "), stored: ["keep"], itemTags: [], save: save),
      .failure(.invalidName)
    )
    XCTAssertEqual(
      WorkspaceTagDirectoryActions.apply(.commit("two words"), stored: ["keep"], itemTags: [], save: save),
      .failure(.invalidName)
    )
    XCTAssertEqual(
      WorkspaceTagDirectoryActions.apply(
        .commit(String(repeating: "a", count: 33)),
        stored: ["keep"],
        itemTags: [],
        save: save
      ),
      .failure(.invalidName)
    )
    XCTAssertEqual(saves, 0)
  }

  func testCreateTrimsToTheNormalizedSpellingAndRejectsACaseDuplicate() {
    let trimmed = try? WorkspaceTagDirectory.inserting(" note ", into: [], itemTags: []).get()
    XCTAssertEqual(trimmed, ["note"] as [String]?)
    var saves = 0
    let duplicate = WorkspaceTagDirectoryActions.apply(
      .commit("Work"),
      stored: [],
      itemTags: ["work"],
      save: { _ in
        saves += 1
        return true
      }
    )
    XCTAssertEqual(duplicate, .failure(.duplicate))
    XCTAssertEqual(saves, 0)
  }

  func testCancelDoesNotSave() {
    let result = WorkspaceTagDirectoryActions.apply(
      .cancel,
      stored: ["keep"],
      itemTags: ["item"],
      save: { _ in
        XCTFail("cancel wrote the directory")
        return false
      }
    )
    XCTAssertEqual(try result.get(), ["keep"])
  }

  func testPersistFailureLeavesTheDirectoryUnchanged() {
    var stored = ["keep"]
    let result = WorkspaceTagDirectoryActions.apply(
      .commit("solo"),
      stored: stored,
      itemTags: [],
      save: { _ in false }
    )
    expectFailure(result, .persistFailed)
    XCTAssertEqual(stored, ["keep"])
    XCTAssertEqual(WorkspaceTagDirectoryError.persistFailed.messageKey, "tag_directory_persist_failed")
  }

  func testSyncDoesNotRewriteAnEmptyTagAfterItsItemsAreGone() {
    let writer = MemoryTagDirectoryWriter(names: ["solo"])
    let result = WorkspaceTagDirectoryActions.sync(itemTags: [], writer: writer)
    XCTAssertEqual(try result.get(), ["solo"])
    XCTAssertEqual(writer.saves, 0)
  }

  func testSyncReportsPersistFailure() {
    let writer = MemoryTagDirectoryWriter(names: [])
    writer.onSave = { _ in false }
    XCTAssertEqual(
      WorkspaceTagDirectoryActions.sync(itemTags: ["work"], writer: writer),
      .failure(.persistFailed)
    )
    XCTAssertEqual(writer.names, [])
    XCTAssertEqual(WorkspaceTagDirectory.ordered(stored: [], itemTags: ["work"]), ["work"])
  }

  func testRenameKeepsPositionAndRollsBackWhenTheDirectorySaveFails() {
    XCTAssertEqual(
      WorkspaceTagDirectory.renaming(["a", "b", "c"], from: "b", to: "bee"),
      ["a", "bee", "c"]
    )
    var history = ["old"]
    var rollbacks = 0
    let result = WorkspaceTagDirectoryActions.rename(
      from: "old",
      to: "fresh",
      itemTagsAfter: { ["fresh"] },
      renameHistory: {
        history = ["fresh"]
        return true
      },
      rollbackHistory: { restored in
        rollbacks += 1
        history = [restored]
        return true
      },
      writer: MemoryTagDirectoryWriter(names: ["old"], acceptSave: false)
    )
    expectFailure(result, .persistFailed)
    XCTAssertEqual(history, ["old"])
    XCTAssertEqual(rollbacks, 1)
  }

  func testDeleteRemovesTheNameBeforeHistoryAndRestoresItIfHistoryFails() {
    let writer = MemoryTagDirectoryWriter(names: ["keep", "gone"])
    let result = WorkspaceTagDirectoryActions.delete(
      named: "gone",
      itemTags: ["gone"],
      deleteHistory: { false },
      writer: writer
    )
    expectFailure(result, .historyFailed)
    XCTAssertEqual(writer.names, ["keep", "gone"])
  }

  func testDropRejectsExternalTextDeletedItemsAndDoesNotAppend() {
    let live = [WorkspaceItemDropLiveItem(id: kept, removed: false)]
    let encoded = WorkspaceItemDrag.encode(kept)
    XCTAssertNil(WorkspaceItemDrag.token(typeIdentifiers: ["public.utf8-plain-text"], data: encoded))
    XCTAssertNil(WorkspaceItemDrag.token(
      typeIdentifiers: [WorkspaceItemDrag.typeIdentifier],
      data: Data("not-a-uuid".utf8)
    ))
    XCTAssertEqual(
      WorkspaceItemDrag.token(typeIdentifiers: [WorkspaceItemDrag.typeIdentifier], data: encoded),
      kept
    )
    XCTAssertNil(WorkspaceItemDrag.acceptedItemID(
      typeIdentifiers: [WorkspaceItemDrag.typeIdentifier],
      data: encoded,
      sourceInProcess: false,
      live: live
    ))
    XCTAssertNil(WorkspaceItemDrag.acceptedItemID(
      typeIdentifiers: [WorkspaceItemDrag.typeIdentifier],
      data: encoded,
      sourceInProcess: true,
      live: [WorkspaceItemDropLiveItem(id: kept, removed: true)]
    ))
    XCTAssertNil(WorkspaceItemDrag.acceptedItemID(
      typeIdentifiers: [WorkspaceItemDrag.typeIdentifier],
      data: encoded,
      sourceInProcess: true,
      live: []
    ))
    XCTAssertEqual(
      WorkspaceItemDrag.acceptedItemID(
        typeIdentifiers: [WorkspaceItemDrag.typeIdentifier],
        data: encoded,
        sourceInProcess: true,
        live: live
      ),
      kept
    )

    XCTAssertFalse(WorkspaceItemDrag.sourceOperation(withinApplication: true).contains(.move))
    XCTAssertEqual(WorkspaceItemDrag.sourceOperation(withinApplication: false), [])
  }

  func testLargerHitFitsTheExistingRailWithoutShrinkingListContent() {
    XCTAssertEqual(PanelSplit.navigationRailWidth, 36)
    XCTAssertEqual(WorkspaceRailMetrics.hit, 35)
    XCTAssertGreaterThanOrEqual(WorkspaceRailMetrics.hit / WorkspaceRailMetrics.baselineHit, 1.25)
    XCTAssertLessThanOrEqual(WorkspaceRailMetrics.hit / WorkspaceRailMetrics.baselineHit, 1.5)
    XCTAssertEqual(400 - PanelSplit.navigationRailWidth, 364)
  }

  /// 输入的是已有分类名时，确认它的意思就是「去那个分类」，不是报重复。
  func testConfirmingAnExistingNameResolvesToThatCategory() {
    XCTAssertEqual(
      WorkspaceTagDirectory.resolveCreate("  123  ", in: ["123", "work"]),
      .selectExisting("123")
    )
    XCTAssertEqual(
      WorkspaceTagDirectory.resolveCreate("WORK", in: ["123", "work"]),
      .selectExisting("work")
    )
    XCTAssertEqual(WorkspaceTagDirectory.resolveCreate("fresh", in: ["123"]), .create("fresh"))
    XCTAssertEqual(WorkspaceTagDirectory.resolveCreate("bad name", in: []), .invalid)
    XCTAssertEqual(WorkspaceTagDirectory.resolveCreate("   ", in: ["123"]), .invalid)
  }

  /// 表单只做「新建」：按钮等宽、与输入框同宽、没有已建分类列表，也没有多余留白。
  func testCreateFormHasNoCategoryListAndSymmetricButtons() throws {
    let size = WorkspaceTagCreatePlacement.formSize(showsError: false)
    let form = WorkspaceTagCreateFormView(frame: NSRect(origin: .zero, size: size))
    form.layoutSubtreeIfNeeded()

    func child(_ id: String) throws -> NSView { try XCTUnwrap(form.subviews.first { $0.accessibilityIdentifier() == id }) }

    let field = try child("lab-rail-new-tag-field")
    let create = try XCTUnwrap(child("lab-rail-new-tag-create") as? NSButton)
    let cancel = try XCTUnwrap(child("lab-rail-new-tag-cancel") as? NSButton)
    let inset = WorkspaceTagCreatePlacement.contentInset

    XCTAssertEqual(field.frame.minX, inset, accuracy: 0.01)
    XCTAssertEqual(field.frame.maxX, size.width - inset, accuracy: 0.01)
    XCTAssertEqual(cancel.frame.minX, inset, accuracy: 0.01)
    XCTAssertEqual(create.frame.maxX, size.width - inset, accuracy: 0.01)
    XCTAssertEqual(create.frame.width, cancel.frame.width, accuracy: 0.01)
    XCTAssertEqual(create.frame.maxY, cancel.frame.maxY, accuracy: 0.01)
    XCTAssertEqual(
      create.frame.minX - cancel.frame.maxX,
      WorkspaceTagCreatePlacement.buttonGap,
      accuracy: 0.01
    )
    XCTAssertEqual(create.frame.maxY + inset, size.height, accuracy: 0.01)
    XCTAssertEqual(cancel.keyEquivalent, "\u{1b}")
    XCTAssertEqual(create.keyEquivalent, "\r")

    XCTAssertFalse(
      form.subviews.contains { ($0.accessibilityIdentifier() ?? "").hasPrefix("lab-rail-new-tag-row-") },
      "a create form must not list the categories that already exist"
    )

    // 空名时主按钮不该可点；有名字才可创建。
    XCTAssertFalse(create.isEnabled)
    form.field.stringValue = "fresh"
    form.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: form.field))
    XCTAssertTrue(create.isEnabled)

    form.show("taken")
    form.layoutSubtreeIfNeeded()
    XCTAssertEqual(form.preferredSize.height, WorkspaceTagCreatePlacement.formSize(showsError: true).height)
    let error = try child("lab-rail-new-tag-error")
    XCTAssertEqual(error.frame.height, WorkspaceTagCreatePlacement.errorHeight, accuracy: 0.01)
    XCTAssertEqual(
      error.frame.minY - create.frame.maxY,
      WorkspaceTagCreatePlacement.errorGap,
      accuracy: 0.01
    )
  }

  @MainActor
  func testEmbeddedTagFormIsAContentSubviewNotAChildWindow() {
    let window = NSWindow(
      contentRect: NSRect(x: -24000, y: -24000, width: 1020, height: 640),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 1020, height: 640))
    window.isReleasedWhenClosed = false
    window.setFrame(NSRect(x: -24000, y: -24000, width: 1020, height: 640), display: false)
    window.contentView = content
    let anchor = NSView(frame: NSRect(x: 1, y: 40, width: 35, height: 35))
    content.addSubview(anchor)
    let controller = WorkspaceTagCreateController()
    controller.present(
      from: anchor,
      onCommit: { _ in nil },
      onCancel: {}
    )
    XCTAssertNil(
      content.subviews.first { $0.accessibilityIdentifier() == "lab-rail-new-tag-form" },
      "tag form was embedded in the content view instead of the popover"
    )
    controller.dismiss(cancelled: true)
    XCTAssertFalse(controller.isPresented)
    window.close()
  }

  func testReadBackMismatchRestoresThePreviousDirectory() {
    let name = "local.thewitness.WitsCopy.tag-directory-mismatch"
    let defaults = UserDefaults(suiteName: name)!
    defer { TestDefaults.discard(name) }
    let writer = MismatchTagDirectoryWriter(defaults: defaults, key: WorkspaceTagDirectoryPersistence.keyName)
    XCTAssertTrue(writer.saveNames(["keep"]))
    XCTAssertFalse(writer.saveNames(["next"]))
    XCTAssertEqual(writer.loadNames(), ["keep"])
  }

  func testTooltipsAndNewTagFormAreExplicit() throws {
    XCTAssertEqual(
      WorkspaceTagCopy.english["tag_directory_add_help"],
      "New tag"
    )
    XCTAssertEqual(
      WorkspaceTagCopy.chinese["tag_directory_add_help"],
      "新建标签"
    )
    XCTAssertEqual(
      WorkspaceTagCopy.english["tag_directory_cancel_help"],
      "Cancel"
    )
    XCTAssertFalse(WorkspaceTagCopy.text("tag_directory_add_help").isEmpty)
    XCTAssertNotEqual(WorkspaceTagCopy.text("tag_directory_create_help"), "tag_directory_create_help")

    let rail = try labSource("WitsCopy/WorkspaceManagementView.swift")
    XCTAssertTrue(rail.contains("lab-rail-add-tag"))
    XCTAssertTrue(rail.contains("lab-options-button"))
    XCTAssertTrue(rail.contains("accessibilityIdentifier(for:"))
    XCTAssertFalse(rail.contains("popover(isPresented: $creatingTag"))
    XCTAssertFalse(rail.contains("NSPopover"))
    let form = try labSource("WitsCopy/WorkspaceTagRail.swift")
    XCTAssertFalse(form.contains("addChildWindow"))
    XCTAssertTrue(form.contains("popover?.contentSize"))
    XCTAssertTrue(form.contains("contentView"))
    XCTAssertTrue(form.contains("lab-rail-new-tag-form"))
    XCTAssertTrue(form.contains("tag_directory_create_help"))
    XCTAssertTrue(form.contains("tag_directory_cancel_help"))
    XCTAssertTrue(form.contains("WorkspaceItemDrag.draggingImage"))
  }

  func testGhostUsesTheSuggestedNativeSize() {
    let image = WorkspaceItemDrag.draggingImage(title: "合成标题")
    XCTAssertEqual(image.size, WorkspaceItemDrag.suggestedGhostSize)
  }

  private func labSource(_ relative: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(contentsOf: root.appending(path: relative), encoding: .utf8)
  }
}

private final class MemoryTagDirectoryWriter: WorkspaceTagDirectoryWriting {
  var names: [String]
  var saves = 0
  var acceptSave: Bool
  var onSave: (([String]) -> Bool)?

  init(names: [String], acceptSave: Bool = true) {
    self.names = names
    self.acceptSave = acceptSave
  }

  func loadNames() -> [String] { names }

  func saveNames(_ names: [String]) -> Bool {
    saves += 1
    if let onSave { return onSave(names) }
    guard acceptSave else { return false }
    self.names = names
    return true
  }
}

private struct MismatchTagDirectoryWriter: WorkspaceTagDirectoryWriting {
  var defaults: UserDefaults
  var key: String

  func loadNames() -> [String] {
    WorkspaceTagDirectory.ordered(stored: defaults.stringArray(forKey: key) ?? [], itemTags: [])
  }

  func saveNames(_ names: [String]) -> Bool {
    let previous = defaults.stringArray(forKey: key)
    if previous == ["keep"] && names == ["next"] {
      defaults.set(["tampered"], forKey: key)
      let matched = defaults.stringArray(forKey: key) == names
      if !matched, let previous {
        defaults.set(previous, forKey: key)
      }
      return matched
    }
    defaults.set(names, forKey: key)
    return defaults.stringArray(forKey: key) == names
  }
}

private func expectFailure<Success>(
  _ result: Result<Success, WorkspaceTagDirectoryError>,
  _ error: WorkspaceTagDirectoryError,
  file: StaticString = #filePath,
  line: UInt = #line
) {
  switch result {
  case .success:
    XCTFail("expected \(error)", file: file, line: line)
  case .failure(let actual):
    XCTAssertEqual(actual, error, file: file, line: line)
  }
}
