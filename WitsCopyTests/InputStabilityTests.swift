import AppKit
import SwiftUI
import XCTest
@testable import WitsCopy

/// Pure decisions for popup chord, outside click, Esc, and the shortcut lane.
/// Does not register a shortcut, post events, open a window, or touch the pasteboard.
/// The production chord is whatever KeyboardShortcuts has; there is no test-only key.
final class InputStabilityTests: XCTestCase {
  func testHeldPopupChordDoesNotCycleSelectOrReset() {
    let open = PopupHotkeyRoute.firstDown(panelClosed: true)
    XCTAssertTrue(open.open)
    XCTAssertFalse(open.close)
    XCTAssertFalse(open.highlightNext)
    XCTAssertFalse(open.select)
    XCTAssertFalse(open.resetSelection)

    for _ in 0..<5 {
      let repeatDown = PopupHotkeyRoute.localChord()
      XCTAssertTrue(repeatDown.consume)
      XCTAssertFalse(repeatDown.open)
      XCTAssertFalse(repeatDown.close)
      XCTAssertFalse(repeatDown.highlightNext)
      XCTAssertFalse(repeatDown.select)
      XCTAssertFalse(repeatDown.resetSelection)
    }

    let released = PopupHotkeyRoute.modifiersReleased()
    XCTAssertFalse(released.select)
    XCTAssertFalse(released.resetSelection)
    XCTAssertFalse(released.highlightNext)
    XCTAssertFalse(released.close)
    XCTAssertFalse(released.open)

    let hide = PopupHotkeyRoute.firstDown(panelClosed: false)
    XCTAssertTrue(hide.close)
    XCTAssertFalse(hide.open)
    XCTAssertFalse(hide.select)
    XCTAssertFalse(hide.highlightNext)
  }

  func testOutsideClickAfterUnpinClosesAndPinnedStays() {
    XCTAssertTrue(PanelOutsideClick.shouldDismiss(
      presented: true, insideOwnedWindow: false,
      windowPinned: false, tagPopover: false, confirmation: false, menu: false
    ))
    XCTAssertFalse(PanelOutsideClick.shouldDismiss(
      presented: true, insideOwnedWindow: false,
      windowPinned: true, tagPopover: false, confirmation: false, menu: false
    ))
    XCTAssertFalse(PanelOutsideClick.shouldDismiss(
      presented: true, insideOwnedWindow: true,
      windowPinned: false, tagPopover: false, confirmation: false, menu: false
    ))
    for blocked in [
      PanelOutsideClick.shouldDismiss(presented: true, insideOwnedWindow: false, windowPinned: false, tagPopover: true, confirmation: false, menu: false),
      PanelOutsideClick.shouldDismiss(presented: true, insideOwnedWindow: false, windowPinned: false, tagPopover: false, confirmation: true, menu: false),
      PanelOutsideClick.shouldDismiss(presented: true, insideOwnedWindow: false, windowPinned: false, tagPopover: false, confirmation: false, menu: true)
    ] {
      XCTAssertFalse(blocked)
    }
    XCTAssertTrue(PanelOutsideClick.shouldDismiss(
      presented: true, insideOwnedWindow: false,
      windowPinned: false, tagPopover: false, confirmation: false, menu: false
    ))
  }

  func testOutsideClickAgreesWithPanelClosePolicy() {
    let cases: [(Bool, Bool, Bool, Bool)] = [
      (false, false, false, false),
      (true, false, false, false),
      (false, true, false, false),
      (false, false, true, false),
      (false, false, false, true)
    ]
    for row in cases {
      let context = PanelFocusContext(
        windowPinned: row.0,
        tagPopoverPresented: row.1,
        confirmationPresented: row.2,
        menuPresented: row.3
      )
      let dismiss = PanelOutsideClick.shouldDismiss(
        presented: true,
        insideOwnedWindow: false,
        windowPinned: row.0,
        tagPopover: row.1,
        confirmation: row.2,
        menu: row.3
      )
      let policy = PanelClosePolicy.decide(.externalClick, context: context)
      XCTAssertEqual(dismiss, policy == .close, "\(row)")
    }
  }

