import AppKit
import ObjectiveC
import SwiftUI
import XCTest
@testable import WitsCopy

/// Focused contracts for explicit paste and inactive-panel tooltips.
/// Does not copy, activate, post keys, or call AX against another application.
/// This stage does not build or run the suite.
@MainActor
final class PasteIntentTests: XCTestCase {
  private var panels: [NSWindow] = []
  private let savedPinned = AppState.shared.windowPinned
  private let savedPresented = AppState.shared.panelPresented
  private let savedSection = AppState.shared.workspaceSection

  override func tearDown() {
    panels.forEach { $0.close() }
    panels.removeAll()
    AppState.shared.windowPinned = savedPinned
    AppState.shared.panelPresented = savedPresented
    AppState.shared.workspaceSection = savedSection
    Clipboard.shared.resetExplicitPasteClaim()
    Clipboard.shared.copyProbe = nil
    Clipboard.shared.explicitHideProbe = nil
    Clipboard.shared.explicitRestoreProbe = nil
    Clipboard.shared.explicitPasteKeyProbe = nil
    Clipboard.shared.explicitSessionTapProbe = nil
    Clipboard.shared.explicitActivateProbe = nil
    Clipboard.shared.lastExplicitPasteResult = nil
    Clipboard.shared.explicitPasteFeedbackKey = nil
    Accessibility.trustProbe = nil
    PinRecordingKeyRoute.end(nil)
    ImmediateActionButton.menuPopupForTests = nil
    AppState.shared.menuTracking = false
    PopupSpyMenu.pops = 0
    PopupSpyMenu.heldTargets = -1
    ContextMenuSpy.restore()
    ContextMenuSpy.calls = 0
    ContextMenuSpy.heldTargets = -1
    super.tearDown()
  }

  func testShowDoesNotTakeKeyAndRemembersFocusBeforeOrdering() {
    let front = frontPID
    let preview = AppState.shared.preview
    let savedList = preview.layoutListWidth
    let savedPreview = preview.layoutPreviewWidth
    let savedHeight = preview.currentHeight
    let savedState = preview.state
    defer {
      preview.layoutListWidth = savedList
      preview.layoutPreviewWidth = savedPreview
      preview.currentHeight = savedHeight
      preview.state = savedState
    }

    let panel = makePanel()
    panel.collectionBehavior.remove(.moveToActiveSpace)
    let record = sampleRecord(pid: 4242)
    panel.pasteFocusSource = {
      XCTAssertFalse(panel.didStartPresentation)
      return record
    }
    AppState.shared.windowPinned = true
    Clipboard.shared.explicitPasteLedger.notePasted(itemID: UUID(), now: 1)

    panel.open(height: 200)

    XCTAssertEqual(panel.pasteFocus?.snapshot.processIdentifier, 4242)
    XCTAssertEqual(panel.pasteFocusAvailability, .recorded(record.snapshot))
    XCTAssertTrue(panel.didStartPresentation)
    XCTAssertEqual(panel.makeKeyCount, 0, "isolated show must not order or take the user's key")
    XCTAssertEqual(panel.orderCount, 0)
    XCTAssertFalse(panel.isKeyWindow)
    XCTAssertFalse(panel.isVisible)
    XCTAssertTrue(panel.acceptsKeyForEditing, "show arms key after capture")
    XCTAssertTrue(FloatingPanel<QuietMark>.shouldMakeKeyOnShow())
    XCTAssertTrue(AppState.shared.windowPinned)
    XCTAssertNil(Clipboard.shared.explicitPasteLedger.lastPasteItem)
    XCTAssertEqual(frontPID, front)
  }

  func testHideKeepsPinAndRecordedField() {
    let front = frontPID
    let panel = makePanel()
    panel.pasteFocus = sampleRecord(pid: 4242, title: "Notes")
    panel.pasteFocusAvailability = .recorded(panel.pasteFocus!.snapshot)
    panel.isPresented = true
    AppState.shared.windowPinned = true

    panel.hideForExplicitPaste()

    XCTAssertTrue(AppState.shared.windowPinned)
    XCTAssertFalse(panel.isPresented)
    XCTAssertEqual(panel.pasteFocus?.snapshot.processIdentifier, 4242)
    XCTAssertEqual(panel.pasteFocus?.snapshot.windowTitle, "Notes")
    XCTAssertFalse(panel.acceptsKeyForEditing)
    XCTAssertEqual(panel.makeKeyCount, 0)
    XCTAssertEqual(frontPID, front)
  }

