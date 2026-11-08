import AppKit
import Defaults
import SwiftData
import SwiftUI
import XCTest
@testable import WitsCopy

/// Offscreen regressions for a selected pin replaced by dedup, and for pin-details
/// resignKey. Does not order, activate, or read a deleted model.
@MainActor
final class PinContinuityTests: XCTestCase {
  private let history = History.shared
  private var savedSize = 0
  private var savedSortBy = Defaults[.sortBy]
  private var savedPinTo = Defaults[.pinTo]
  private var savedWindowPinned = false
  private var savedRail = true
  private var savedSection = WorkspaceSection.all
  private var savedPreview = SlideoutState.open
  private var probe: OffscreenPinPanel?
  private var resignPanel: QuietFloatingPanel?

  override func setUp() {
    super.setUp()
    savedSize = Defaults[.size]
    savedSortBy = Defaults[.sortBy]
    savedPinTo = Defaults[.pinTo]
    savedWindowPinned = AppState.shared.windowPinned
    savedRail = AppState.shared.managementRailVisible
    savedSection = AppState.shared.workspaceSection
    savedPreview = AppState.shared.preview.state
    history.clearAll()
    Defaults[.size] = 20
    Defaults[.sortBy] = .firstCopiedAt
    Defaults[.pinTo] = .bottom
    AppState.shared.windowPinned = false
    AppState.shared.workspaceSection = .all
    AppState.shared.panelPresented = false
    AppState.shared.managementRailVisible = true
    AppState.shared.preview.state = .open
    AppState.shared.storageError = nil
    Storage.shared.saveImplementation = nil
    AppState.shared.clearTagEditor()
    AppState.shared.endPinRecordingSession()
    AppState.shared.discardAllTextDrafts()
    AppState.shared.navigator.select(item: nil)
    history.searchQuery = ""
    history.tagFilter = nil
    history.typeFilter = nil
    Clipboard.shared.copyProbe = nil
  }

  override func tearDown() {
    probe?.close()
    probe = nil
    resignPanel?.close()
    resignPanel = nil
    suppressOnscreenWindows()
    AppState.shared.panelPresented = false
    AppState.shared.navigator.select(item: nil)
    AppState.shared.clearTagEditor()
    AppState.shared.endPinRecordingSession()
    AppState.shared.discardAllTextDrafts()
    AppState.shared.storageError = nil
    Storage.shared.saveImplementation = nil
    history.searchQuery = ""
    history.tagFilter = nil
    history.typeFilter = nil
    history.clearAll()
    Defaults[.size] = savedSize
    Defaults[.sortBy] = savedSortBy
    Defaults[.pinTo] = savedPinTo
    AppState.shared.windowPinned = savedWindowPinned
    AppState.shared.managementRailVisible = savedRail
    AppState.shared.workspaceSection = savedSection
    AppState.shared.preview.state = savedPreview
    Clipboard.shared.copyProbe = nil
    super.tearDown()
  }

  func testLetterPinDedupKeepsSelectedAliasAndPin() throws {
    try assertDedupKeepsLead(pin: "s", image: false, alias: "alias-letter")
  }

  func testEmptyPinStringDedupKeepsSelectedAlias() throws {
    try assertDedupKeepsLead(pin: "", image: false, alias: "alias-empty")
  }

  func testImageAliasDedupKeepsSelectedPin() throws {
    try assertDedupKeepsLead(pin: "s", image: true, alias: "alias-image")
  }

