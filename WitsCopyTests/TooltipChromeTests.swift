import AppKit
import SwiftUI
import XCTest
@testable import WitsCopy

/// Offscreen contracts for the compact hover tip.
/// Does not order front, activate, become key, or touch the pasteboard.
/// Host registration is still required before this file runs.
@MainActor
final class TooltipChromeTests: XCTestCase {
  private final class FlippedHitRoot: NSView {
    override var isFlipped: Bool { true }
  }


  func testShortHelpCopyStaysPresentInChineseAndEnglish() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let zh = try String(contentsOf: root.appendingPathComponent("WitsCopy/zh-Hans.lproj/Localizable.strings"), encoding: .utf8)
    let en = try String(contentsOf: root.appendingPathComponent("WitsCopy/en.lproj/Localizable.strings"), encoding: .utf8)
    let zhPreview = try String(contentsOf: root.appendingPathComponent("WitsCopy/Views/zh-Hans.lproj/PreviewItemView.strings"), encoding: .utf8)
    let enPreview = try String(contentsOf: root.appendingPathComponent("WitsCopy/Views/en.lproj/PreviewItemView.strings"), encoding: .utf8)
    let expected = [
      ("\"row_tag_help\" = \"标签\"", "\"row_tag_help\" = \"Tags\""),
      ("\"selection_pin_help\" = \"置顶\"", "\"selection_pin_help\" = \"Pin\""),
      ("\"selection_unpin_help\" = \"取消置顶\"", "\"selection_unpin_help\" = \"Unpin\""),
      ("\"selection_delete_help\" = \"删除\"", "\"selection_delete_help\" = \"Delete\""),
      ("\"window_pin_help_off\" = \"固定窗口\"", "\"window_pin_help_off\" = \"Pin window\"")
    ]
    for (chinese, english) in expected {
      XCTAssertTrue(zh.contains(chinese), chinese)
      XCTAssertTrue(en.contains(english), english)
    }
    XCTAssertTrue(zhPreview.contains("\"WrapLines\" = \"自动换行\""))
    XCTAssertTrue(zhPreview.contains("\"RecognizeText\" = \"识别文字\""))
    XCTAssertTrue(enPreview.contains("\"WrapLines\" = \"Wrap lines\""))
    XCTAssertTrue(enPreview.contains("\"RecognizeText\" = \"Recognize text\""))
    for key in [
      "tag_directory_name", "tag_directory_invalid", "tag_directory_duplicate",
      "tag_directory_persist_failed", "tag_drop_rejected", "tag_drop_assign_failed", "tag_drop_ghost"
    ] {
      XCTAssertTrue(zh.contains("\"\(key)\""), "zh-Hans missing \(key)")
      XCTAssertTrue(en.contains("\"\(key)\""), "en missing \(key)")
    }
    XCTAssertFalse(zh.contains("这不是固定窗口"))
    XCTAssertFalse(en.contains("This does not pin the window"))
  }

  func testBackgroundDragStaysOffAndTitleBarDragRemains() {
    let window = NSWindow(
      contentRect: NSRect(x: -24000, y: -24000, width: 200, height: 80),
      styleMask: [.titled, .closable, .fullSizeContentView],
      backing: .buffered,
      defer: true
    )
    window.isReleasedWhenClosed = false
    window.setFrame(NSRect(x: -24000, y: -24000, width: 200, height: 80), display: false)
    window.isMovable = true
    window.isMovableByWindowBackground = true
    PanelWindowDrag.lock(window)
    XCTAssertFalse(window.isMovableByWindowBackground)
    XCTAssertTrue(window.isMovable, "title-bar movement was replaced by making the window immovable")
    XCTAssertTrue(PanelWindowDrag.titleBarCanMove(window))
    window.isMovableByWindowBackground = true
    PanelWindowDrag.lock(window)
    XCTAssertFalse(window.isMovableByWindowBackground, "hover/drag-end reopened background dragging")
    XCTAssertTrue(window.isMovable)
    let strip = TitleBarDragStripView()
    XCTAssertTrue(strip.mouseDownCanMoveWindow)
    let row = RowDragSurfaceView()
    XCTAssertFalse(row.mouseDownCanMoveWindow)
    let bounds = CGRect(x: 0, y: 0, width: 200, height: 80)
    XCTAssertTrue(RowDragHit.claims(
      point: CGPoint(x: 8, y: 2),
      bounds: bounds,
      edgesOnly: true,
      topInset: 6,
      bottomInset: 11
    ), "top padding fell through")
    XCTAssertTrue(RowDragHit.claims(
      point: CGPoint(x: 8, y: 74),
      bounds: bounds,
      edgesOnly: true,
      topInset: 6,
      bottomInset: 11
    ), "bottom padding or row gap fell through")
    XCTAssertFalse(RowDragHit.claims(
      point: CGPoint(x: 8, y: 40),
      bounds: bounds,
      edgesOnly: true,
      topInset: 6,
      bottomInset: 11
    ), "edge surface stole the content hit")
    XCTAssertTrue(RowDragHit.claims(
      point: CGPoint(x: 2, y: 40),
      bounds: bounds,
      edgesOnly: false,
      topInset: 0,
      bottomInset: 0
    ), "image edge did not start an item drag")
    XCTAssertFalse(RowDragHit.claims(
      point: CGPoint(x: 180, y: 40),
      bounds: bounds,
      edgesOnly: false,
      topInset: 0,
      bottomInset: 0
    ), "shortcut lane was swallowed by the item drag surface")
    XCTAssertFalse(window.isVisible)
    window.close()
  }

  /// AppKit hitTest receives superview coordinates. A non-zero frame origin must
  /// not be compared with local bounds. Pins use the same RowDragSurfaceView.
  /// Title-bar movement is not verified here.
  func testRowDragHitUsesSuperviewCoordinates() {
    let shell = FlippedHitRoot(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
    let root = FlippedHitRoot(frame: NSRect(x: 48, y: 36, width: 520, height: 240))
    shell.addSubview(root)

    // Negative origin maps the shortcut lane's superview point into the claimed
    // local x range. The surface is above the slot, so a wrong hitTest swallows it.
    let content = RowDragSurfaceView(frame: NSRect(x: -48, y: 24, width: 200, height: 36))
    root.addSubview(content)
    let laneLocal = NSPoint(x: content.bounds.maxX - 8, y: 10)
    let laneInRoot = content.convert(laneLocal, to: root)
    XCTAssertTrue(content.bounds.contains(laneInRoot), "lane superview point must sit inside local bounds or the old comparison cannot fail")
    XCTAssertTrue(RowDragHit.claims(
      point: laneInRoot, bounds: content.bounds, edgesOnly: false, topInset: 0, bottomInset: 0
    ), "lane superview point must look claimed if it is treated as local")
    XCTAssertFalse(RowDragHit.claims(
      point: laneLocal, bounds: content.bounds, edgesOnly: false, topInset: 0, bottomInset: 0
    ))
    let slot = NSView(frame: NSRect(
      x: content.frame.minX + content.bounds.width - HistoryRowMetrics.shortcutWidth,
      y: content.frame.minY,
      width: HistoryRowMetrics.shortcutWidth,
      height: content.bounds.height
    ))
    slot.setAccessibilityIdentifier("slot")
    root.addSubview(slot)
    content.removeFromSuperview()
    root.addSubview(content)

    let edge = RowDragSurfaceView(frame: NSRect(x: 180, y: 80, width: 80, height: 30))
    edge.claimsEdgesOnly = true
    edge.topInset = 6
    edge.bottomInset = 8
    root.addSubview(edge)
    let topLocal = NSPoint(x: 4, y: 2)
    let topInRoot = edge.convert(topLocal, to: root)
    XCTAssertFalse(edge.bounds.contains(topInRoot), "top padding superview point must fall outside local bounds")
    let bottomLocal = NSPoint(x: 4, y: edge.bounds.height - 2)
    XCTAssertFalse(edge.bounds.contains(edge.convert(bottomLocal, to: root)))

    let imageEdge = RowDragSurfaceView(frame: NSRect(x: 300, y: 40, width: 80, height: 30))
    root.addSubview(imageEdge)
    let imageLocal = NSPoint(x: 4, y: 8)
    XCTAssertFalse(imageEdge.bounds.contains(imageEdge.convert(imageLocal, to: root)))

    let pin = RowDragSurfaceView(frame: NSRect(x: 300, y: 150, width: 80, height: 30))
    root.addSubview(pin)
    let tag = NSView(frame: NSRect(x: 16, y: 180, width: 36, height: 16))
    tag.setAccessibilityIdentifier("tag")
    root.addSubview(tag)
    let action = NSView(frame: NSRect(x: 450, y: 40, width: 28, height: 28))
    action.setAccessibilityIdentifier("action")
    root.addSubview(action)

    func hit(_ view: NSView, local: NSPoint) -> NSView? {
      root.hitTest(view.convert(local, to: shell))
    }
    XCTAssertTrue(hit(slot, local: NSPoint(x: 8, y: 10)) === slot, "shortcut slot was swallowed")
    XCTAssertFalse(hit(slot, local: NSPoint(x: 8, y: 10)) === content)
    XCTAssertTrue(hit(edge, local: topLocal) === edge, "top padding missed")
    XCTAssertTrue(hit(edge, local: bottomLocal) === edge, "bottom padding missed")
    XCTAssertFalse(hit(edge, local: NSPoint(x: 8, y: 14)) === edge, "edge surface claimed the middle")
    XCTAssertTrue(hit(imageEdge, local: imageLocal) === imageEdge, "image edge missed after coordinate conversion")
    XCTAssertTrue(hit(pin, local: NSPoint(x: 4, y: 8)) === pin, "pin row does not use the same drag surface")
    XCTAssertTrue(hit(tag, local: NSPoint(x: 4, y: 4)) === tag, "tag chip was intercepted")
    XCTAssertTrue(hit(action, local: NSPoint(x: 4, y: 4)) === action, "row-end action was intercepted")
  }

  /// No test window may be ordered or become key/main, even accidentally.
  private final class HiddenSettingsWindow: NSWindow {
    var presentationAttempts = 0
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func makeKey() { presentationAttempts += 1 }
    override func becomeKey() { presentationAttempts += 1 }
    override func makeMain() { presentationAttempts += 1 }
    override func becomeMain() { presentationAttempts += 1 }
    override func makeKeyAndOrderFront(_ sender: Any?) { presentationAttempts += 1 }
    override func orderFrontRegardless() { presentationAttempts += 1 }
    override func orderFront(_ sender: Any?) { presentationAttempts += 1 }
    override func orderBack(_ sender: Any?) { presentationAttempts += 1 }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
      if place != .out { presentationAttempts += 1 }
    }
  }

  private func prepareSettings(_ controller: LabSettingsWindowController) -> HiddenSettingsWindow {
    let window = controller.prepareWindow {
      let window = HiddenSettingsWindow(
        contentRect: NSRect(x: -24000, y: -24000, width: 400, height: 502),
        styleMask: [.titled, .closable, .miniaturizable],
        backing: .buffered,
        defer: false
      )
      window.setFrameOrigin(NSPoint(x: -24000, y: -24000))
      return window
    } as! HiddenSettingsWindow
    window.contentView?.superview?.layoutSubtreeIfNeeded()
    XCTAssertFalse(window.isVisible)
    XCTAssertFalse(window.isKeyWindow)
    XCTAssertFalse(window.isMainWindow)
    XCTAssertLessThan(window.frame.maxX, 0)
    XCTAssertLessThan(window.frame.maxY, 0)
    XCTAssertEqual(window.presentationAttempts, 0)
    return window
  }

  @MainActor
  private final class SettingsActionRelay: NSObject {
    let target: AnyObject?
    let action: Selector
    var count = 0

    init(target: AnyObject?, action: Selector) {
      self.target = target
      self.action = action
    }

    @objc func select(_ sender: AnyObject) {
      count += 1
      NSApp.sendAction(action, to: target, from: sender)
    }
  }

  private func settingsTabButtons(in window: NSWindow) throws -> [NSButton] {
    let root = try XCTUnwrap(window.contentView?.superview)
    var buttons: [NSButton] = []
    func walk(_ view: NSView) {
      if let button = view as? NSButton,
         button.identifier?.rawValue.hasPrefix("settings-") == true {
        buttons.append(button)
      }
      view.subviews.forEach(walk)
    }
    walk(root)
    return buttons.sorted { $0.convert(.zero, to: nil).x < $1.convert(.zero, to: nil).x }
  }

  private func settingsIconCenter(_ button: NSButton) throws -> NSPoint {
    let cell = try XCTUnwrap(button.cell as? NSButtonCell)
    let rect = cell.imageRect(forBounds: button.bounds)
    XCTAssertGreaterThan(rect.width, 0)
    XCTAssertGreaterThan(rect.height, 0)
    return NSPoint(x: rect.midX, y: rect.midY)
  }

  /// Only local, synthetic NSEvents. NSButton's synchronous tracking loop reads
  /// the queued up event; no global post, pointer movement, AXPress or performClick.
  private func settingsMouseClick(_ point: NSPoint, in window: NSWindow) throws {
    let root = try XCTUnwrap(window.contentView?.superview)
    let hit = root.hitTest(root.convert(point, from: nil))
    let number = Int.random(in: 1000...1000000)
    func event(_ type: NSEvent.EventType) throws -> NSEvent {
      try XCTUnwrap(NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil,
        eventNumber: number, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
      ))
    }
    let down = try event(.leftMouseDown)
    let up = try event(.leftMouseUp)
    NSApp.postEvent(up, atStart: true)
    // Dispatch to AppKit's actual hit-test recipient, not directly to the button.
    // Blank titlebar hits cannot start a window drag in this hidden fixture.
    if let hit, hit is NSControl {
      hit.mouseDown(with: down)
    }
    if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .eventTracking, dequeue: true) {
      hit?.mouseUp(with: pending)
    }
  }

  func testSettingsTabsMouseHitCoversVisibleFace() throws {
    XCTAssertTrue(LabRuntime.isUnitTestProcess)
    XCTAssertTrue(LabRuntime.isIsolated)
    let controller = LabSettingsWindowController()
    let window = prepareSettings(controller)
    defer { window.close() }
    let buttons = try settingsTabButtons(in: window)
    XCTAssertEqual(buttons.compactMap { $0.identifier?.rawValue }, [
      "settings-general", "settings-storage", "settings-privacy", "settings-appearance", "settings-advanced"
    ])
    var relays: [SettingsActionRelay] = []
    for button in buttons {
      let relay = SettingsActionRelay(target: button.target, action: try XCTUnwrap(button.action))
      relays.append(relay)
      button.target = relay
      button.action = #selector(SettingsActionRelay.select(_:))
    }

    // Establish the harness before declaring any peripheral miss a product red.
    for (index, button) in buttons.enumerated() {
      let iconCenter = try settingsIconCenter(button)
      try settingsMouseClick(button.convert(iconCenter, to: nil), in: window)
      XCTAssertEqual(relays[index].count, 1, "HARNESS icon center \(button.title)")
      XCTAssertEqual(window.title, button.title, "HARNESS icon did not install page")
    }
    guard relays.allSatisfy({ $0.count == 1 }) else { return }

    for (index, button) in buttons.enumerated() {
      let view = button
      let w = view.bounds.width
      let h = view.bounds.height
      XCTAssertEqual(w, 55, accuracy: 0.5, "\(button.title): visible face shrank")
      XCTAssertEqual(h, 56, accuracy: 0.5, "\(button.title): visible face shrank")
      XCTAssertEqual(button.accessibilityRole(), .button)
      XCTAssertEqual(button.accessibilityLabel(), button.title)
      let face = button.convert(button.bounds, to: nil)
      XCTAssertEqual(face.minX, 60.5 + CGFloat(index) * 56, accuracy: 0.5)
      XCTAssertEqual(window.frame.height - face.maxY, 32, accuracy: 0.5)
      XCTAssertEqual(window.frame.height - window.contentLayoutRect.maxY, 88, accuracy: 0.5)
      let titleRect = try XCTUnwrap(button.cell as? NSButtonCell).titleRect(forBounds: button.bounds)
      XCTAssertGreaterThan(titleRect.width, 0)
      XCTAssertGreaterThan(titleRect.height, 0)
      let samples: [(String, NSPoint)] = [
        ("center", NSPoint(x: w / 2, y: h / 2)),
        ("icon", try settingsIconCenter(button)),
        ("title", NSPoint(x: titleRect.midX, y: titleRect.midY)),
        ("bottom-left", NSPoint(x: 1, y: 1)),
        ("bottom-right", NSPoint(x: w - 1, y: 1)),
        ("top-left", NSPoint(x: 1, y: h - 1)),
        ("top-right", NSPoint(x: w - 1, y: h - 1)),
        ("left", NSPoint(x: 1, y: h / 2)),
        ("right", NSPoint(x: w - 1, y: h / 2)),
        ("bottom", NSPoint(x: w / 2, y: 1)),
        ("top", NSPoint(x: w / 2, y: h - 1))
      ]
      for (name, local) in samples {
        let other = buttons[(index + 1) % buttons.count]
        try settingsMouseClick(other.convert(try settingsIconCenter(other), to: nil), in: window)
        XCTAssertEqual(window.title, other.title, "HARNESS reset")
        let before = relays[index].count
        try settingsMouseClick(view.convert(local, to: nil), in: window)
        XCTAssertEqual(relays[index].count - before, 1, "\(button.title) \(name): full-face mouse action")
        XCTAssertEqual(window.title, button.title, "\(button.title) \(name): wrong page")
        XCTAssertEqual(buttons.filter { $0.state == .on }.map(\.identifier), [button.identifier])
      }
      let before = relays.map(\.count)
      let outside = [
        NSPoint(x: -0.5, y: h / 2), NSPoint(x: w + 0.5, y: h / 2),
        NSPoint(x: w / 2, y: -0.5), NSPoint(x: w / 2, y: h + 0.5)
      ]
      for point in outside {
        try settingsMouseClick(button.convert(point, to: nil), in: window)
        XCTAssertEqual(relays.map(\.count), before, "\(button.title): outside click selected a page")
      }
      let center = button.convert(NSPoint(x: w / 2, y: h / 2), to: nil)
      button.isEnabled = false
      try settingsMouseClick(center, in: window)
      XCTAssertEqual(relays.map(\.count), before, "disabled tab fired")
      button.isEnabled = true
      button.isHidden = true
      try settingsMouseClick(center, in: window)
      XCTAssertEqual(relays.map(\.count), before, "hidden tab fired")
      button.isHidden = false
    }
    XCTAssertFalse(window.isVisible)
    XCTAssertFalse(window.isKeyWindow)
    XCTAssertEqual(window.presentationAttempts, 0)
  }

  /// Separate from mouse coverage: native focus/AX activation must still select
  /// exactly one page. This is not a VoiceOver or real-key-window acceptance run.
  func testSettingsTabsRetainNativeFocusAndAccessibilityActivation() throws {
    let controller = LabSettingsWindowController()
    let window = prepareSettings(controller)
    defer { window.close() }
    let buttons = try settingsTabButtons(in: window)
    XCTAssertEqual(buttons.count, 5)
    for button in buttons {
      let relay = SettingsActionRelay(target: button.target, action: try XCTUnwrap(button.action))
      button.target = relay
      button.action = #selector(SettingsActionRelay.select(_:))
      XCTAssertTrue(window.makeFirstResponder(button))
      XCTAssertTrue(window.firstResponder === button)
      _ = button.accessibilityPerformPress()
      XCTAssertEqual(relay.count, 1)
      XCTAssertEqual(window.title, button.title)
      XCTAssertEqual(buttons.filter { $0.state == .on }.map(\.identifier), [button.identifier])
      XCTAssertEqual(button.accessibilityValue() as? Int, 1)
      button.target = relay.target
      button.action = relay.action
    }
    XCTAssertFalse(window.isVisible)
    XCTAssertFalse(window.isKeyWindow)
    XCTAssertEqual(window.presentationAttempts, 0)
  }

  @MainActor
  func testSettingsPagesFitTheirContentWithoutCollapsingControls() throws {
    let controller = LabSettingsWindowController()
    let window = prepareSettings(controller)
    defer { window.close() }

    let buttons = try settingsTabButtons(in: window)
    var sharedContentSize: NSSize?
    for title in ["通用", "存储", "隐私", "外观", "高级"] {
      guard let button = buttons.first(where: { $0.title == title }) else {
        XCTFail("missing toolbar button \(title)")
        continue
      }
      _ = button.target?.perform(button.action, with: button)
      RunLoop.current.run(until: Date().addingTimeInterval(0.12))
      let contentHeight = window.contentLayoutRect.height
      XCTAssertEqual(window.contentLayoutRect.width, SettingsMetrics.windowContent.width)
      if let sharedContentSize {
        XCTAssertEqual(window.contentLayoutRect.size, sharedContentSize, "\(title): tab switched window size")
      } else {
        sharedContentSize = window.contentLayoutRect.size
      }
      // Full-size content view: the frame is fixed, the pane fills the layout rect.
      XCTAssertFalse(window.styleMask.contains(.resizable), "settings window has one fixed size")
      XCTAssertEqual(window.frame.height - contentHeight, 88, accuracy: 0.5, "\(title): chrome height")
      let root = try XCTUnwrap(window.contentView)
      let box = try XCTUnwrap(root.subviews.first { $0.accessibilityIdentifier() == "lab-settings-content" })
      XCTAssertEqual(box.frame.height, contentHeight, accuracy: 0.5, "\(title): pane box != layout rect")
      let hosted = try XCTUnwrap(box.subviews.first)
      XCTAssertEqual(box.subviews.count, 1, "\(title): stale pane left in content box")
      XCTAssertEqual(hosted.frame.origin, .zero, "\(title): pane origin drifted")
      XCTAssertEqual(hosted.frame.size.width, box.bounds.width, accuracy: 0.5, "\(title): pane width")
      XCTAssertEqual(hosted.frame.size.height, box.bounds.height, accuracy: 0.5,
                     "\(title): pane height \(hosted.frame.height) != content \(box.bounds.height)")
      hosted.layoutSubtreeIfNeeded()
      var scrolls: [NSScrollView] = []
      func findScrolls(in view: NSView) {
        if let scroll = view as? NSScrollView { scrolls.append(scroll) }
        view.subviews.forEach(findScrolls)
      }
      findScrolls(in: hosted)
      if let outer = scrolls.max(by: { $0.frame.height < $1.frame.height }),
         let document = outer.documentView {
        XCTAssertLessThanOrEqual(document.frame.height, outer.contentView.bounds.height + 1,
                                 "\(title): form needs scrolling, content is clipped")
        XCTAssertEqual(outer.contentView.bounds.origin.y, 0, accuracy: 0.5, "\(title): form not scrolled to top")
      }
      if title == "隐私" {
        var tables: [NSTableView] = []
        func findTables(in view: NSView) {
          if let table = view as? NSTableView { tables.append(table) }
          view.subviews.forEach(findTables)
        }
        if let content = window.contentView { findTables(in: content) }
        XCTAssertEqual(tables.count, 1, "privacy list should be represented by one table")
        XCTAssertGreaterThanOrEqual(tables.first?.frame.height ?? 0, 44, "privacy list collapsed")
      }
    }
  }

  /// The settings window shares the clipboard panel's shell, not its layout.
  @MainActor
  func testSettingsWindowWearsThePanelGlassShell() throws {
    let controller = LabSettingsWindowController()
    let window = prepareSettings(controller)
    defer { window.close() }
    XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
    XCTAssertTrue(window.titlebarAppearsTransparent)
    XCTAssertEqual(window.titlebarSeparatorStyle, .none)
    XCTAssertFalse(window.isOpaque)
    let root = try XCTUnwrap(window.contentView)
    let glass = try XCTUnwrap(root.subviews.first { $0.accessibilityIdentifier() == GlassShell.backgroundIdentifier })
    if #available(macOS 26.0, *) {
      XCTAssertTrue(glass is NSGlassEffectView, "same material as ContentView")
    } else {
      XCTAssertEqual((glass as? NSVisualEffectView)?.material, .popover)
    }
    XCTAssertEqual(glass.frame.size, root.bounds.size, "glass covers title bar and tabs too")
    XCTAssertEqual(window.frame.height - window.contentLayoutRect.maxY, 88, accuracy: 0.5)
  }

  func testInteractivePinSlotIsNotSwallowedAndDoesNotPaste() throws {
    let shell = FlippedHitRoot(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
    let root = FlippedHitRoot(frame: NSRect(x: 12, y: 8, width: 280, height: 60))
    shell.addSubview(root)
    let width: CGFloat = 200
    let surface = RowDragSurfaceView(frame: NSRect(x: 4, y: 6, width: width, height: 36))
    surface.pinSlotWidth = HistoryRowMetrics.pinWidth
    var rowClicks = 0
    surface.onClick = { _, _ in rowClicks += 1 }
    let pinX = width - HistoryRowMetrics.shortcutWidth - HistoryRowMetrics.pinWidth
    let pin = ImmediateActionButton(frame: NSRect(x: surface.frame.minX + pinX, y: 10, width: HistoryRowMetrics.pinWidth, height: 22))
    pin.setAccessibilityIdentifier(RowPinSlot.accessibilityIdentifier(slotID: "row"))
    var pinClicks = 0
    pin.onMouseDown = { pinClicks += 1 }
    root.addSubview(pin)
    root.addSubview(surface)

    let pinLocal = NSPoint(x: pinX + 8, y: 14)
    XCTAssertFalse(RowDragHit.claims(
      point: pinLocal,
      bounds: surface.bounds,
      edgesOnly: false,
      topInset: 0,
      bottomInset: 0,
      pinSlotWidth: HistoryRowMetrics.pinWidth
    ), "interactive pin slot was still claimed by the drag surface")
    XCTAssertTrue(RowDragHit.claims(
      point: pinLocal,
      bounds: surface.bounds,
      edgesOnly: false,
      topInset: 0,
      bottomInset: 0,
      pinSlotWidth: 0
    ), "hidden pin slot became a dead zone")
    XCTAssertTrue(root.hitTest(surface.convert(pinLocal, to: shell)) === pin, "pin button was intercepted")
    let event = try XCTUnwrap(NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: pin.convert(NSPoint(x: 8, y: 8), to: nil),
      modifierFlags: [],
      timestamp: 1,
      windowNumber: 0,
      context: nil,
      eventNumber: 1,
      clickCount: 2,
      pressure: 1
    ))
    pin.mouseDown(with: event)
    XCTAssertEqual(pinClicks, 1, "pin click did not reach the button")
    XCTAssertEqual(rowClicks, 0, "pin click bubbled into a row paste")

    surface.pinSlotWidth = 0
    XCTAssertTrue(root.hitTest(surface.convert(pinLocal, to: shell)) === surface, "hidden pin slot no longer selects the row")

    let slot = UUID().uuidString
    XCTAssertNotEqual(
      RowPinSlot.accessibilityIdentifier(slotID: slot),
      "lab-row-pin-\(slot)",
      "row pin button reused the menu item identifier"
    )
    XCTAssertFalse(RowPinSlot.shown(pinned: false, rowHovered: false))
    XCTAssertTrue(RowPinSlot.shown(pinned: false, rowHovered: true))
    XCTAssertTrue(RowPinSlot.shown(pinned: true, rowHovered: false))
    XCTAssertEqual(RowPinSlot.tint(pinned: true, selected: false), .controlAccentColor)
    XCTAssertEqual(RowPinSlot.tint(pinned: false, selected: false), .secondaryLabelColor)
  }

}
