import AppKit
import SwiftUI
import XCTest
@testable import WitsCopy

/// Offscreen lifecycle of the local pin-recording monitor. These tests do not
/// call `PinRecordingKeyRoute.end` to produce the result, do not activate the
/// app, and do not order a window on screen. Tear-down may end a leftover route.
@MainActor
final class PinRecordingLifecycleTests: XCTestCase {
  private let history = History.shared
  private var panels: [NSPanel] = []
  private var watch: Any?
  private var watched: [String] = []
  private var previousMenu: NSMenu?
  private var probe = KeyRouteProbe()
  private var savedPresented = false
  private var savedPreview = SlideoutState.open
  private var front: pid_t = 0
  private var wasActive = false

  override func setUp() {
    super.setUp()
    front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    wasActive = NSApp.isActive
    savedPresented = AppState.shared.panelPresented
    savedPreview = AppState.shared.preview.state
    history.clearAll()
    AppState.shared.navigator.select(item: nil)
    AppState.shared.panelPresented = false
    AppState.shared.preview.state = .open
    AppState.shared.preview.notifiesPreviewClose = true
    AppState.shared.endPinRecordingSession()
    PinRecordingKeyRoute.end(nil)
    previousMenu = NSApp.mainMenu
    probe = KeyRouteProbe()
    NSApp.mainMenu = probe.menu
    watched = []
    watch = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      self?.watched.append(event.charactersIgnoringModifiers ?? "")
      return event
    }
  }

  override func tearDown() {
    if let watch {
      NSEvent.removeMonitor(watch)
    }
    watch = nil
    NSApp.mainMenu = previousMenu
    for panel in panels {
      panel.orderOut(nil)
      panel.close()
    }
    panels.removeAll()
    AppState.shared.navigator.select(item: nil)
    AppState.shared.panelPresented = false
    AppState.shared.endPinRecordingSession()
    PinRecordingKeyRoute.end(nil)
    AppState.shared.panelPresented = savedPresented
    AppState.shared.preview.state = savedPreview
    history.clearAll()
    XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0, front)
    XCTAssertEqual(NSApp.isActive, wasActive)
    super.tearDown()
  }

  func testClosingTheWindowReleasesTheRecordingMonitor() throws {
    let panel = makePanel()
    let recorder = installRecorder(in: panel, itemID: UUID())
    AppState.shared.panelPresented = true
    XCTAssertTrue(recorder.accessibilityPerformPress())
    XCTAssertTrue(PinRecordingKeyRoute.isInstalled)
    XCTAssertTrue(recorder.recording)
    XCTAssertFalse(panel.isVisible)
    XCTAssertLessThan(panel.frame.maxX, 0)

    panel.close()

    XCTAssertNil(AppState.shared.pinRecordingItemID)
    XCTAssertFalse(recorder.recording, "closed window left the recorder swallowing")
    XCTAssertFalse(recorder.ownsSession)
    XCTAssertFalse(PinRecordingKeyRoute.isInstalled, "closed window left the local monitor installed")
    try assertKeysReachTheApp()
    assertQuiet(panel)
  }

  func testSwitchingTheLeadReleasesTheRecordingMonitor() throws {
    let first = history.add(textItem("lead-a"))
    let second = history.add(textItem("lead-b"))
    let panel = makePanel()
    let recorder = installRecorder(in: panel, itemID: first.id)
    AppState.shared.navigator.select(item: first)
    AppState.shared.panelPresented = true
    XCTAssertTrue(recorder.accessibilityPerformPress())
    XCTAssertEqual(AppState.shared.pinRecordingItemID, first.id)
    XCTAssertTrue(PinRecordingKeyRoute.isInstalled)

    AppState.shared.navigator.select(item: second)

    XCTAssertNil(AppState.shared.pinRecordingItemID)
    XCTAssertFalse(recorder.recording)
    XCTAssertFalse(PinRecordingKeyRoute.isInstalled, "switching items left the local monitor installed")
    try assertKeysReachTheApp()
    assertQuiet(panel)
  }

  func testDeletingTheRecordedItemReleasesTheMonitor() throws {
    let item = history.add(textItem("delete-rec"))
    let panel = makePanel()
    let recorder = installRecorder(in: panel, itemID: item.id)
    AppState.shared.panelPresented = true
    XCTAssertTrue(recorder.accessibilityPerformPress())
    XCTAssertTrue(PinRecordingKeyRoute.isInstalled)

    history.delete(item)

    XCTAssertNil(AppState.shared.pinRecordingItemID)
    XCTAssertFalse(recorder.recording)
    XCTAssertFalse(PinRecordingKeyRoute.isInstalled, "deleting the item left the local monitor installed")
    try assertKeysReachTheApp()
    assertQuiet(panel)
  }

  func testClosingPreviewReleasesTheRecordingMonitor() throws {
    let panel = makePanel()
    let recorder = installRecorder(in: panel, itemID: UUID())
    AppState.shared.preview.state = .open
    AppState.shared.panelPresented = true
    XCTAssertTrue(recorder.accessibilityPerformPress())
    XCTAssertTrue(PinRecordingKeyRoute.isInstalled)

    AppState.shared.preview.state = .closed

    XCTAssertNil(AppState.shared.pinRecordingItemID)
    XCTAssertFalse(recorder.recording)
    XCTAssertFalse(PinRecordingKeyRoute.isInstalled, "closing preview left the local monitor installed")
    try assertKeysReachTheApp()
    assertQuiet(panel)
  }

  func testBodyFocusReleasesTheRecordingMonitor() throws {
    let panel = makePanel()
    let recorder = installRecorder(in: panel, itemID: UUID())
    AppState.shared.panelPresented = true
    XCTAssertTrue(recorder.accessibilityPerformPress())
    let body = OriginalTextBodyView(frame: NSRect(x: 80, y: 8, width: 100, height: 28))
    body.string = "body"
    panel.contentView?.addSubview(body)

    _ = panel.makeFirstResponder(body)

    XCTAssertNil(AppState.shared.pinRecordingItemID)
    XCTAssertFalse(recorder.recording)
    XCTAssertFalse(PinRecordingKeyRoute.isInstalled, "body focus left the local monitor installed")
    try assertKeysReachTheApp()
    assertQuiet(panel)
  }

  func testSearchFocusReleasesTheRecordingMonitor() throws {
    let panel = makePanel()
    let recorder = installRecorder(in: panel, itemID: UUID())
    AppState.shared.panelPresented = true
    XCTAssertTrue(recorder.accessibilityPerformPress())
    let search = NSTextField(frame: NSRect(x: 80, y: 36, width: 100, height: 22))
    search.isEditable = true
    search.setAccessibilityIdentifier("lab-search-field")
    panel.contentView?.addSubview(search)

    _ = panel.makeFirstResponder(search)

    XCTAssertNil(AppState.shared.pinRecordingItemID)
    XCTAssertFalse(recorder.recording)
    XCTAssertFalse(PinRecordingKeyRoute.isInstalled, "search focus left the local monitor installed")
    try assertKeysReachTheApp()
    assertQuiet(panel)
  }

  func testHostUnloadReleasesTheRecordingMonitor() throws {
    let panel = makePanel()
    let recorder = installRecorder(in: panel, itemID: UUID())
    AppState.shared.panelPresented = true
    XCTAssertTrue(recorder.accessibilityPerformPress())
    XCTAssertTrue(PinRecordingKeyRoute.isInstalled)

    recorder.removeFromSuperview()

    XCTAssertFalse(recorder.recording)
    XCTAssertFalse(PinRecordingKeyRoute.isInstalled, "unloading the host left the local monitor installed")
    try assertKeysReachTheApp()
    assertQuiet(panel)
  }

  func testRecordingStartedBeforeTheViewJoinsTheWindowStillSwallowsCommandQ() throws {
    let panel = makePanel()
    let recorder = PinnedShortcutRecorder()
    recorder.pinned = true
    recorder.itemID = UUID()
    recorder.onCommit = { _, _ in .rejected("occupied") }
    XCTAssertTrue(recorder.accessibilityPerformPress())
    XCTAssertTrue(recorder.recording)
    XCTAssertFalse(PinRecordingKeyRoute.isInstalled)

    panel.contentView?.addSubview(recorder)
    recorder.frame = NSRect(x: 8, y: 8, width: 56, height: 28)

    XCTAssertTrue(PinRecordingKeyRoute.isInstalled)
    XCTAssertTrue(recorder.holdsLocalRecordingKey)
    probe.letters.removeAll()
    NSApp.sendEvent(try commandLetter("q"))
    XCTAssertTrue(recorder.recording)
    XCTAssertEqual(probe.letters, [])
    assertQuiet(panel)
  }

  func testLateOldHostCannotEndTheNewRecordingSession() throws {
    let first = history.add(textItem("old-host"))
    let second = history.add(textItem("new-host"))
    let panel = makePanel()
    let old = installRecorder(in: panel, itemID: first.id)
    let current = installRecorder(in: panel, itemID: second.id)
    old.onCommit = { _, _ in .conflict }
    current.onCommit = { _, _ in .conflict }
    current.frame = NSRect(x: 80, y: 8, width: 56, height: 28)
    AppState.shared.panelPresented = true
    XCTAssertTrue(old.accessibilityPerformPress())
    XCTAssertTrue(current.accessibilityPerformPress())
    XCTAssertTrue(PinRecordingKeyRoute.owner === current)
    XCTAssertEqual(AppState.shared.pinRecordingItemID, second.id)

    old.removeFromSuperview()
    AppState.shared.cancelPinRecording(itemID: first.id)

    XCTAssertEqual(AppState.shared.pinRecordingItemID, second.id)
    XCTAssertTrue(current.recording)
    XCTAssertTrue(current.ownsSession)
    XCTAssertTrue(PinRecordingKeyRoute.isInstalled)
    XCTAssertTrue(PinRecordingKeyRoute.owner === current)
    watched.removeAll()
    probe.letters.removeAll()
    NSApp.sendEvent(try commandLetter("q"))
    XCTAssertEqual(probe.letters, [], "a late old host let the menu take the new session's key")
    XCTAssertTrue(PinRecordingKeyRoute.owner === current)
    assertQuiet(panel)
  }

  func testOnlyTheCurrentHostWithLegalFocusSwallowsKeys() throws {
    let panel = makePanel()
    let recorder = installRecorder(in: panel, itemID: UUID())
    recorder.sessionActive = { _ in true }
    recorder.onCommit = { _, _ in .conflict }
    AppState.shared.panelPresented = true
    XCTAssertTrue(recorder.accessibilityPerformPress())
    XCTAssertTrue(panel.acceptsKeyForEditing)
    XCTAssertTrue(PinRecordingKeyRoute.isInstalled)
    // Local-monitor order is not stable. A watch installed before the product
    // monitor can record a key that the later monitor then swallows, so an
    // empty watch is not proof and a non-empty watch is not a leak. The menu
    // is after every monitor; the prompt changes only inside the recorder's
    // consume path. keyCode 12 is q, so a passed-through event can fire the menu.
    probe.letters.removeAll()
    NSApp.sendEvent(try commandLetter("q", keyCode: 12))
    XCTAssertEqual(probe.letters, [], "the current recording host did not keep command-q out of the menu")
    XCTAssertEqual(
      promptValue(in: recorder),
      PinShortcutCapture.conflictPrompt,
      "legal recording focus did not consume command-q on the installed local monitor"
    )
    XCTAssertTrue(recorder.recording)
    XCTAssertTrue(recorder.ownsSession)
    XCTAssertTrue(PinRecordingKeyRoute.isInstalled)
    XCTAssertTrue(PinRecordingKeyRoute.owner === recorder)
    NSApp.sendEvent(try plainLetter("a"))
    XCTAssertEqual(probe.letters, [], "a plain letter during recording reached the menu")
    XCTAssertEqual(
      promptValue(in: recorder),
      PinShortcutCapture.illegalPrompt,
      "legal recording focus did not consume the plain letter on the installed local monitor"
    )
    XCTAssertTrue(recorder.recording)
    XCTAssertTrue(PinRecordingKeyRoute.owner === recorder)

    let mirror = PinnedShortcutRecorder()
    mirror.itemID = recorder.itemID
    mirror.pinned = true
    mirror.sessionActive = { _ in true }
    mirror.frame = NSRect(x: 80, y: 8, width: 56, height: 28)
    panel.contentView?.addSubview(mirror)
    mirror.configure(itemID: recorder.itemID, pinned: true, recording: true, message: nil, error: nil)
    XCTAssertFalse(mirror.ownsSession)
    XCTAssertTrue(PinRecordingKeyRoute.owner === recorder)

    let bare = NSPanel(
      contentRect: NSRect(x: -24000, y: -24000, width: 80, height: 40),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    bare.isReleasedWhenClosed = false
    panels.append(bare)
    let stranger = PinnedShortcutRecorder()
    stranger.pinned = true
    stranger.frame = NSRect(x: 4, y: 4, width: 56, height: 28)
    bare.contentView?.addSubview(stranger)
    let ownerBeforeStranger = PinRecordingKeyRoute.owner
    XCTAssertTrue(stranger.accessibilityPerformPress())
    XCTAssertTrue(
      PinRecordingKeyRoute.owner === ownerBeforeStranger,
      "a recorder without a local key grant took the route"
    )

    let search = NSTextField(frame: NSRect(x: 80, y: 36, width: 100, height: 22))
    search.isEditable = true
    search.setAccessibilityIdentifier("lab-search-field")
    panel.contentView?.addSubview(search)
    _ = panel.makeFirstResponder(search)
    XCTAssertFalse(PinRecordingKeyRoute.isInstalled)
    try assertKeysReachTheApp()
    assertQuiet(panel)
  }

  func testInactiveSessionDoesNotSwallowTheArrivingKey() throws {
    let panel = makePanel()
    let recorder = installRecorder(in: panel, itemID: UUID())
    var active = true
    recorder.sessionActive = { _ in active }
    AppState.shared.panelPresented = true
    XCTAssertTrue(recorder.accessibilityPerformPress())
    active = false
    watched.removeAll()
    probe.letters.removeAll()

    NSApp.sendEvent(try commandLetter("q"))

    XCTAssertEqual(probe.letters, ["q"], "an inactive recording session still ate command-q")
    XCTAssertFalse(PinRecordingKeyRoute.isInstalled, "an inactive session left the monitor installed after the key")
    XCTAssertFalse(recorder.recording)
    assertQuiet(panel)
  }

  func testSaveFailureReleasesTheMonitorAndKeepsTheError() throws {
    let panel = makePanel()
    let recorder = installRecorder(in: panel, itemID: UUID())
    recorder.onCommit = { _, _ in .failed("disk") }
    AppState.shared.panelPresented = true
    XCTAssertTrue(recorder.accessibilityPerformPress())
    watched.removeAll()

    NSApp.sendEvent(try commandLetter("a"))

    XCTAssertFalse(recorder.recording)
    XCTAssertFalse(recorder.ownsSession)
    XCTAssertFalse(panel.acceptsKeyForEditing)
    XCTAssertFalse(PinRecordingKeyRoute.isInstalled, "a failed save left the local monitor installed")
    XCTAssertEqual(promptValue(in: recorder), "disk")
    try assertKeysReachTheApp()
    assertQuiet(panel)
  }

  private func promptValue(in root: NSView) -> String? {
    if root.accessibilityIdentifier() == "lab-shortcut-prompt" {
      return (root as? NSTextField)?.stringValue
    }
    for subview in root.subviews {
      if let value = promptValue(in: subview) { return value }
    }
    return nil
  }

  private func assertKeysReachTheApp() throws {
    watched.removeAll()
    probe.letters.removeAll()
    NSApp.sendEvent(try plainLetter("a"))
    NSApp.sendEvent(try commandLetter("q"))
    XCTAssertEqual(watched, ["a", "q"], "a residual monitor intercepted ordinary input")
    XCTAssertEqual(probe.letters, ["q"], "a residual monitor intercepted the menu key")
  }

  private func assertQuiet(_ panel: NSPanel) {
    XCTAssertFalse(panel.isVisible)
    XCTAssertLessThan(panel.frame.maxX, 0)
    XCTAssertFalse(panel.isKeyWindow)
    XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0, front)
    XCTAssertEqual(NSApp.isActive, wasActive)
  }

  private func installRecorder(in panel: NSPanel, itemID: UUID) -> PinnedShortcutRecorder {
    let recorder = PinnedShortcutRecorder()
    recorder.itemID = itemID
    recorder.pinned = true
    recorder.frame = NSRect(x: 8, y: 8, width: 56, height: 28)
    recorder.onBegin = { AppState.shared.beginPinRecording(itemID: $0) }
    recorder.onCancel = { AppState.shared.cancelPinRecording(itemID: $0) }
    recorder.sessionActive = { AppState.shared.pinRecordingItemID == $0 }
    panel.contentView?.addSubview(recorder)
    return recorder
  }

  private func makePanel() -> QuietRecordingPanel {
    let panel = QuietRecordingPanel(
      contentRect: NSRect(x: -24000, y: -24000, width: 220, height: 80),
      onClose: {},
      view: { QuietMark() }
    )
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior.remove(.moveToActiveSpace)
    panel.setFrame(NSRect(x: -24000, y: -24000, width: 220, height: 80), display: false)
    let shell = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 80))
    panel.contentView = shell
    panels.append(panel)
    return panel
  }

  private func commandLetter(_ letter: String, keyCode: UInt16 = 0) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: .command,
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: 0,
      context: nil,
      characters: letter,
      charactersIgnoringModifiers: letter,
      isARepeat: false,
      keyCode: keyCode
    ))
  }

  private func plainLetter(_ letter: String) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: 0,
      context: nil,
      characters: letter,
      charactersIgnoringModifiers: letter,
      isARepeat: false,
      keyCode: 0
    ))
  }

  private func textItem(_ value: String) -> HistoryItem {
    let item = HistoryItem(contents: [
      HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data(value.utf8))
    ])
    item.title = value
    Storage.shared.context.insert(item)
    return item
  }
}