  func testUnpinnedShortcutSlotSelectsAndNeverCopies() {
    for count in [1, 2, 3] {
      let result = ShortcutSlotPointer.result(pinned: false, clickCount: count)
      XCTAssertEqual(result, .select, "clickCount \(count)")
    }
    XCTAssertEqual(ShortcutSlotPointer.result(pinned: true, clickCount: 1), .select)
    XCTAssertEqual(ShortcutSlotPointer.result(pinned: true, clickCount: 2), .selectAndRecord)
  }

  func testEscapeDeliveryDoesNotCancelAndHideTogether() {
    XCTAssertEqual(PanelBrowsingKeys.delivery(isEscape: true, confirmationPresented: false, menuPresented: false, editorOwnsEscape: true, markedText: false, sessionActive: true, cancelArmed: false), .passToEditor)
    XCTAssertEqual(PanelBrowsingKeys.delivery(isEscape: true, confirmationPresented: false, menuPresented: false, editorOwnsEscape: false, markedText: true, sessionActive: false, cancelArmed: false), .passToEditor)
    XCTAssertEqual(PanelBrowsingKeys.delivery(isEscape: true, confirmationPresented: false, menuPresented: false, editorOwnsEscape: false, markedText: false, sessionActive: true, cancelArmed: false), .consumeCancel)
    XCTAssertEqual(PanelBrowsingKeys.delivery(isEscape: true, confirmationPresented: false, menuPresented: false, editorOwnsEscape: false, markedText: false, sessionActive: false, cancelArmed: false), .consumeHide)
    XCTAssertEqual(PanelBrowsingKeys.delivery(isEscape: true, confirmationPresented: true, menuPresented: false, editorOwnsEscape: true, markedText: false, sessionActive: true, cancelArmed: false), .pass)
    XCTAssertFalse(PanelBrowsingKeys.consumes(.passToEditor))
    XCTAssertTrue(PanelBrowsingKeys.consumes(.consumeCancel))
    XCTAssertTrue(PanelBrowsingKeys.consumes(.consumeHide))
    PanelEscapeHandoff.beginEditorEscape()
    XCTAssertTrue(PanelRootEscape.ignoresClose())
    PanelEscapeHandoff.endEditorEscape()
    XCTAssertFalse(PanelRootEscape.ignoresClose())
  }

  func testRegisteredHotKeyHandlerTogglesOnceUntilUp() {
    let popup = Popup()
    defer { popup.deinitEventsMonitor() }
    let before = popup.registeredHotKeyToggles
    popup.deliverRegisteredHotKeyDown()
    XCTAssertEqual(popup.registeredHotKeyToggles, before + 1)
    for _ in 0..<4 {
      popup.deliverRegisteredHotKeyDown()
      XCTAssertEqual(popup.registeredHotKeyToggles, before + 1, "held Carbon down toggled again")
    }
    popup.deliverRegisteredHotKeyUp()
    XCTAssertEqual(popup.registeredHotKeyToggles, before + 1, "key up toggled")
    popup.deliverRegisteredHotKeyDown()
    XCTAssertEqual(popup.registeredHotKeyToggles, before + 2, "a new down edge did not toggle")
    popup.deliverRegisteredHotKeyUp()
  }