  func testScenePhaseActiveAfterDedupDoesNotFallBackToUnpinned() throws {
    let front = frontPID
    let loose = history.add(textItem("loose-row"))
    let mounted = try mountPinned(pin: "s", image: false, alias: "scene-alias")
    AppState.shared.navigator.select(item: mounted.original)
    let flags = ModifierFlags()
    let driver = PhaseDriver()
    let host = NSHostingView(rootView: PhaseHost(driver: driver, flags: flags)
      .environment(AppState.shared)
      .environment(flags)
      .modelContainer(Storage.shared.container))
    host.sizingOptions = []
    let panel = makeProbe(size: NSSize(width: 320, height: 180))
    panel.contentView = host
    drain(0.15)
    XCTAssertFalse(panel.isVisible)
    XCTAssertFalse(panel.isKeyWindow)

    let survivor = history.add(duplicate(of: mounted.original, image: false))
    drain(0.15)
    driver.phase = .active
    drain(0.2)

    let lead = AppState.shared.navigator.leadHistoryItem
    XCTAssertEqual(
      lead?.id,
      survivor.id,
      "scenePhase.active selected \(lead?.title ?? "nil") instead of the pinned survivor; loose was \(loose.title)"
    )
    XCTAssertNotEqual(lead?.id, loose.id, "reopen fell back to the unpinned row")
    XCTAssertEqual(survivor.item.pin, "s")
    XCTAssertEqual(survivor.item.title, "scene-alias")
    XCTAssertTrue(mounted.original.isRemoved)
    XCTAssertFalse(panel.isVisible)
    XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, front)
  }

  func testRemovedDetailsPopoverIsNotAResignKeyException() throws {
    let front = frontPID
    let mounted = try mountPinned(pin: "s", image: false, alias: "resign-alias")
    AppState.shared.navigator.select(item: mounted.original)
    AppState.shared.panelPresented = true
    AppState.shared.windowPinned = false
    XCTAssertNil(button(id: "lab-pin-details", in: mounted.host), "old pin details button is still installed")
    AppState.shared.beginPinRecording(itemID: mounted.original.id)
    XCTAssertEqual(
      PanelClosePolicy.decide(.resignKey, context: AppState.shared.focusContext),
      .close,
      "shortcut recording must not keep the panel open the way the details popover did"
    )
    let panel = makeResignPanel()
    panel.resignKey()
    XCTAssertFalse(AppState.shared.panelPresented)
    XCTAssertNil(AppState.shared.pinRecordingItemID)
    XCTAssertEqual(mounted.original.item.pin, "s")
    XCTAssertFalse(panel.isVisible)
    XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, front)
  }

  func testUnselectedDedupDoesNotMoveLead() throws {
    let keep = history.add(textItem("keep-lead"))
    AppState.shared.navigator.select(item: keep)
    let other = textItem("other-body")
    other.pin = "o"
    other.title = "other-alias"
    let original = history.add(other)
    let survivor = history.add(textItem("other-body"))
    drain(0.05)
    XCTAssertEqual(AppState.shared.navigator.leadHistoryItem?.id, keep.id)
    XCTAssertNotEqual(survivor.id, original.id)
    XCTAssertEqual(survivor.item.pin, "o")
    XCTAssertEqual(survivor.item.title, "other-alias")
    XCTAssertTrue(original.isRemoved)
  }

  func testExplicitUnpinAndRefreshDoNotInventAPin() throws {
    let mounted = try mountPinned(pin: "s", image: false, alias: "refresh-alias")
    AppState.shared.navigator.select(item: mounted.original)
    history.refreshVisibleItems(highlightFirst: false)
    drain(0.05)
    XCTAssertEqual(AppState.shared.navigator.leadHistoryItem?.id, mounted.original.id)
    XCTAssertEqual(mounted.original.item.pin, "s")
    XCTAssertEqual(mounted.original.item.title, "refresh-alias")

    history.togglePin(mounted.original)
    drain(0.1)
    XCTAssertNil(mounted.original.item.pin, "explicit unpin must be a real nil")
    XCTAssertEqual(AppState.shared.navigator.leadHistoryItem?.id, mounted.original.id)
    XCTAssertFalse(mounted.original.isRemoved)
  }

  func testDeleteAndClearWithMountedEditorDoNotReadRemovedModels() throws {
    let loose = history.add(textItem("delete-loose"))
    let mounted = try mountPinned(pin: "s", image: false, alias: "delete-alias")
    AppState.shared.navigator.select(item: mounted.original)
    let alias = try XCTUnwrap(mounted.field).string
    AppState.shared.deleteItem(mounted.original)
    drain(0.2)
    XCTAssertTrue(mounted.original.isRemoved)
    XCTAssertNotEqual(AppState.shared.navigator.leadHistoryItem?.id, mounted.original.id)
    XCTAssertEqual(AppState.shared.navigator.leadHistoryItem?.id, loose.id)
    XCTAssertEqual(try XCTUnwrap(mounted.field).string, alias, "deleted-model binding blanked the mounted alias")

    let pinned = try mountPinned(pin: "", image: false, alias: "clear-alias")
    history.clear()
    drain(0.1)
    XCTAssertFalse(pinned.original.isRemoved, "clear must keep a pin, including an empty shortcut")
    XCTAssertEqual(pinned.original.item.pin, "")

    let shown = try XCTUnwrap(pinned.field).string
    XCTAssertEqual(shown, "body-clear-alias", "mounted editor shows the body, not the stored title")
    history.clearAll()
    drain(0.2)
    XCTAssertTrue(pinned.original.isRemoved)
    XCTAssertEqual(
      try XCTUnwrap(pinned.field).string,
      shown,
      "clearAll binding read or blanked the mounted body"
    )
  }

  func testPinRecordingEndsWithItsHostAndDoesNotClearANewerSession() {
    let first = history.add(textItem("first-details"))
    let second = history.add(textItem("second-details"))
    first.item.pin = "s"
    second.item.pin = "t"
    AppState.shared.navigator.select(item: first)
    AppState.shared.panelPresented = true
    AppState.shared.beginPinRecording(itemID: first.id)
    AppState.shared.panelPresented = false
    XCTAssertNil(AppState.shared.pinRecordingItemID, "hidden panel retained shortcut recording")

    AppState.shared.panelPresented = true
    AppState.shared.beginPinRecording(itemID: first.id)
    AppState.shared.notePreviewClosed()
    XCTAssertNil(AppState.shared.pinRecordingItemID, "closed preview retained shortcut recording")

    AppState.shared.beginPinRecording(itemID: first.id)
    AppState.shared.navigator.select(item: second)
    XCTAssertNil(AppState.shared.pinRecordingItemID, "another lead retained the previous recording")

    AppState.shared.beginPinRecording(itemID: second.id)
    AppState.shared.cancelPinRecording(itemID: first.id)
    XCTAssertEqual(AppState.shared.pinRecordingItemID, second.id, "late old-host cancel cleared the new recording")
    AppState.shared.cancelPinRecording(itemID: second.id)
    XCTAssertNil(AppState.shared.pinRecordingItemID)
    XCTAssertEqual(first.item.pin, "s")
    XCTAssertEqual(second.item.pin, "t")
  }

  func testPinLetterSaveFailureRestoresTheOldPin() {
    let item = history.add(textItem("save-fail"))
    item.item.pin = "s"
    AppState.shared.storageError = "stale"
    AppState.shared.beginPinRecording(itemID: item.id)
    Storage.shared.saveImplementation = { throw CocoaError(.fileWriteUnknown) }
    let result = AppState.shared.commitPinLetter("l", itemID: item.id)
    XCTAssertEqual(result, .failed(CocoaError(.fileWriteUnknown).localizedDescription))
    XCTAssertEqual(item.item.pin, "s", "failed shortcut save kept the new letter")
    XCTAssertEqual(AppState.shared.pinShortcutError(for: item.id), CocoaError(.fileWriteUnknown).localizedDescription)
    XCTAssertNotEqual(AppState.shared.storageError, "stale")

    Storage.shared.saveImplementation = nil
    AppState.shared.beginPinRecording(itemID: item.id)
    XCTAssertEqual(AppState.shared.commitPinLetter("l", itemID: item.id), .saved)
    XCTAssertEqual(item.item.pin, "l")
    XCTAssertNil(AppState.shared.storageError, "successful save left the previous error in place")
    XCTAssertNil(AppState.shared.pinShortcutError(for: item.id))
  }

  func testLoadAndSearchKeepTheDedupedPin() async throws {
    let mounted = try mountPinned(pin: "s", image: false, alias: "load-alias")
    AppState.shared.navigator.select(item: mounted.original)
    let survivor = history.add(duplicate(of: mounted.original, image: false))
    drain(0.1)
    XCTAssertEqual(AppState.shared.navigator.leadHistoryItem?.id, survivor.id)

    try await history.load()
    drain(0.1)
    let afterLoad = try XCTUnwrap(AppState.shared.navigator.leadHistoryItem)
    XCTAssertFalse(afterLoad.isRemoved)
    XCTAssertEqual(afterLoad.item.pin, "s")
    XCTAssertEqual(afterLoad.item.title, "load-alias")
    XCTAssertTrue(history.items.contains { $0.id == afterLoad.id })

    history.searchQuery = "load-alias"
    drain(0.45)
    XCTAssertEqual(AppState.shared.navigator.leadHistoryItem?.item.pin, "s")
    XCTAssertTrue(history.items.contains { $0.item.title == "load-alias" && $0.item.pin == "s" })

    history.searchQuery = "no-such-row"
    drain(0.45)
    XCTAssertNotEqual(AppState.shared.navigator.leadHistoryItem?.id, mounted.original.id)
    XCTAssertFalse(AppState.shared.navigator.leadHistoryItem?.isRemoved == true)
  }

  // MARK: - Path

  private struct Mounted {
    var original: HistoryItemDecorator
    var host: NSView
    /// Only plain-text rows expose the live body editor; images stay read-only.
    var field: OriginalTextBodyView?
  }

  private func assertDedupKeepsLead(pin: String, image: Bool, alias: String) throws {
    let front = frontPID
    let loose = history.add(textItem("loose-\(alias)"))
    let mounted = try mountPinned(pin: pin, image: image, alias: "before-\(alias)")
    AppState.shared.navigator.select(item: mounted.original)
    AppState.shared.panelPresented = true
    let initial = "before-\(alias)"
    let expectedTitle: String
    if image {
      XCTAssertNil(mounted.field, "an image row exposed an editable title")
      expectedTitle = initial
    } else {
      XCTAssertNil(findIdentifier("lab-preview-title", in: mounted.host))
      XCTAssertEqual(mounted.original.item.title, initial, "stored title changed before dedup")
      expectedTitle = initial
    }
    try Storage.shared.save()
    let pinBefore = mounted.original.item.pin
    XCTAssertEqual(pinBefore, pin, "alias edit cleared pin before dedup")
    let shown = image ? expectedTitle : "body-\(initial)"

    let survivor = history.add(duplicate(of: mounted.original, image: image))
    drain(0.2)

    XCTAssertTrue(mounted.original.isRemoved)
    XCTAssertNotEqual(survivor.id, mounted.original.id)
    XCTAssertEqual(survivor.item.pin, pin, "dedup wrote pin nil")
    XCTAssertEqual(survivor.item.title, expectedTitle)
    XCTAssertEqual(
      AppState.shared.navigator.leadHistoryItem?.id,
      survivor.id,
      "lead stayed on the removed decorator \(mounted.original.id); reopen would select unpinned \(loose.title) and collapse pin chrome"
    )
    XCTAssertEqual(AppState.shared.navigator.leadHistoryItem?.title, expectedTitle)
    XCTAssertEqual(AppState.shared.navigator.leadHistoryItem?.item.pin, pin)
    XCTAssertNotEqual(AppState.shared.navigator.leadHistoryItem?.id, loose.id)

    let liveEmpty = mounted.host.accessibilityIdentifier() == "lab-preview-empty"
      || findIdentifier("lab-preview-empty", in: mounted.host) != nil
    XCTAssertFalse(liveEmpty, "lead-following pin chrome collapsed while survivor pin is \(pin)")
    if let field = mounted.field {
      XCTAssertEqual(field.string, shown, "mounted editor blanked the alias after dedup")
    }

    AppState.shared.selectOnPanelOpen()
    XCTAssertEqual(AppState.shared.navigator.leadHistoryItem?.id, survivor.id)
    XCTAssertNotEqual(AppState.shared.navigator.leadHistoryItem?.id, loose.id)
    XCTAssertFalse(probe?.isVisible ?? false)
    XCTAssertFalse(probe?.isKeyWindow ?? false)
    XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, front)
  }

  private func mountPinned(pin: String, image: Bool, alias: String) throws -> Mounted {
    let item = image ? imageItem(alias) : textItem("body-\(alias)")
    item.pin = pin
    item.title = alias
    let original = history.add(item)
    original.title = alias
    let root = PinEditorHost(item: original)
      .environment(AppState.shared)
      .modelContainer(Storage.shared.container)
      .frame(width: 280, height: 200)
    let panel = makeProbe(size: NSSize(width: 280, height: 200))
    let host = NSHostingView(rootView: root)
    host.sizingOptions = []
    panel.contentView = host
    var field: OriginalTextBodyView?
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
      drain(0.04)
      host.layoutSubtreeIfNeeded()
      field = bodyEditor(in: host)
      if button(id: "lab-preview-delete", in: host) != nil, image || field != nil { break }
    }
    if !image {
      let body = try XCTUnwrap(field)
      XCTAssertEqual(body.string, "body-\(alias)", "the live body editor did not load the text")
      XCTAssertEqual(original.item.title, alias, "mounting the body editor changed the stored title")
      XCTAssertNil(findIdentifier("lab-preview-title", in: host))
      XCTAssertFalse(body.isEditable)
    }
    XCTAssertNotNil(button(id: "lab-preview-delete", in: host), "preview delete was not installed")
    XCTAssertNil(button(id: "lab-preview-pin", in: host), "preview pin action must stay on the row")
    XCTAssertFalse(panel.isVisible)
    XCTAssertFalse(panel.isKeyWindow)
    XCTAssertLessThan(panel.frame.maxX, 0)
    return Mounted(original: original, host: host, field: field)
  }

  private func bodyEditor(in root: NSView) -> OriginalTextBodyView? {
    if let view = findIdentifier("lab-preview-edit-body", in: root) as? OriginalTextBodyView { return view }
    return nil
  }

  private func duplicate(of original: HistoryItemDecorator, image: Bool) -> HistoryItem {
    if image {
      let copy = imageItem("incoming")
      copy.contents = original.item.contents.map {
        HistoryItemContent(type: $0.type, value: $0.value)
      }
      copy.title = "incoming"
      return copy
    }
    let copy = textItem(original.item.text ?? "body")
    copy.title = "incoming"
    return copy
  }

  private func textItem(_ value: String) -> HistoryItem {
    let item = HistoryItem(contents: [
      HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data(value.utf8))
    ])
    item.title = value
    Storage.shared.context.insert(item)
    return item
  }

  private func imageItem(_ title: String) -> HistoryItem {
    let data = LabSmokeCanvas.png(pixels: NSSize(width: 16, height: 16)) ?? Data([0x89, 0x50, 0x4E, 0x47])
    let item = HistoryItem(contents: [
      HistoryItemContent(type: NSPasteboard.PasteboardType.png.rawValue, value: data)
    ])
    item.title = title
    item.application = "com.apple.Preview"
    Storage.shared.context.insert(item)
    return item
  }

  private var frontPID: pid_t {
    NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
  }

  private func makeProbe(size: NSSize) -> OffscreenPinPanel {
    let panel = OffscreenPinPanel(
      contentRect: NSRect(x: -24000, y: -24000, width: size.width, height: size.height),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isReleasedWhenClosed = false
    panel.level = .normal
    panel.collectionBehavior = [.stationary, .ignoresCycle]
    probe?.close()
    probe = panel
    return panel
  }

  private func makeResignPanel() -> QuietFloatingPanel {
    let panel = QuietFloatingPanel(
      contentRect: NSRect(x: -24000, y: -24000, width: 80, height: 40),
      onClose: {},
      view: { QuietDot() }
    )
    panel.isReleasedWhenClosed = false
    panel.setFrame(NSRect(x: -24000, y: -24000, width: 80, height: 40), display: false)
    XCTAssertFalse(panel.isVisible, "resign probe became visible")
    XCTAssertLessThan(panel.frame.maxX, 0)
    resignPanel = panel
    return panel
  }

  @discardableResult
  private func suppressOnscreenWindows() -> Int {
    var closed = 0
    for window in NSApp.windows where window.isVisible && window.frame.maxX >= 0 {
      window.orderOut(nil)
      closed += 1
    }
    return closed
  }

  private func drain(_ interval: TimeInterval) {
    let end = Date().addingTimeInterval(interval)
    while Date() < end {
      RunLoop.current.run(mode: .common, before: Date().addingTimeInterval(0.01))
    }
  }

  private func button(id: String, in root: NSView?) -> ImmediateActionButton? {
    guard let root else { return nil }
    if let button = root as? ImmediateActionButton, button.accessibilityIdentifier() == id {
      return button
    }
    for subview in root.subviews {
      if let found = button(id: id, in: subview) { return found }
    }
    return nil
  }

  private func findIdentifier(_ id: String, in root: NSView) -> NSView? {
    if root.accessibilityIdentifier() == id { return root }
    for subview in root.subviews {
      if let found = findIdentifier(id, in: subview) { return found }
    }
    return nil
  }
}