/// Source inventory of product-button copy. Not a five-button sample, and not a
/// hover observation: this test never moves the pointer or looks for a bubble.
/// Confirmation-role buttons stay in the inventory. Clear/quit no longer use
/// SwiftUI confirmationDialog Button.help: that configured AXHelp and did not
/// install a native toolTip in a real window. They now share the
/// delete path's NSAlert addButton.toolTip. Tag-delete confirmationDialog
/// buttons stay. System traffic-light buttons are not authored Button sites.
/// None of that is a physical hover pass.
@MainActor
final class ProductButtonCopyTests: XCTestCase {
  func testEveryProductButtonHasHelpCopyBeyondASample() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("WitsCopy")
    let files = try swiftFiles(under: root)
    var covered: [String] = []
    var missing: [String] = []
    var confirmationRoles: [String] = []
    var alertButtons: [String] = []
    var systemWindowButtons: [String] = []
    let wrappers = ["railButton(", "WorkspaceRailTagButton(", "WorkspaceOptionsButton("]
    for url in files {
      let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
      let rel = url.path.replacingOccurrences(of: root.deletingLastPathComponent().path + "/", with: "")
      for index in lines.indices {
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        if line.contains("func ") { continue }
        if line.contains("standardWindowButton") {
          systemWindowButtons.append("\(rel):\(index + 1)")
          continue
        }
        if line.hasPrefix("let button =") || line.hasPrefix("let create =") || line.hasPrefix("let cancel =") {
          continue
        }
        if line == "Button(action: action) {" { continue }
        let isWrapper = wrappers.contains { line.contains($0) }
        let isAlertButton = line.contains("addButton(")
        let isControl = isAlertButton
          || line.contains("Button(")
          || line.contains("ImmediateIconButton(")
          || line.contains("ImmediateMenuButton(")
          || line.contains("EditActionButton(")
        guard isControl || isWrapper else { continue }
        let spanEnd = min(index + 12, lines.count)
        var roleEnd = spanEnd
        if index + 1 < lines.count {
          for follow in (index + 1)..<spanEnd {
            let followLine = lines[follow].trimmingCharacters(in: .whitespaces)
            let followControl = followLine.contains("Button(")
              || followLine.contains("ImmediateIconButton(")
              || followLine.contains("ImmediateMenuButton(")
              || followLine.contains("EditActionButton(")
              || followLine.contains("addButton(")
            if followControl {
              roleEnd = follow
              break
            }
          }
        }
        let span = lines[index..<spanEnd].joined(separator: "\n")
        let roleSpan = lines[index..<roleEnd].joined(separator: "\n")
        let site = "\(rel):\(index + 1): \(line.prefix(90))"
        let hasCopy = span.contains("iconHelp") || span.contains("help:") || span.contains(".help(") || span.contains("toolTip")
        let roleKind: String? = {
          if roleSpan.contains("role: .destructive") { return "destructive" }
          if roleSpan.contains("role: .cancel") { return "cancel" }
          if roleSpan.contains("role: .save") { return "save" }
          return nil
        }()
        if let roleKind {
          let helpMarker = [
            ".help(confirmation.confirmHelp)",
            ".help(confirmation.cancelHelp)",
            "directory_error_dismiss_help",
            "ApplicationImportDismissHelp",
            "tag_delete_confirm_help",
            "tag_delete_cancel_help",
            "tag_edit_error_dismiss_help",
            "paste_permission_later_help",
            "edit_save_help",
            "edit_cancel_help",
          ].first { roleSpan.contains($0) } ?? "none"
          confirmationRoles.append("\(roleKind)|\(hasCopy)|\(helpMarker)|\(site)")
        }
        if isAlertButton {
          alertButtons.append(site)
        }
        if isWrapper || hasCopy {
          covered.append(site)
        } else {
          missing.append(site)
        }
      }
    }