  func testPresentedPanelConsumesHideAndDoesNotAlsoCancel() throws {
    var hides = 0
    let panel = FloatingPanel(
      contentRect: NSRect(x: -24000, y: -24000, width: 80, height: 40),
      identifier: "lab-escape-route",
      onClose: { hides += 1 },
      view: { EmptyView() }
    )
    panel.isReleasedWhenClosed = false
    panel.isPresented = true
    AppState.shared.tagEditorItem = nil
    AppState.shared.endPinRecordingSession()
    PanelEscapeHandoff.endEditorEscape()
    let event = try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [],
      timestamp: 1,
      windowNumber: 0,
      context: nil,
      characters: "\u{1b}",
      charactersIgnoringModifiers: "",
      isARepeat: false,
      keyCode: 53
    ))
    XCTAssertNil(panel.localBrowsingEvent(event), "browse Esc was forwarded")
    XCTAssertEqual(hides, 1)
    XCTAssertFalse(panel.isPresented)
    XCTAssertFalse(panel.isVisible)
    XCTAssertFalse(PanelEscapeHandoff.editorOwnsCurrent)
    panel.close()
  }

  func testDragThresholdDoesNotTreatAClickAsADrag() {
    XCTAssertFalse(RowPointerDrag.exceeded(dx: 3, dy: 0))
    XCTAssertTrue(RowPointerDrag.exceeded(dx: 4, dy: 0))
    XCTAssertFalse(RowPointerDrag.exceeded(dx: 2, dy: 2))
  }

  /// The resize band sits a few points outside the frame. A press there is
  /// delivered to the panel and must not count as an outside click; closing
  /// then left an empty, inert glass frame on screen for the whole resize.
  @MainActor
  func testPressInTheResizeBandOutsideTheFrameDoesNotDismiss() throws {
    var hides = 0
    let panel = offscreenPanel { hides += 1 }
    let pinned = AppState.shared.windowPinned
    defer {
      panel.close()
      AppState.shared.windowPinned = pinned
    }
    panel.isPresented = true
    AppState.shared.windowPinned = false
    func press(windowNumber: Int, timestamp: TimeInterval) throws -> NSEvent {
      try XCTUnwrap(NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: NSPoint(x: 20, y: -3),
        modifierFlags: [],
        timestamp: timestamp,
        windowNumber: windowNumber,
        context: nil,
        eventNumber: Int(timestamp),
        clickCount: 1,
        pressure: 1
      ))
    }
    let own = try press(windowNumber: panel.windowNumber, timestamp: 41)
    XCTAssertTrue(own.window === panel, "probe event is not addressed to the panel")
    _ = panel.localBrowsingEvent(own)
    XCTAssertEqual(hides, 0, "a press in the panel's own resize band closed it")
    XCTAssertTrue(panel.isPresented)
  }

  @MainActor
  func testLocalMonitorRouteKeepsConsumedNil() throws {
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let active = NSApp.isActive
    var hides = 0
    let panel = offscreenPanel { hides += 1 }
    defer {
      panel.close()
      AppState.shared.pinRecordingItemID = nil
      AppState.shared.menuTracking = false
      AppState.shared.deleteConfirmationPresented = false
      PanelEscapeHandoff.endEditorEscape()
      XCTAssertFalse(panel.isVisible)
      XCTAssertFalse(panel.isKeyWindow)
      XCTAssertEqual(NSApp.isActive, active)
      XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, front)
    }
    panel.isPresented = true
    let event = try escapeEvent(timestamp: 21)
    XCTAssertTrue(FloatingPanel<EmptyView>.routeLocalBrowsingEvent(event, panel: nil) === event)
    let routed = FloatingPanel<EmptyView>.routeLocalBrowsingEvent(event, panel: panel)
    XCTAssertNil(routed, "consumed nil was turned back into the event")
    XCTAssertEqual(hides, 1)
    XCTAssertFalse(panel.isPresented)
    XCTAssertFalse(panel.escapeTapInstalled, "unit test must not create a session tap")
  }

  @MainActor
  func testInstalledLocalMonitorClosureConsumesBrowseEscape() throws {
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let active = NSApp.isActive
    var hides = 0
    let panel = offscreenPanel { hides += 1 }
    defer {
      panel.close()
      XCTAssertFalse(panel.localBrowsingMonitorInstalled)
      XCTAssertFalse(panel.escapeTapInstalled)
      XCTAssertFalse(panel.isVisible)
      XCTAssertFalse(panel.isKeyWindow)
      XCTAssertEqual(NSApp.isActive, active)
      XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, front)
    }
    panel.isPresented = true
    panel.attachLocalBrowsingMonitor()
    XCTAssertTrue(panel.localBrowsingMonitorInstalled)
    XCTAssertFalse(panel.escapeTapInstalled)
    let event = try XCTUnwrap(
      CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true).flatMap { NSEvent(cgEvent: $0) }
    )
    NSApp.sendEvent(event)
    XCTAssertEqual(hides, 1, "installed local monitor closure did not consume Esc")
    XCTAssertFalse(panel.isPresented)
    XCTAssertFalse(panel.localBrowsingMonitorInstalled, "hide did not release the monitor")
  }

  @MainActor
  func testSameEscapeIsNotAppliedTwiceAndLifecycleReleasesMonitors() throws {
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let active = NSApp.isActive
    var hides = 0
    let panel = offscreenPanel { hides += 1 }
    defer {
      panel.close()
      AppState.shared.pinRecordingItemID = nil
      AppState.shared.menuTracking = false
      AppState.shared.deleteConfirmationPresented = false
      XCTAssertFalse(panel.isVisible)
      XCTAssertEqual(NSApp.isActive, active)
      XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, front)
    }
    let id = UUID()
    panel.isPresented = true
    panel.attachLocalBrowsingMonitor()
    AppState.shared.pinRecordingItemID = id
    let event = try escapeEvent(timestamp: 23)
    XCTAssertNil(FloatingPanel<EmptyView>.routeLocalBrowsingEvent(event, panel: panel))
    XCTAssertNil(AppState.shared.pinRecordingItemID)
    XCTAssertEqual(hides, 0)
    AppState.shared.pinRecordingItemID = id
    XCTAssertNil(FloatingPanel<EmptyView>.routeLocalBrowsingEvent(event, panel: panel))
    XCTAssertEqual(AppState.shared.pinRecordingItemID, id, "the same Esc was applied twice")
    XCTAssertEqual(hides, 0)

    AppState.shared.menuTracking = true
    let menuEsc = try escapeEvent(timestamp: 24)
    XCTAssertTrue(FloatingPanel<EmptyView>.routeLocalBrowsingEvent(menuEsc, panel: panel) === menuEsc)
    XCTAssertEqual(hides, 0)
    AppState.shared.menuTracking = false

    AppState.shared.deleteConfirmationPresented = true
    let confirmEsc = try escapeEvent(timestamp: 25)
    XCTAssertTrue(FloatingPanel<EmptyView>.routeLocalBrowsingEvent(confirmEsc, panel: panel) === confirmEsc)
    XCTAssertEqual(hides, 0)
    AppState.shared.deleteConfirmationPresented = false

    panel.orderOut(nil)
    XCTAssertFalse(panel.localBrowsingMonitorInstalled)
    XCTAssertFalse(panel.escapeTapInstalled)
    XCTAssertFalse(panel.isVisible)

    let hidden = offscreenPanel { hides += 1 }
    hidden.isPresented = true
    hidden.attachLocalBrowsingMonitor()
    hidden.hideForExplicitPaste()
    XCTAssertFalse(hidden.localBrowsingMonitorInstalled)
    XCTAssertFalse(hidden.isPresented)
    XCTAssertFalse(hidden.isVisible)
    hidden.close()
  }

  @MainActor
  func testMarkedTextAndBodyEscapeUndoThenSecondEscapeHides() throws {
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let active = NSApp.isActive
    var hides = 0
    let panel = offscreenPanel { hides += 1 }
    let body = OriginalTextBodyView(frame: NSRect(x: 0, y: 0, width: 60, height: 20))
    body.isEditable = true
    body.string = "changed"
    var cancels = 0
    body.onCancel = {
      cancels += 1
      body.string = "original"
    }
    let hosting = panel.contentView
    let shell = NSView(frame: hosting?.frame ?? NSRect(x: 0, y: 0, width: 80, height: 40))
    shell.setAccessibilityIdentifier("lab-content-shell")
    panel.contentView = shell
    if let hosting {
      shell.addSubview(hosting)
      hosting.frame = shell.bounds
      hosting.autoresizingMask = [.width, .height]
    }
    shell.addSubview(body)
    XCTAssertEqual(body.superview?.accessibilityIdentifier(), "lab-content-shell")
    XCTAssertFalse(
      String(describing: type(of: body.superview as Any)).contains("NSHostingView"),
      "body must not be added under NSHostingView"
    )
    defer {
      panel.close()
      AppState.shared.endPinRecordingSession()
      PanelEscapeHandoff.endEditorEscape()
      XCTAssertFalse(panel.isVisible)
      XCTAssertFalse(panel.isKeyWindow)
      XCTAssertEqual(NSApp.isActive, active)
      XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, front)
    }
    panel.isPresented = true
    XCTAssertTrue(panel.makeFirstResponder(body), "editor was not installed")
    XCTAssertTrue(panel.firstResponder === body)
    body.setMarkedText("候", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: 0, length: 0))
    XCTAssertTrue(body.hasMarkedText())
    let marked = try escapeEvent(timestamp: 31)
    XCTAssertTrue(FloatingPanel<EmptyView>.routeLocalBrowsingEvent(marked, panel: panel) === marked)
    body.keyDown(with: marked)
    XCTAssertEqual(cancels, 0, "IME Esc cancelled the edit")
    XCTAssertNotEqual(body.string, "original")
    XCTAssertEqual(hides, 0)
    XCTAssertTrue(panel.firstResponder === body)

    body.unmarkText()
    XCTAssertFalse(body.hasMarkedText())
    body.string = "changed-more"
    let first = try escapeEvent(timestamp: 32)
    XCTAssertTrue(FloatingPanel<EmptyView>.routeLocalBrowsingEvent(first, panel: panel) === first)
    XCTAssertEqual(hides, 0, "editor Esc was also hidden")
    body.keyDown(with: first)
    XCTAssertEqual(cancels, 1)
    XCTAssertEqual(body.string, "original")
    XCTAssertFalse(panel.firstResponder === body)
    XCTAssertTrue(panel.isPresented)

    let second = try escapeEvent(timestamp: 33)
    XCTAssertNil(FloatingPanel<EmptyView>.routeLocalBrowsingEvent(second, panel: panel))
    XCTAssertEqual(hides, 1)
    XCTAssertEqual(cancels, 1, "second Esc cancelled again")
    XCTAssertFalse(panel.isPresented)
    XCTAssertFalse(panel.localBrowsingMonitorInstalled)
  }

  func testEscapeTapStaysBlockedWithoutTrustAndDoesNotSwallowOtherKeys() {
    XCTAssertEqual(PanelEscapeTap.gate(visible: true, trusted: false, unitTest: false, alreadyInstalled: false), .blockedUntrusted)
    XCTAssertEqual(PanelEscapeTap.gate(visible: true, trusted: true, unitTest: true, alreadyInstalled: false), .skipped)
    XCTAssertEqual(PanelEscapeTap.gate(visible: false, trusted: true, unitTest: false, alreadyInstalled: false), .skipped)
    XCTAssertEqual(PanelEscapeTap.gate(visible: true, trusted: true, unitTest: false, alreadyInstalled: false), .install)
    XCTAssertFalse(PanelEscapeTap.shouldSwallow(keyCode: 0, panelIsKey: false, delivery: .consumeHide))
    XCTAssertFalse(PanelEscapeTap.shouldSwallow(keyCode: 53, panelIsKey: true, delivery: .consumeHide))
    XCTAssertFalse(PanelEscapeTap.shouldSwallow(keyCode: 53, panelIsKey: false, delivery: .pass))
    XCTAssertFalse(PanelEscapeTap.shouldSwallow(keyCode: 53, panelIsKey: false, delivery: .passToEditor))
    XCTAssertTrue(PanelEscapeTap.shouldSwallow(keyCode: 53, panelIsKey: false, delivery: .consumeHide))
    XCTAssertTrue(PanelEscapeTap.shouldSwallow(keyCode: 53, panelIsKey: false, delivery: .consumeCancel))
  }

  @MainActor
  func testHiddenBrowsingPanelDoesNotClaimEscapeIntercept() throws {
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let active = NSApp.isActive
    var hides = 0
    let panel = offscreenPanel { hides += 1 }
    defer {
      panel.close()
      XCTAssertFalse(panel.isVisible)
      XCTAssertEqual(NSApp.isActive, active)
      XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, front)
    }
    panel.isPresented = true
    XCTAssertFalse(panel.isVisible)
    XCTAssertFalse(panel.consumeBrowsingEscapeFromTap(keyCode: 53))
    XCTAssertEqual(hides, 0)
    XCTAssertFalse(panel.escapeTapInstalled)
    XCTAssertFalse(panel.escapeTapBlockedUntrusted)
  }

  @MainActor
  func testPanelEscapeEntriesFollowBrowsingPolicy() throws {
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let active = NSApp.isActive
    var hides = 0
    let panel = offscreenPanel { hides += 1 }
    let body = OriginalTextBodyView(frame: NSRect(x: 0, y: 0, width: 40, height: 16))
    body.isEditable = true
    body.string = "editing"
    panel.contentView?.addSubview(body)
    defer {
      panel.close()
      AppState.shared.pinRecordingItemID = nil
      AppState.shared.previewShortcutItemID = nil
      AppState.shared.menuTracking = false
      AppState.shared.deleteConfirmationPresented = false
      PanelEscapeHandoff.endEditorEscape()
      XCTAssertFalse(panel.isVisible)
      XCTAssertFalse(panel.isKeyWindow)
      XCTAssertEqual(NSApp.isActive, active)
      XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, front)
    }
    panel.isPresented = true
    let recording = UUID()
    AppState.shared.pinRecordingItemID = recording
    panel.keyDown(with: try escapeEvent(timestamp: 41))
    XCTAssertNil(AppState.shared.pinRecordingItemID, "keyDown Esc did not cancel recording")
    XCTAssertEqual(hides, 0, "recording Esc hid the panel")
    panel.close()

    hides = 0
    let cancelPanel = offscreenPanel { hides += 1 }
    cancelPanel.isPresented = true
    AppState.shared.pinRecordingItemID = recording
    cancelPanel.cancelOperation(nil)
    XCTAssertNil(AppState.shared.pinRecordingItemID, "cancelOperation Esc did not cancel recording")
    XCTAssertEqual(hides, 0)
    cancelPanel.close()

    hides = 0
    let menuPanel = offscreenPanel { hides += 1 }
    menuPanel.isPresented = true
    AppState.shared.menuTracking = true
    let menu = try escapeEvent(timestamp: 42)
    XCTAssertTrue(FloatingPanel<EmptyView>.routeLocalBrowsingEvent(menu, panel: menuPanel) === menu)
    menuPanel.keyDown(with: menu)
    menuPanel.cancelOperation(nil)
    XCTAssertEqual(hides, 0, "menu Esc hid the panel")
    XCTAssertTrue(AppState.shared.menuTracking)
    AppState.shared.menuTracking = false
    menuPanel.close()

    hides = 0
    let confirmPanel = offscreenPanel { hides += 1 }
    confirmPanel.isPresented = true
    AppState.shared.deleteConfirmationPresented = true
    let confirm = try escapeEvent(timestamp: 43)
    XCTAssertTrue(FloatingPanel<EmptyView>.routeLocalBrowsingEvent(confirm, panel: confirmPanel) === confirm)
    confirmPanel.keyDown(with: confirm)
    confirmPanel.cancelOperation(nil)
    XCTAssertEqual(hides, 0, "confirmation Esc hid the panel")
    AppState.shared.deleteConfirmationPresented = false
    confirmPanel.close()

    hides = 0
    let shortcutPanel = offscreenPanel { hides += 1 }
    shortcutPanel.isPresented = true
    AppState.shared.previewShortcutItemID = recording
    shortcutPanel.keyDown(with: try escapeEvent(timestamp: 44))
    XCTAssertNil(AppState.shared.previewShortcutItemID, "preview shortcut editor survived Esc")
    XCTAssertEqual(hides, 0, "preview shortcut Esc hid the panel")
    shortcutPanel.close()

    hides = 0
    let editorPanel = offscreenPanel { hides += 1 }
    editorPanel.isPresented = true
    editorPanel.contentView?.addSubview(body)
    XCTAssertTrue(editorPanel.makeFirstResponder(body))
    let editing = try escapeEvent(timestamp: 45)
    XCTAssertTrue(FloatingPanel<EmptyView>.routeLocalBrowsingEvent(editing, panel: editorPanel) === editing)
    editorPanel.keyDown(with: editing)
    editorPanel.cancelOperation(nil)
    XCTAssertEqual(hides, 0, "editor Esc hid the panel")
    XCTAssertTrue(editorPanel.makeFirstResponder(nil))
    editorPanel.keyDown(with: try escapeEvent(timestamp: 46))
    XCTAssertEqual(hides, 1, "idle Esc did not hide")
    XCTAssertFalse(editorPanel.isPresented)
  }

  private func offscreenPanel(_ onClose: @escaping () -> Void) -> FloatingPanel<EmptyView> {
    let panel = FloatingPanel(
      contentRect: NSRect(x: -24000, y: -24000, width: 80, height: 40),
      identifier: "lab-escape-route",
      onClose: onClose,
      view: { EmptyView() }
    )
    panel.isReleasedWhenClosed = false
    return panel
  }

  private func escapeEvent(timestamp: TimeInterval, windowNumber: Int = 0) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [],
      timestamp: timestamp,
      windowNumber: windowNumber,
      context: nil,
      characters: "\u{1b}",
      charactersIgnoringModifiers: "",
      isARepeat: false,
      keyCode: 53
    ))
  }
}