private final class OffscreenPinPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  override func makeMain() {}
  override func makeKeyAndOrderFront(_ sender: Any?) {}
  override func orderFront(_ sender: Any?) {}
  override func orderFrontRegardless() {}
  override func orderBack(_ sender: Any?) {}
  override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {}
}

private struct QuietDot: View {
  var body: some View { Color.clear.frame(width: 4, height: 4) }
}

private final class QuietFloatingPanel: FloatingPanel<QuietDot> {
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

@Observable
private final class PhaseDriver {
  var phase: ScenePhase = .background
  var query = ""
}

private struct PhaseHost: View {
  @Bindable var driver: PhaseDriver
  var flags: ModifierFlags
  @FocusState private var searchFocused: Bool

  var body: some View {
    HistoryListView(searchQuery: $driver.query, searchFocused: $searchFocused)
      .environment(\.scenePhase, driver.phase)
      .environment(AppState.shared)
      .environment(flags)
  }
}

private struct PinEditorHost: View {
  var item: HistoryItemDecorator

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      LeadPinChrome()
      // Residue: the editor that was already mounted stays after the model is replaced.
      PreviewCornerActions(item: item)
      // The real live editor: title plus original text, saved explicitly.
      OriginalTextEditSection(item: item)
    }
    .padding(8)
    .environment(AppState.shared)
  }
}

private struct LeadPinChrome: View {
  @Environment(AppState.self) private var appState

  var body: some View {
    if let item = appState.navigator.leadHistoryItem, !item.isRemoved {
      PreviewCornerActions(item: item)
        .id(item.id)
        .accessibilityIdentifier("lab-live-pin-chrome")
    } else {
      Text("preview_empty")
        .accessibilityIdentifier("lab-preview-empty")
    }
  }
}