  func testMouseBrowseDoesNotRequestKeyButEditorClickDoes() {
    let front = frontPID
    let panel = makePanel()
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 40))
    let plain = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
    let field = NSTextField(frame: NSRect(x: 48, y: 8, width: 60, height: 22))
    field.isEditable = true
    field.isBordered = false
    host.addSubview(plain)
    host.addSubview(field)
    panel.contentView = host

    XCTAssertFalse(FloatingPanel<QuietMark>.hitRequestsKey(plain))
    XCTAssertTrue(FloatingPanel<QuietMark>.hitRequestsKey(field))
    XCTAssertFalse(panel.canBecomeKey)

    panel.sendEvent(mouseDown(on: plain))
    XCTAssertEqual(panel.makeKeyCount, 0)
    XCTAssertFalse(panel.acceptsKeyForEditing)
    XCTAssertFalse(panel.isKeyWindow)

    panel.pasteFocus = sampleRecord(pid: 4242)
    panel.sendEvent(mouseDown(on: field))
    XCTAssertGreaterThan(panel.makeKeyCount, 0)
    XCTAssertTrue(panel.acceptsKeyForEditing)
    XCTAssertFalse(panel.isKeyWindow)
    XCTAssertEqual(panel.pasteFocus?.snapshot.processIdentifier, 4242)
    XCTAssertEqual(frontPID, front)
  }

  /// First click on a rich body that may edit, but is not editable yet, must
  /// take the same key route as an already editable field. Read-only file
  /// preview, a rich body without edit permission, and row chrome must not.
  func testRichTextAllowsEditFirstClickRequestsKey() {
    let front = frontPID
    let panel = makePanel()
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 40))
    let row = NSView(frame: NSRect(x: 0, y: 0, width: 16, height: 40))
    let file = PreviewNSTextView(usingTextLayoutManager: false)
    file.isSelectable = true
    file.isRichText = true
    file.drawsBackground = false
    file.string = "file"
    file.frame = NSRect(x: 18, y: 8, width: 18, height: 24)
    file.isEditable = false
    let locked = RichTextBodyView(frame: NSRect(x: 38, y: 8, width: 18, height: 24))
    locked.allowsEdit = false
    locked.isEditable = false
    let rich = RichTextBodyView(frame: NSRect(x: 58, y: 8, width: 18, height: 24))
    rich.allowsEdit = true
    rich.isEditable = false
    host.addSubview(row)
    host.addSubview(file)
    host.addSubview(locked)
    host.addSubview(rich)
    panel.contentView = host

    XCTAssertFalse(FloatingPanel<QuietMark>.hitRequestsKey(row))
    XCTAssertFalse(FloatingPanel<QuietMark>.hitRequestsKey(file))
    XCTAssertFalse(FloatingPanel<QuietMark>.hitRequestsKey(locked))
    XCTAssertTrue(FloatingPanel<QuietMark>.hitRequestsKey(rich))

    panel.sendEvent(mouseDown(on: row))
    panel.sendEvent(mouseDown(on: file))
    panel.sendEvent(mouseDown(on: locked))
    XCTAssertEqual(panel.makeKeyCount, 0)
    XCTAssertFalse(panel.acceptsKeyForEditing)
    XCTAssertFalse(file.isEditable)
    XCTAssertFalse(locked.isEditable)
    XCTAssertFalse(rich.isEditable)

    panel.pasteFocus = sampleRecord(pid: 4242)
    panel.sendEvent(mouseDown(on: rich))
    XCTAssertGreaterThan(panel.makeKeyCount, 0)
    XCTAssertTrue(panel.acceptsKeyForEditing)
    XCTAssertFalse(panel.isKeyWindow)
    XCTAssertEqual(panel.pasteFocus?.snapshot.processIdentifier, 4242)
    XCTAssertEqual(frontPID, front)
  }

  func testActionClickStillFiresWithoutTakingKey() {
    let panel = makePanel()
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 40))
    let button = ImmediateActionButton(frame: NSRect(x: 8, y: 8, width: 24, height: 24))
    button.isEnabled = true
    var presses = 0
    button.onMouseDown = { presses += 1 }
    host.addSubview(button)
    panel.contentView = host

    panel.sendEvent(mouseDown(on: button))

    XCTAssertEqual(presses, 1)
    XCTAssertFalse(panel.acceptsKeyForEditing)
    XCTAssertEqual(panel.makeKeyCount, 0)
    XCTAssertTrue(button.accessibilityPerformPress())
    XCTAssertEqual(presses, 2)
  }

  func testCaptureRejectsSelfTerminatedAndMissingElement() {
    let selfPID = ProcessInfo.processInfo.processIdentifier
    XCTAssertFalse(PasteFocusCapture.accept(pid: nil, terminated: false, hasElement: true, selfPID: selfPID))
    XCTAssertFalse(PasteFocusCapture.accept(pid: 0, terminated: false, hasElement: true, selfPID: selfPID))
    XCTAssertFalse(PasteFocusCapture.accept(pid: selfPID, terminated: false, hasElement: true, selfPID: selfPID))
    XCTAssertFalse(PasteFocusCapture.accept(pid: 42, terminated: true, hasElement: true, selfPID: selfPID))
    XCTAssertFalse(PasteFocusCapture.accept(pid: 42, terminated: false, hasElement: false, selfPID: selfPID))
    XCTAssertTrue(PasteFocusCapture.accept(pid: 42, terminated: false, hasElement: true, selfPID: selfPID))
    XCTAssertFalse(PasteFocusCapture.acceptApplication(pid: nil, terminated: false, selfPID: selfPID))
    XCTAssertFalse(PasteFocusCapture.acceptApplication(pid: selfPID, terminated: false, selfPID: selfPID))
    XCTAssertFalse(PasteFocusCapture.acceptApplication(pid: 42, terminated: true, selfPID: selfPID))
    XCTAssertTrue(PasteFocusCapture.acceptApplication(pid: 42, terminated: false, selfPID: selfPID))
    XCTAssertEqual(PasteFocusCapture.pasteState(recordedPID: nil, terminated: false, selfPID: selfPID), .missing)
    XCTAssertEqual(PasteFocusCapture.pasteState(recordedPID: 42, terminated: true, selfPID: selfPID), .invalid)
    XCTAssertEqual(PasteFocusCapture.pasteState(recordedPID: 42, terminated: false, selfPID: selfPID), .ready(pid: 42))
    XCTAssertNil(PasteFocusCapture.liveRecord())
    XCTAssertNil(PasteFocusCapture.focusedPID())
    XCTAssertFalse(makePanel().restoreRecordedFocus())
  }

  func testExplicitPasteFailsClosedWithoutHidingOrInjecting() {
    let front = frontPID
    var effects = EffectLog()
    let denied = ExplicitPastePerformer.perform(
      state: .untrusted,
      selfPID: 7,
      effects: effects.make()
    )
    let missing = ExplicitPastePerformer.perform(
      state: .missing,
      selfPID: 7,
      effects: effects.make()
    )
    let invalid = ExplicitPastePerformer.perform(
      state: .invalid,
      selfPID: 7,
      effects: effects.make()
    )
    XCTAssertEqual(effects.hides, 0)
    let wrongField = ExplicitPastePerformer.perform(
      state: .ready(pid: 42),
      selfPID: 7,
      effects: effects.make(restore: true, focused: 99)
    )
    let selfTarget = ExplicitPastePerformer.perform(
      state: .ready(pid: 7),
      selfPID: 7,
      effects: effects.make(restore: true, focused: 7)
    )

    XCTAssertEqual(denied, .failed(.accessibilityDenied))
    XCTAssertEqual(denied.failureMessageKey, "paste_accessibility_denied")
    XCTAssertEqual(missing, .failed(.noTarget))
    XCTAssertEqual(missing.failureMessageKey, "paste_no_target")
    XCTAssertEqual(invalid, .failed(.targetInvalid))
    XCTAssertEqual(invalid.failureMessageKey, "paste_target_invalid")
    XCTAssertEqual(wrongField, .failed(.targetInvalid))
    XCTAssertEqual(selfTarget, .failed(.noTarget))
    XCTAssertEqual(effects.hides, 1)
    XCTAssertEqual(effects.copies, 1)
    XCTAssertEqual(effects.keys, [])
    XCTAssertEqual(effects.sessionTaps, 0)
    XCTAssertEqual(effects.activations, [])
    XCTAssertEqual(frontPID, front)
  }

  func testExplicitPasteHidesThenPostsOnlyToTheRecordedProcess() {
    var effects = EffectLog()
    var pinned = true
    effects.onHide = { pinned = true }
    let result = ExplicitPastePerformer.perform(
      state: .ready(pid: 42),
      selfPID: 7,
      effects: effects.make(restore: true, focused: 42)
    )
    XCTAssertEqual(result, .pasted(pid: 42))
    XCTAssertNil(result.failureMessageKey)
    XCTAssertEqual(effects.hides, 1)
    XCTAssertEqual(effects.copies, 1)
    XCTAssertEqual(effects.restores, 1)
    XCTAssertEqual(effects.keys, [42])
    XCTAssertEqual(effects.sessionTaps, 0)
    XCTAssertEqual(effects.activations, [])
    XCTAssertTrue(pinned)
    XCTAssertLessThan(effects.copyIndex, effects.hideIndex)
    XCTAssertLessThan(effects.hideIndex, effects.restoreIndex)
    XCTAssertLessThan(effects.restoreIndex, effects.keyIndex)
    if case .pasted(let pid) = result {
      XCTAssertEqual(pid, 42)
    } else {
      XCTFail("pasted must name the pid the key was sent to, not a target-text proof")
    }
  }

  func testDoubleClickSubmissionCollapsesToOnePaste() {
    let item = UUID()
    var ledger = ExplicitPasteLedger()
    var effects = EffectLog()
    let first = ExplicitPastePerformer.submit(
      itemID: item,
      eventNumber: 8,
      now: 10,
      interval: 0.5,
      ledger: &ledger,
      state: .ready(pid: 42),
      selfPID: 7,
      effects: effects.make(restore: true, focused: 42)
    )
    let sameEvent = ExplicitPastePerformer.submit(
      itemID: item,
      eventNumber: 8,
      now: 10.1,
      interval: 0.5,
      ledger: &ledger,
      state: .ready(pid: 42),
      selfPID: 7,
      effects: effects.make(restore: true, focused: 42)
    )
    let tooSoon = ExplicitPastePerformer.submit(
      itemID: item,
      eventNumber: 9,
      now: 10.2,
      interval: 0.5,
      ledger: &ledger,
      state: .ready(pid: 42),
      selfPID: 7,
      effects: effects.make(restore: true, focused: 42)
    )
    XCTAssertEqual(first, .pasted(pid: 42))
    XCTAssertEqual(sameEvent, .duplicate)
    XCTAssertEqual(tooSoon, .duplicate)
    XCTAssertEqual(effects.keys, [42])
    XCTAssertEqual(effects.copies, 1)

    ledger.reset()
    let retry = ExplicitPastePerformer.submit(
      itemID: item,
      eventNumber: 10,
      now: 12,
      interval: 0.5,
      ledger: &ledger,
      state: .invalid,
      selfPID: 7,
      effects: effects.make()
    )
    XCTAssertEqual(retry, .failed(.targetInvalid))
    let again = ExplicitPastePerformer.submit(
      itemID: item,
      eventNumber: 11,
      now: 12.1,
      interval: 0.5,
      ledger: &ledger,
      state: .ready(pid: 42),
      selfPID: 7,
      effects: effects.make(restore: true, focused: 42)
    )
    XCTAssertEqual(again, .pasted(pid: 42))
    XCTAssertEqual(effects.keys, [42, 42])
  }

  func testIsolatedSubmitDoesNotCopyActivateOrSendKeys() {
    let front = frontPID
    Clipboard.shared.copyProbe = { _, _ in XCTFail("copied") }
    Clipboard.shared.explicitHideProbe = { XCTFail("hid") }
    Clipboard.shared.explicitRestoreProbe = { XCTFail("restored focus") }
    Clipboard.shared.explicitPasteKeyProbe = { _ in XCTFail("posted a key") }
    Clipboard.shared.explicitSessionTapProbe = { XCTFail("session tap") }
    Clipboard.shared.explicitActivateProbe = { _ in XCTFail("activated") }

    let result = Clipboard.shared.submitExplicitPaste(
      item: nil,
      itemID: UUID(),
      eventNumber: 3,
      removeFormatting: false
    )

    XCTAssertEqual(result, .suppressed)
    XCTAssertNil(result.failureMessageKey)
    XCTAssertEqual(Clipboard.shared.lastExplicitPasteResult, .suppressed)
    XCTAssertNil(Clipboard.shared.explicitPasteFeedbackKey)
    XCTAssertEqual(frontPID, front)
    XCTAssertNil(Accessibility.promptOptions)
  }

  func testHoverTrackingKeepsSystemTipAreasAndPressStillFires() {
    let front = frontPID
    let button = ImmediateActionButton(frame: NSRect(x: 0, y: 0, width: 28, height: 24))
    let foreign = NSTrackingArea(
      rect: button.bounds,
      options: [.mouseEnteredAndExited, .activeInKeyWindow],
      owner: button,
      userInfo: ["systemTip": true]
    )
    button.addTrackingArea(foreign)
    button.toolTip = "Pin window"
    button.updateTrackingAreas()
    button.updateTrackingAreas()

    XCTAssertTrue(button.trackingAreas.contains { $0.userInfo?["systemTip"] as? Bool == true })
    let owned = button.trackingAreas.filter { PanelHoverTracking.isOwned($0) }
    XCTAssertEqual(owned.count, 1)
    XCTAssertTrue(owned[0].options.contains(.activeAlways))

    var presses = 0
    button.onMouseDown = { presses += 1 }
    button.mouseDown(with: mouseDown(at: NSPoint(x: 4, y: 4), windowNumber: 0))
    XCTAssertEqual(presses, 1)
    XCTAssertTrue(button.accessibilityPerformPress())

    XCTAssertEqual(frontPID, front)
  }

  func testSuppressedIsNotAPasteAndFailedRestoreDoesNotSend() {
    XCTAssertNotEqual(ExplicitPasteResult.suppressed, .pasted(pid: 42))
    var effects = EffectLog()
    var ledger = ExplicitPasteLedger()
    let failedRestore = ExplicitPastePerformer.submit(
      itemID: UUID(),
      eventNumber: 4,
      now: 3,
      interval: 0.5,
      ledger: &ledger,
      state: .ready(pid: 42),
      selfPID: 7,
      effects: effects.make(restore: false, focused: 42)
    )
    XCTAssertEqual(failedRestore, .failed(.targetInvalid))
    XCTAssertEqual(effects.copies, 1)
    XCTAssertEqual(effects.hides, 1)
    XCTAssertEqual(effects.keys, [])
    XCTAssertEqual(effects.sessionTaps, 0)
    XCTAssertEqual(effects.activations, [])
    XCTAssertLessThan(effects.copyIndex, effects.hideIndex)
  }

  func testOffscreenRecorderAcceptsOneNativeKeyWithoutBecomingKey() {
    let front = frontPID
    let panel = makePanel()
    let recorder = PinnedShortcutRecorder()
    recorder.itemID = UUID()
    recorder.frame = NSRect(x: 0, y: 0, width: 56, height: 28)
    var committed: String?
    recorder.onCommit = { _, letter in
      committed = letter
      return .saved
    }
    recorder.sessionActive = { _ in true }
    panel.contentView = recorder
    _ = recorder.accessibilityPerformPress()
    XCTAssertFalse(panel.isKeyWindow)
    XCTAssertEqual(panel.makeKeyCount, 0)
    XCTAssertEqual(frontPID, front)
    guard panel.firstResponder === recorder else {
      XCTAssertNil(committed)
      return
    }
    let event = NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: .command,
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: panel.windowNumber,
      context: nil,
      characters: "q",
      charactersIgnoringModifiers: "q",
      isARepeat: false,
      keyCode: 12
    )!
    panel.sendEvent(event)
    XCTAssertEqual(committed, "q")
    XCTAssertFalse(panel.isKeyWindow)
    XCTAssertEqual(frontPID, front)
  }

  func testRecordingRouteEatsEveryLetterWithoutStealingFocus() throws {
    let front = frontPID
    let active = NSApp.isActive
    XCTAssertFalse(PinRecordingKeyRoute.isInstalled)
    let panel = RoutePanel(
      contentRect: NSRect(x: -24000, y: -24000, width: 200, height: 80),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isReleasedWhenClosed = false
    panels.append(panel)
    let shell = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
    panel.contentView = shell
    let preview = PinnedShortcutRecorder()
    let row = PinnedShortcutRecorder()
    let id = UUID()
    preview.itemID = id
    preview.pinned = true
    row.itemID = id
    row.pinned = true
    preview.frame = NSRect(x: 8, y: 8, width: 56, height: 28)
    row.frame = NSRect(x: 80, y: 8, width: 56, height: 28)
    shell.addSubview(preview)
    shell.addSubview(row)
    var seen: [String] = []
    var cancelled = 0
    preview.onCommit = { _, letter in
      seen.append(letter)
      return .conflict
    }
    preview.onCancel = { _ in cancelled += 1 }
    preview.sessionActive = { _ in true }
    row.sessionActive = { _ in true }

    let probe = KeyMenuProbe()
    let menu = NSMenu()
    for scalar in UnicodeScalar("a").value...UnicodeScalar("z").value {
      let letter = String(UnicodeScalar(scalar)!)
      let item = NSMenuItem(title: letter, action: #selector(KeyMenuProbe.fired(_:)), keyEquivalent: letter)
      item.keyEquivalentModifierMask = .command
      item.target = probe
      menu.addItem(item)
    }
    let previous = NSApp.mainMenu
    NSApp.mainMenu = menu
    defer {
      NSApp.mainMenu = previous
      PinRecordingKeyRoute.end(nil)
      panel.close()
    }

    XCTAssertTrue(preview.accessibilityPerformPress())
    XCTAssertTrue(PinRecordingKeyRoute.isInstalled)
    XCTAssertEqual(frontPID, front)
    XCTAssertEqual(NSApp.isActive, active)
    XCTAssertFalse(panel.isVisible)

    for scalar in UnicodeScalar("a").value...UnicodeScalar("z").value {
      let letter = String(UnicodeScalar(scalar)!)
      NSApp.sendEvent(try commandLetter(letter))
    }
    XCTAssertEqual(seen, (UnicodeScalar("a").value...UnicodeScalar("z").value).map { String(UnicodeScalar($0)!) })
    XCTAssertEqual(probe.letters, [])
    XCTAssertEqual(cancelled, 0)
    XCTAssertEqual(frontPID, front)
    XCTAssertEqual(NSApp.isActive, active)

    row.configure(itemID: id, pinned: true, recording: true, message: nil, error: nil)
    XCTAssertFalse(row.ownsSession, "a mirrored recorder must not take the session")
    XCTAssertTrue(preview.ownsSession)
    NSApp.sendEvent(try commandLetter("q"))
    XCTAssertEqual(probe.letters, [])
    XCTAssertEqual(cancelled, 0)
    XCTAssertTrue(seen.contains("q"))
    PinRecordingKeyRoute.end(nil)
    XCTAssertFalse(PinRecordingKeyRoute.isInstalled)
    NSApp.sendEvent(try commandLetter("q"))
    XCTAssertEqual(probe.letters, ["q"], "idle popup must not keep eating keys")
    XCTAssertEqual(frontPID, front)
  }

  private func commandLetter(_ letter: String) throws -> NSEvent {
    let event = NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: .command,
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: 0,
      context: nil,
      characters: letter,
      charactersIgnoringModifiers: letter,
      isARepeat: false,
      keyCode: 0
    )
    return try XCTUnwrap(event)
  }

  private var frontPID: pid_t {
    NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
  }

  func testQueuedAXPressAfterRemovalDoesNotEnterMenuTracking() {
    ImmediateActionButton.menuPopupForTests = nil
    let savedTracking = AppState.shared.menuTracking
    AppState.shared.menuTracking = false
    defer { AppState.shared.menuTracking = savedTracking }

    let button = ImmediateActionButton(frame: NSRect(x: 8, y: 8, width: 24, height: 24))
    button.isEnabled = true
    var built = 0
    button.menuProvider = {
      built += 1
      let menu = NSMenu()
      menu.addItem(NSMenuItem(title: "Options", action: nil, keyEquivalent: ""))
      return (menu, [])
    }
    let window = NSWindow(
      contentRect: NSRect(x: -24000, y: -24000, width: 80, height: 40),
      styleMask: [.borderless],
      backing: .buffered,
      defer: true
    )
    window.isReleasedWhenClosed = false
    window.contentView?.addSubview(button)
    XCTAssertFalse(window.isVisible)
    XCTAssertNotNil(button.window)
    XCTAssertTrue(button.accessibilityPerformPress())
    button.removeFromSuperview()
    XCTAssertNil(button.window)

    let drained = expectation(description: "queued menu press")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 1)

    XCTAssertEqual(built, 0)
    XCTAssertFalse(AppState.shared.menuTracking)
    XCTAssertFalse(window.isVisible)
    XCTAssertEqual(button.retainedMenuTargetCount, 0)
  }

  func testQueuedAXPressRefusesWindowChangeHideAndDuplicate() {
    let savedTracking = AppState.shared.menuTracking
    AppState.shared.menuTracking = false
    defer {
      AppState.shared.menuTracking = savedTracking
      ImmediateActionButton.menuPopupForTests = nil
    }
    var calls = 0
    ImmediateActionButton.menuPopupForTests = { _, _, _ in calls += 1 }

    let first = makeAnchorWindow(visible: true)
    let second = makeAnchorWindow(visible: true)
    let button = menuButton()
    first.contentView?.addSubview(button)
    XCTAssertTrue(button.accessibilityPerformPress())
    button.removeFromSuperview()
    second.contentView?.addSubview(button)
    drainMain()
    XCTAssertEqual(calls, 0, "queued press must not pop on the old or the new window")
    XCTAssertFalse(AppState.shared.menuTracking)
    XCTAssertEqual(button.retainedMenuTargetCount, 0)

    let hidden = menuButton()
    let hiddenWindow = makeAnchorWindow(visible: true)
    hiddenWindow.contentView?.addSubview(hidden)
    hidden.isHidden = true
    XCTAssertTrue(hidden.accessibilityPerformPress())
    drainMain()
    XCTAssertEqual(calls, 0)
    XCTAssertFalse(AppState.shared.menuTracking)

    let covered = menuButton()
    let clip = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
    clip.isHidden = true
    clip.addSubview(covered)
    makeAnchorWindow(visible: true).contentView?.addSubview(clip)
    XCTAssertTrue(covered.accessibilityPerformPress())
    drainMain()
    XCTAssertEqual(calls, 0)

    let invisible = menuButton()
    let real = NSWindow(
      contentRect: NSRect(x: -24000, y: -24000, width: 80, height: 40),
      styleMask: [.borderless],
      backing: .buffered,
      defer: true
    )
    real.isReleasedWhenClosed = false
    real.contentView?.addSubview(invisible)
    XCTAssertFalse(real.isVisible)
    XCTAssertTrue(invisible.accessibilityPerformPress())
    drainMain()
    XCTAssertEqual(calls, 0)
    XCTAssertFalse(real.isVisible)

    let live = menuButton()
    makeAnchorWindow(visible: true).contentView?.addSubview(live)
    var nestedTargets = -1
    var nestedTracking = false
    ImmediateActionButton.menuPopupForTests = { _, _, view in
      calls += 1
      XCTAssertTrue(view === live)
      live.mouseDown(with: self.mouseDown(on: live))
      XCTAssertTrue(live.accessibilityPerformPress())
      nestedTargets = live.retainedMenuTargetCount
      nestedTracking = AppState.shared.menuTracking
    }
    XCTAssertTrue(live.accessibilityPerformPress())
    XCTAssertTrue(live.accessibilityPerformPress())
    drainMain()
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(nestedTargets, 1)
    XCTAssertTrue(nestedTracking)
    XCTAssertFalse(AppState.shared.menuTracking)
    XCTAssertEqual(live.retainedMenuTargetCount, 0)
  }

  func testForeignMenuSessionIsNotClearedByARefusedPress() {
    let savedTracking = AppState.shared.menuTracking
    defer { AppState.shared.menuTracking = savedTracking }
    AppState.shared.menuTracking = true
    var calls = 0
    ImmediateActionButton.menuPopupForTests = { _, _, _ in calls += 1 }
    defer { ImmediateActionButton.menuPopupForTests = nil }
    let button = menuButton()
    makeAnchorWindow(visible: true).contentView?.addSubview(button)
    XCTAssertTrue(button.accessibilityPerformPress())
    drainMain()
    button.mouseDown(with: mouseDown(on: button))
    XCTAssertEqual(calls, 0)
    XCTAssertTrue(AppState.shared.menuTracking)
    XCTAssertEqual(button.retainedMenuTargetCount, 0)
  }

  func testVisibleMenuAndContextClicksPresentTheLiveAnchor() {
    defer { ImmediateActionButton.menuPopupForTests = nil }
    let button = menuButton()
    button.contextMenuProvider = {
      let menu = NSMenu()
      let item = NSMenuItem(title: "Context", action: nil, keyEquivalent: "")
      item.setAccessibilityIdentifier("lab-context-entry")
      menu.addItem(item)
      return (menu, [])
    }
    let window = makeAnchorWindow(visible: true)
    window.contentView?.addSubview(button)
    button.toolTip = "Options"
    var presented: NSView?
    var identifiers: [String] = []
    var sawEvent = false
    ImmediateActionButton.menuPopupForTests = { menu, event, view in
      presented = view
      sawEvent = event != nil
      identifiers = menu.items.map { $0.accessibilityIdentifier() ?? "" }
    }

    button.mouseDown(with: mouseDown(on: button))
    XCTAssertTrue(presented === button)
    XCTAssertFalse(sawEvent)
    XCTAssertEqual(identifiers, ["lab-options-entry"])
    XCTAssertFalse(AppState.shared.menuTracking)
    XCTAssertEqual(button.retainedMenuTargetCount, 0)
    XCTAssertEqual(button.toolTip, "Options")

    presented = nil
    identifiers = []
    sawEvent = false
    XCTAssertTrue(button.accessibilityPerformPress())
    drainMain()
    XCTAssertTrue(presented === button)
    XCTAssertEqual(identifiers, ["lab-options-entry"])
    XCTAssertFalse(sawEvent)

    let control = NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: button.convert(NSPoint(x: 4, y: 4), to: nil),
      modifierFlags: [.control],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber,
      context: nil,
      eventNumber: 2,
      clickCount: 1,
      pressure: 1
    )!
    button.mouseDown(with: control)
    XCTAssertTrue(sawEvent)
    XCTAssertEqual(identifiers, ["lab-context-entry"])
    XCTAssertTrue(presented === button)

    let right = NSEvent.mouseEvent(
      with: .rightMouseDown,
      location: button.convert(NSPoint(x: 4, y: 4), to: nil),
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber,
      context: nil,
      eventNumber: 3,
      clickCount: 1,
      pressure: 1
    )!
    sawEvent = false
    identifiers = []
    button.rightMouseDown(with: right)
    XCTAssertTrue(sawEvent)
    XCTAssertEqual(identifiers, ["lab-context-entry"])
    XCTAssertFalse(window.isKeyWindow)
    XCTAssertFalse(AppState.shared.menuTracking)
  }

  func testPlainClickStillFiresAndDisabledQueuedPressDoesNotPresent() {
    defer { ImmediateActionButton.menuPopupForTests = nil }
    var presses = 0
    var calls = 0
    ImmediateActionButton.menuPopupForTests = { _, _, _ in calls += 1 }
    let plain = ImmediateActionButton(frame: NSRect(x: 8, y: 8, width: 24, height: 24))
    plain.isEnabled = true
    plain.toolTip = "Pin"
    plain.onMouseDown = { presses += 1 }
    plain.mouseDown(with: mouseDown(at: NSPoint(x: 4, y: 4), windowNumber: 0))
    XCTAssertTrue(plain.accessibilityPerformPress())
    XCTAssertEqual(presses, 2)
    XCTAssertEqual(calls, 0)
    XCTAssertEqual(plain.toolTip, "Pin")

    let button = menuButton()
    makeAnchorWindow(visible: true).contentView?.addSubview(button)
    XCTAssertTrue(button.accessibilityPerformPress())
    button.isEnabled = false
    drainMain()
    XCTAssertEqual(calls, 0)
    button.isEnabled = true
    let cleared = menuButton()
    makeAnchorWindow(visible: true).contentView?.addSubview(cleared)
    XCTAssertTrue(cleared.accessibilityPerformPress())
    cleared.menuProvider = nil
    drainMain()
    XCTAssertEqual(calls, 0)
    XCTAssertFalse(cleared.accessibilityPerformPress())
    XCTAssertEqual(presses, 2)
  }

  func testQueuedAXPressWithoutWindowDoesNotAdoptLaterAnchor() {
    let savedTracking = AppState.shared.menuTracking
    AppState.shared.menuTracking = false
    defer {
      AppState.shared.menuTracking = savedTracking
      ImmediateActionButton.menuPopupForTests = nil
    }
    var calls = 0
    var built = 0
    ImmediateActionButton.menuPopupForTests = { _, _, _ in calls += 1 }
    let button = ImmediateActionButton(frame: NSRect(x: 8, y: 8, width: 24, height: 24))
    button.isEnabled = true
    button.menuProvider = {
      built += 1
      return self.menuPair()
    }
    XCTAssertNil(button.window)
    XCTAssertTrue(button.accessibilityPerformPress())
    let window = makeAnchorWindow(visible: true)
    window.contentView?.addSubview(button)
    XCTAssertTrue(button.window === window)
    drainMain()
    XCTAssertEqual(calls, 0, "nil stamp at press must not be filled by a window attached before drain")
    XCTAssertEqual(built, 0)
    XCTAssertFalse(AppState.shared.menuTracking)
    XCTAssertEqual(button.retainedMenuTargetCount, 0)
    XCTAssertFalse(window.isKeyWindow)

    calls = 0
    built = 0
    XCTAssertTrue(button.accessibilityPerformPress())
    drainMain()
    XCTAssertEqual(calls, 1, "a new press after the button is attached may present")
    XCTAssertEqual(built, 1)
    XCTAssertFalse(AppState.shared.menuTracking)
    XCTAssertEqual(button.retainedMenuTargetCount, 0)
  }

  func testMenuProviderRemovalRewindowOrForeignTakeoverDoesNotPop() {
    let savedTracking = AppState.shared.menuTracking
    AppState.shared.menuTracking = false
    defer {
      AppState.shared.menuTracking = savedTracking
      ImmediateActionButton.menuPopupForTests = nil
    }
    var calls = 0
    var seized = -1
    ImmediateActionButton.menuPopupForTests = { _, _, view in
      calls += 1
      seized = (view as? ImmediateActionButton)?.retainedMenuTargetCount ?? -1
    }

    let removed = menuButton()
    makeAnchorWindow(visible: true).contentView?.addSubview(removed)
    removed.menuProvider = {
      removed.removeFromSuperview()
      return self.menuPair()
    }
    removed.mouseDown(with: mouseDown(on: removed))
    XCTAssertEqual(calls, 0, "provider removal must not pop")
    XCTAssertEqual(seized, -1, "must not install targets and then pop")
    XCTAssertNil(removed.window)
    XCTAssertFalse(AppState.shared.menuTracking)
    XCTAssertEqual(removed.retainedMenuTargetCount, 0)

    let moved = menuButton()
    let origin = makeAnchorWindow(visible: true)
    let later = makeAnchorWindow(visible: true)
    origin.contentView?.addSubview(moved)
    moved.menuProvider = {
      moved.removeFromSuperview()
      later.contentView?.addSubview(moved)
      return self.menuPair()
    }
    calls = 0
    seized = -1
    moved.mouseDown(with: mouseDown(on: moved))
    XCTAssertEqual(calls, 0, "provider must not pop on a window it attached during the call")
    XCTAssertEqual(seized, -1)
    XCTAssertTrue(moved.window === later)
    XCTAssertFalse(AppState.shared.menuTracking)
    XCTAssertEqual(moved.retainedMenuTargetCount, 0)

    let thief = menuButton()
    makeAnchorWindow(visible: true).contentView?.addSubview(thief)
    thief.menuProvider = {
      AppState.shared.menuTracking = true
      return self.menuPair()
    }
    calls = 0
    seized = -1
    thief.mouseDown(with: mouseDown(on: thief))
    XCTAssertEqual(calls, 0, "provider takeover must not pop")
    XCTAssertEqual(seized, -1, "must not seize targets after another session takes tracking")
    XCTAssertTrue(AppState.shared.menuTracking, "must not clear tracking taken during provider")
    XCTAssertEqual(thief.retainedMenuTargetCount, 0)

    AppState.shared.menuTracking = false
    let legal = menuButton()
    makeAnchorWindow(visible: true).contentView?.addSubview(legal)
    calls = 0
    seized = -1
    legal.mouseDown(with: mouseDown(on: legal))
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(seized, 1)
    XCTAssertFalse(AppState.shared.menuTracking)
    XCTAssertEqual(legal.retainedMenuTargetCount, 0)
  }

  func testWorkspaceTagDropMenuRefusesInvalidAnchorAndKeepsForeignTracking() {
    PopupSpyMenu.pops = 0
    let detached = tagMenuButton()
    XCTAssertNil(detached.window)
    detached.mouseDown(with: mouseDown(at: NSPoint(x: 4, y: 4), windowNumber: 0))
    XCTAssertEqual(PopupSpyMenu.pops, 0, "detached left click must not pop")

    let hidden = tagMenuButton()
    let hiddenWindow = makeAnchorWindow(visible: true)
    hiddenWindow.contentView?.addSubview(hidden)
    hidden.isHidden = true
    let hiddenBefore = PopupSpyMenu.pops
    hidden.mouseDown(with: mouseDown(on: hidden))
    XCTAssertEqual(PopupSpyMenu.pops, hiddenBefore, "hidden button must not pop")

    let covered = tagMenuButton()
    let clip = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
    clip.isHidden = true
    clip.addSubview(covered)
    makeAnchorWindow(visible: true).contentView?.addSubview(clip)
    let coveredBefore = PopupSpyMenu.pops
    covered.mouseDown(with: mouseDown(on: covered))
    XCTAssertEqual(PopupSpyMenu.pops, coveredBefore, "hidden ancestor must not pop")

    let invisible = tagMenuButton()
    let real = NSWindow(
      contentRect: NSRect(x: -24000, y: -24000, width: 80, height: 40),
      styleMask: [.borderless],
      backing: .buffered,
      defer: true
    )
    real.isReleasedWhenClosed = false
    panels.append(real)
    real.contentView?.addSubview(invisible)
    XCTAssertFalse(real.isVisible)
    let invisibleBefore = PopupSpyMenu.pops
    invisible.mouseDown(with: mouseDown(on: invisible))
    XCTAssertEqual(PopupSpyMenu.pops, invisibleBefore, "invisible window must not pop")
    XCTAssertFalse(real.isVisible)
    XCTAssertFalse(real.isKeyWindow)

    let removed = tagMenuButton()
    makeAnchorWindow(visible: true).contentView?.addSubview(removed)
    removed.menuProvider = {
      removed.removeFromSuperview()
      return (self.spyMenu(), [])
    }
    let removedBefore = PopupSpyMenu.pops
    removed.mouseDown(with: mouseDown(on: removed))
    XCTAssertEqual(PopupSpyMenu.pops, removedBefore, "provider removal must not pop")
    XCTAssertNil(removed.window)
    XCTAssertFalse(AppState.shared.menuTracking)

    let moved = tagMenuButton()
    let origin = makeAnchorWindow(visible: true)
    let later = makeAnchorWindow(visible: true)
    origin.contentView?.addSubview(moved)
    moved.menuProvider = {
      moved.removeFromSuperview()
      later.contentView?.addSubview(moved)
      return (self.spyMenu(), [])
    }
    let movedBefore = PopupSpyMenu.pops
    moved.mouseDown(with: mouseDown(on: moved))
    XCTAssertEqual(PopupSpyMenu.pops, movedBefore, "provider must not pop on a window attached during the call")
    XCTAssertTrue(moved.window === later)
    XCTAssertFalse(AppState.shared.menuTracking)

    AppState.shared.menuTracking = true
    let blocked = tagMenuButton()
    makeAnchorWindow(visible: true).contentView?.addSubview(blocked)
    let blockedBefore = PopupSpyMenu.pops
    blocked.mouseDown(with: mouseDown(on: blocked))
    XCTAssertEqual(PopupSpyMenu.pops, blockedBefore, "external tracking must not be seized")
    XCTAssertTrue(AppState.shared.menuTracking, "external tracking must not be cleared")

    AppState.shared.menuTracking = false
    let thief = tagMenuButton()
    makeAnchorWindow(visible: true).contentView?.addSubview(thief)
    thief.menuProvider = {
      AppState.shared.menuTracking = true
      return (self.spyMenu(), [])
    }
    let thiefBefore = PopupSpyMenu.pops
    thief.mouseDown(with: mouseDown(on: thief))
    XCTAssertEqual(PopupSpyMenu.pops, thiefBefore, "provider takeover must not pop")
    XCTAssertTrue(AppState.shared.menuTracking, "must not clear tracking taken during provider")

    guard ContextMenuSpy.install() else {
      XCTFail("could not observe NSMenu.popUpContextMenu; context counterexample not run")
      return
    }
    defer { ContextMenuSpy.restore() }

    let detachedContext = tagMenuButton()
    let contextBefore = ContextMenuSpy.calls
    let contextPopBefore = PopupSpyMenu.pops
    detachedContext.rightMouseDown(with: rightMouseDown(on: detachedContext))
    detachedContext.mouseDown(with: controlMouseDown(on: detachedContext))
    XCTAssertEqual(ContextMenuSpy.calls, contextBefore, "detached context click must not pop")
    XCTAssertEqual(PopupSpyMenu.pops, contextPopBefore, "context path must not fall through to left-click popUp")

    let contextRemoved = tagMenuButton()
    makeAnchorWindow(visible: true).contentView?.addSubview(contextRemoved)
    contextRemoved.contextMenuProvider = {
      contextRemoved.removeFromSuperview()
      AppState.shared.menuTracking = true
      return (self.spyMenu(), [])
    }
    AppState.shared.menuTracking = false
    let contextRemovedBefore = ContextMenuSpy.calls
    contextRemoved.rightMouseDown(with: rightMouseDown(on: contextRemoved))
    XCTAssertEqual(ContextMenuSpy.calls, contextRemovedBefore, "context provider removal must not pop")
    XCTAssertTrue(AppState.shared.menuTracking, "context provider must not clear tracking it took")
    XCTAssertNil(contextRemoved.window)

    let contextMoved = tagMenuButton()
    let contextOrigin = makeAnchorWindow(visible: true)
    let contextLater = makeAnchorWindow(visible: true)
    contextOrigin.contentView?.addSubview(contextMoved)
    contextMoved.contextMenuProvider = {
      contextMoved.removeFromSuperview()
      contextLater.contentView?.addSubview(contextMoved)
      return (self.spyMenu(), [])
    }
    AppState.shared.menuTracking = false
    let contextMovedBefore = ContextMenuSpy.calls
    contextMoved.mouseDown(with: controlMouseDown(on: contextMoved))
    XCTAssertEqual(ContextMenuSpy.calls, contextMovedBefore, "control-click must not pop on a window attached during provider")
    XCTAssertTrue(contextMoved.window === contextLater)
    XCTAssertFalse(AppState.shared.menuTracking)

    AppState.shared.menuTracking = false
    let legal = tagMenuButton()
    legal.menuProvider = { self.spyPair() }
    legal.contextMenuProvider = { self.spyPair() }
    let legalWindow = makeAnchorWindow(visible: true)
    legalWindow.contentView?.addSubview(legal)
    let legalBefore = PopupSpyMenu.pops
    PopupSpyMenu.heldTargets = -1
    legal.mouseDown(with: mouseDown(on: legal))
    XCTAssertEqual(PopupSpyMenu.pops, legalBefore + 1, "legal left click on a routed anchor may present")
    XCTAssertEqual(PopupSpyMenu.heldTargets, 1)
    XCTAssertEqual(legal.retainedMenuTargetCount, 0)
    XCTAssertFalse(AppState.shared.menuTracking)
    XCTAssertFalse(legalWindow.isKeyWindow)

    let legalContextBefore = ContextMenuSpy.calls
    ContextMenuSpy.heldTargets = -1
    legal.rightMouseDown(with: rightMouseDown(on: legal))
    XCTAssertEqual(ContextMenuSpy.calls, legalContextBefore + 1, "legal right click may present")
    XCTAssertEqual(ContextMenuSpy.heldTargets, 1)
    XCTAssertEqual(legal.retainedMenuTargetCount, 0)
    XCTAssertFalse(AppState.shared.menuTracking)
    legal.mouseDown(with: controlMouseDown(on: legal))
    XCTAssertEqual(ContextMenuSpy.calls, legalContextBefore + 2, "legal control click may present")
    XCTAssertEqual(ContextMenuSpy.heldTargets, 1)
    XCTAssertEqual(legal.retainedMenuTargetCount, 0)
    XCTAssertFalse(AppState.shared.menuTracking)
    XCTAssertEqual(PopupSpyMenu.pops, legalBefore + 1)

    var presses = 0
    legal.onMouseDown = { presses += 1 }
    let axBefore = PopupSpyMenu.pops
    let axContextBefore = ContextMenuSpy.calls
    XCTAssertTrue(legal.accessibilityPerformPress())
    XCTAssertEqual(presses, 1, "AX press stays the ordinary action")
    XCTAssertEqual(PopupSpyMenu.pops, axBefore)
    XCTAssertEqual(ContextMenuSpy.calls, axContextBefore)
  }

  private func menuButton() -> ImmediateActionButton {
    let button = ImmediateActionButton(frame: NSRect(x: 8, y: 8, width: 24, height: 24))
    button.isEnabled = true
    button.menuProvider = {
      let menu = NSMenu()
      let item = NSMenuItem(title: "Clear", action: #selector(MenuActionTarget.fire(_:)), keyEquivalent: "")
      item.setAccessibilityIdentifier("lab-options-entry")
      let target = MenuActionTarget {}
      item.target = target
      menu.addItem(item)
      return (menu, [target])
    }
    return button
  }

  private func menuPair() -> (NSMenu, [MenuActionTarget]) {
    let menu = NSMenu()
    let item = NSMenuItem(title: "Clear", action: #selector(MenuActionTarget.fire(_:)), keyEquivalent: "")
    item.setAccessibilityIdentifier("lab-options-entry")
    let target = MenuActionTarget {}
    item.target = target
    menu.addItem(item)
    return (menu, [target])
  }

  private func spyMenu() -> PopupSpyMenu {
    let menu = PopupSpyMenu()
    menu.addItem(NSMenuItem(title: "Tag", action: nil, keyEquivalent: ""))
    return menu
  }

  private func spyPair() -> (PopupSpyMenu, [MenuActionTarget]) {
    let menu = spyMenu()
    let target = MenuActionTarget {}
    menu.items[0].target = target
    menu.items[0].action = #selector(MenuActionTarget.fire(_:))
    return (menu, [target])
  }

  private func tagMenuButton() -> WorkspaceTagDropButton {
    let button = WorkspaceTagDropButton(frame: NSRect(x: 8, y: 8, width: 24, height: 24))
    button.isEnabled = true
    button.menuProvider = { (self.spyMenu(), []) }
    button.contextMenuProvider = { (self.spyMenu(), []) }
    return button
  }

  private func rightMouseDown(on view: NSView) -> NSEvent {
    NSEvent.mouseEvent(
      with: .rightMouseDown,
      location: view.convert(NSPoint(x: 4, y: 4), to: nil),
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: view.window?.windowNumber ?? 0,
      context: nil,
      eventNumber: 3,
      clickCount: 1,
      pressure: 1
    )!
  }

  private func controlMouseDown(on view: NSView) -> NSEvent {
    NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: view.convert(NSPoint(x: 4, y: 4), to: nil),
      modifierFlags: [.control],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: view.window?.windowNumber ?? 0,
      context: nil,
      eventNumber: 2,
      clickCount: 1,
      pressure: 1
    )!
  }

  private func makeAnchorWindow(visible: Bool) -> MenuAnchorWindow {
    let window = MenuAnchorWindow(
      contentRect: NSRect(x: -24000, y: -24000, width: 80, height: 40),
      styleMask: [.borderless],
      backing: .buffered,
      defer: true
    )
    window.isReleasedWhenClosed = false
    window.reportsVisible = visible
    panels.append(window)
    return window
  }

  private func drainMain() {
    let drained = expectation(description: "main")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 1)
  }

  private func makePanel() -> QuietPastePanel {
    let panel = QuietPastePanel(
      contentRect: NSRect(x: -24000, y: -24000, width: 80, height: 40),
      onClose: {},
      view: { QuietMark() }
    )
    panel.collectionBehavior.remove(.moveToActiveSpace)
    panel.setFrame(NSRect(x: -24000, y: -24000, width: 80, height: 40), display: false)
    panels.append(panel)
    return panel
  }

  private func sampleRecord(pid: pid_t, title: String? = "Editor") -> PasteFocusRecord {
    PasteFocusRecord(
      snapshot: PasteFocusSnapshot(
        processIdentifier: pid,
        bundleIdentifier: "com.example.Editor",
        localizedName: "Editor",
        windowTitle: title,
        role: "AXTextArea",
        subrole: nil,
        identifier: "body"
      ),
      application: nil,
      window: nil,
      element: nil
    )
  }

  private func mouseDown(on view: NSView) -> NSEvent {
    let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    return mouseDown(at: point, windowNumber: view.window?.windowNumber ?? 0)
  }

  private func mouseDown(at point: NSPoint, windowNumber: Int) -> NSEvent {
    NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: point,
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: windowNumber,
      context: nil,
      eventNumber: 1,
      clickCount: 1,
      pressure: 1
    )!
  }
}