    XCTAssertGreaterThanOrEqual(covered.count, 30, "inventory collapsed to a sample: \(covered)")
    let titleSectionLive = files.contains { url in
      guard url.lastPathComponent != "OriginalTextEdit.swift" else { return false }
      return (try? String(contentsOf: url, encoding: .utf8))?.contains("RichTitleEditSection(") == true
    }
    XCTAssertFalse(
      titleSectionLive,
      "RichTitleEditSection is referenced; remove the unmounted title form instead of keeping its save/cancel"
    )
    let retiredEditor = confirmationRoles.filter { $0.contains("EditActionButton(") }
    let liveRoles = confirmationRoles.filter { !$0.contains("EditActionButton(") }
    let expectedLive = [
      "cancel|true|directory_error_dismiss_help|",
      "cancel|true|ApplicationImportDismissHelp|",
      "destructive|true|tag_delete_confirm_help|",
      "cancel|true|tag_delete_cancel_help|",
      "cancel|true|tag_edit_error_dismiss_help|",
    ]
    XCTAssertEqual(
      liveRoles.map { entry in
        expectedLive.first { entry.contains($0) } ?? entry
      }.sorted(),
      expectedLive.sorted(),
      "live confirmation set changed; name the removed or added entry instead of lowering a bound: \(liveRoles)"
    )
    XCTAssertEqual(
      retiredEditor.count,
      0,
      "unmounted title save/cancel were removed with the form, not left as a hidden exception: \(retiredEditor)"
    )
    let editSource = try String(contentsOf: root.appendingPathComponent("Views/OriginalTextEdit.swift"), encoding: .utf8)
    XCTAssertFalse(editSource.contains("struct RichTitleEditSection"))
    XCTAssertFalse(editSource.contains("OriginalTextTitleFieldView"))
    let richSource = try String(contentsOf: root.appendingPathComponent("Views/RichTextEdit.swift"), encoding: .utf8)
    XCTAssertTrue(richSource.contains("case titleOnly"))
    let appStateSource = try String(contentsOf: root.appendingPathComponent("Observables/AppState.swift"), encoding: .utf8)
    XCTAssertTrue(appStateSource.contains("func saveTitlePreservingRich"))
    XCTAssertEqual(
      alertButtons.count,
      7,
      "NSAlert buttons changed; delete has two, footer clear/quit two, paste failure open/copy/cancel three: \(alertButtons)"
    )
    XCTAssertEqual(
      alertButtons.filter { site in !covered.contains(site) },
      [],
      "NSAlert buttons without toolTip: \(alertButtons)"
    )
    XCTAssertGreaterThan(systemWindowButtons.count, 0, "system traffic lights should stay listed as out of the product-button inventory")
    XCTAssertFalse(missing.contains { $0.contains("standardWindowButton") })
    XCTAssertEqual(missing, [], "product buttons without help copy: \(missing.joined(separator: " | "))")
    let joined = covered.joined(separator: "\n")
    XCTAssertTrue(joined.contains("lab-wrap-toggle") || files.contains { url in
      (try? String(contentsOf: url))?.contains("lab-wrap-toggle") == true
    })
    let source = try String(contentsOf: root.appendingPathComponent("WorkspaceManagementView.swift"), encoding: .utf8)
    XCTAssertTrue(source.contains("lab-rail-rename-confirm"))
    XCTAssertTrue(source.contains("lab-rail-merge-confirm"))
    XCTAssertTrue(source.contains("lab-snippet-add"))
    XCTAssertTrue(source.contains("tag_rename_help"))
    XCTAssertTrue(source.contains("tag_merge_help"))
    XCTAssertTrue(source.contains("snippet_add_help"))
    XCTAssertTrue(source.contains("tag_delete_confirm_help"))
    XCTAssertTrue(source.contains("tag_delete_cancel_help"))
    XCTAssertTrue(source.contains("directory_error_dismiss_help"))
    XCTAssertTrue(source.contains("tag_edit_error_dismiss_help"))
    let confirmation = try String(contentsOf: root.appendingPathComponent("Views/ConfirmationView.swift"), encoding: .utf8)
    XCTAssertTrue(confirmation.contains("presentFooterConfirmation"))
    XCTAssertFalse(confirmation.contains("confirmationDialog"), "clear/quit must not keep the dialog whose .help did not show")
    let footer = try String(contentsOf: root.appendingPathComponent("Observables/Footer.swift"), encoding: .utf8)
    for key in ["clear_alert_confirm_help", "clear_alert_cancel_help", "quit_alert_confirm_help", "quit_alert_cancel_help"] {
      XCTAssertTrue(footer.contains(key), "data-driven confirmation missing \(key)")
    }
    let alerts = try String(contentsOf: root.appendingPathComponent("Observables/AppState.swift"), encoding: .utf8)
    XCTAssertTrue(alerts.contains("confirmButton.toolTip"))
    XCTAssertTrue(alerts.contains("cancelButton.toolTip"))
    XCTAssertTrue(alerts.contains("suppressionButton?.toolTip"))
    XCTAssertTrue(alerts.contains("response == .alertFirstButtonReturn"))
    XCTAssertTrue(alerts.contains("confirmation.confirmHelpKey"))
    XCTAssertTrue(alerts.contains("confirmation.cancelHelpKey"))
    XCTAssertTrue(alerts.contains("func presentFooterConfirmation"))
    let slot = try String(contentsOf: root.appendingPathComponent("Views/PinShortcutRecorder.swift"), encoding: .utf8)
    XCTAssertTrue(slot.contains("enum HistoryShortcutSlotCopy"))
    XCTAssertTrue(slot.contains("final class HistoryShortcutSlotView"))
    XCTAssertTrue(slot.contains("func applySlotHelp"))
    XCTAssertTrue(slot.contains("toolTip"))
    XCTAssertTrue(slot.contains("onSelect?(itemID)"))
    if let start = slot.range(of: "final class HistoryShortcutSlotView"),
       let end = slot.range(of: "\nstruct HistoryShortcutSlot", range: start.upperBound..<slot.endIndex) {
      let body = slot[start.lowerBound..<end.lowerBound]
      XCTAssertTrue(body.contains("toolTip"))
      XCTAssertTrue(
        body.contains("recorder?.mouseDown(with: event)"),
        "slot tooltip must forward the click to the recorder, not replace it"
      )
      XCTAssertTrue(body.contains("override func hitTest"), "slot hit testing no longer reaches the recorder")
    } else {
      XCTFail("HistoryShortcutSlotView body was not bounded")
    }
    for key in HistoryShortcutSlotCopy.pinnedKey == "row_shortcut_help" ? [HistoryShortcutSlotCopy.pinnedKey, HistoryShortcutSlotCopy.unpinnedKey] : [] {
      XCTAssertFalse(HistoryShortcutSlotCopy.text(pinned: key == HistoryShortcutSlotCopy.pinnedKey).isEmpty, key)
    }
    XCTAssertNotEqual(
      HistoryShortcutSlotCopy.text(pinned: true),
      HistoryShortcutSlotCopy.text(pinned: false)
    )
    for name in ["en.lproj/Localizable.strings", "zh-Hans.lproj/Localizable.strings"] {
      let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
      for key in [
        "tag_rename_help", "tag_merge_help", "snippet_add_help",
        "clear_alert_confirm_help", "clear_alert_cancel_help",
        "quit_alert_confirm_help", "quit_alert_cancel_help",
        "clear_alert_suppress_help", "quit_alert_suppress_help",
        "delete_item_alert_confirm_help", "delete_item_alert_cancel_help",
        "delete_item_alert_suppress_help",
        "tag_delete_confirm_help", "tag_delete_cancel_help",
        "directory_error_dismiss_help", "tag_edit_error_dismiss_help",
        "row_shortcut_help", "row_shortcut_help_disabled"
      ] {
        XCTAssertTrue(text.contains("\"\(key)\""), "\(name) missing \(key)")
      }
    }
  }

  private func swiftFiles(under root: URL) throws -> [URL] {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
      return []
    }
    var urls: [URL] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
      urls.append(url)
    }
    return urls.sorted { $0.path < $1.path }
  }
}

private struct QuietMark: View {
  var body: some View { Color.clear.frame(width: 4, height: 4) }
}

private final class QuietRecordingPanel: FloatingPanel<QuietMark> {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
  override func makeKey() {}
  override func becomeKey() {}
  override func makeMain() {}
  override func makeKeyAndOrderFront(_ sender: Any?) {}
  override func orderFront(_ sender: Any?) {}
  override func orderFrontRegardless() {}
  override func orderBack(_ sender: Any?) {}
  override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {}
}

private final class KeyRouteProbe: NSObject {
  var letters: [String] = []
  let menu = NSMenu()

  override init() {
    super.init()
    let item = NSMenuItem(title: "q", action: #selector(fired(_:)), keyEquivalent: "q")
    item.keyEquivalentModifierMask = .command
    item.target = self
    menu.addItem(item)
  }

  @objc func fired(_ sender: NSMenuItem) {
    letters.append(sender.keyEquivalent)
  }
}