private final class EffectLog {
  var hides = 0
  var copies = 0
  var keys: [pid_t] = []
  var sessionTaps = 0
  var activations: [pid_t] = []
  var hideIndex = -1
  var copyIndex = -1
  var restoreIndex = -1
  var keyIndex = -1
  var step = 0
  var restores = 0
  var onHide: () -> Void = {}

  func make(restore: Bool = false, focused: pid_t? = nil) -> ExplicitPasteEffects {
    ExplicitPasteEffects(
      hideWithoutUnpinning: {
        self.step += 1
        self.hides += 1
        self.hideIndex = self.step
        self.onHide()
      },
      restoreFocus: {
        self.step += 1
        self.restores += 1
        self.restoreIndex = self.step
        return restore
      },
      focusedPID: { focused },
      copy: {
        self.step += 1
        self.copies += 1
        self.copyIndex = self.step
      },
      sendPasteKey: { pid in
        self.step += 1
        self.keys.append(pid)
        self.keyIndex = self.step
      },
      sessionTap: { self.sessionTaps += 1 },
      activate: { self.activations.append($0) }
    )
  }
}

private final class PopupSpyMenu: NSMenu {
  static var pops = 0
  static var heldTargets = -1
  override func popUp(positioning item: NSMenuItem?, at location: NSPoint, in view: NSView?) -> Bool {
    Self.pops += 1
    Self.heldTargets = (view as? WorkspaceTagDropButton)?.retainedMenuTargetCount ?? -1
    return true
  }
}

private final class ContextMenuSpy {
  static var calls = 0
  static var heldTargets = -1
  private static var installed = false
  private static var original: IMP?

  static func install() -> Bool {
    guard !installed else { return true }
    let sel = NSSelectorFromString("popUpContextMenu:withEvent:forView:")
    guard let method = class_getClassMethod(NSMenu.self, sel) else { return false }
    original = method_getImplementation(method)
    let block: @convention(block) (AnyObject, NSMenu, NSEvent, NSView) -> Void = { _, _, _, view in
      calls += 1
      heldTargets = (view as? WorkspaceTagDropButton)?.retainedMenuTargetCount ?? -1
    }
    method_setImplementation(method, imp_implementationWithBlock(block))
    installed = true
    return true
  }

  static func restore() {
    guard installed, let original else { return }
    let sel = NSSelectorFromString("popUpContextMenu:withEvent:forView:")
    guard let method = class_getClassMethod(NSMenu.self, sel) else { return }
    method_setImplementation(method, original)
    installed = false
    self.original = nil
  }
}

private struct QuietMark: View {
  var body: some View { Color.clear.frame(width: 4, height: 4) }
}

private final class MenuAnchorWindow: NSWindow {
  var reportsVisible = false
  override var isVisible: Bool { reportsVisible }
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
  override func orderFront(_ sender: Any?) {}
  override func orderFrontRegardless() {}
  override func makeKey() {}
  override func makeKeyAndOrderFront(_ sender: Any?) {}
}

private final class QuietPastePanel: FloatingPanel<QuietMark> {
  var makeKeyCount = 0
  var orderCount = 0

  override func makeKey() { makeKeyCount += 1 }
  override func becomeKey() {}
  override func makeMain() {}
  override func makeKeyAndOrderFront(_ sender: Any?) { makeKeyCount += 1 }
  override func orderFront(_ sender: Any?) { orderCount += 1 }
  override func orderFrontRegardless() { orderCount += 1 }
  override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) { orderCount += 1 }

  override func setFrame(_ frameRect: NSRect, display flag: Bool) {
    super.setFrame(
      NSRect(x: -24000, y: -24000, width: max(frameRect.width, 80), height: max(frameRect.height, 40)),
      display: false
    )
  }
}

private final class RoutePanel: NSPanel, LocalRecordingKeyWindow {
  var allowsKey = false
  override var canBecomeKey: Bool { allowsKey }
  override var canBecomeMain: Bool { false }
  func requestLocalRecordingKey() { allowsKey = true }
  func releaseLocalRecordingKey() { allowsKey = false }
  override func orderFront(_ sender: Any?) {}
  override func orderFrontRegardless() {}
  override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {}
}

private final class KeyMenuProbe: NSObject {
  var letters: [String] = []
  @objc func fired(_ sender: NSMenuItem) {
    letters.append(sender.keyEquivalent)
  }
}
