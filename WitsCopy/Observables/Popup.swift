import AppKit.NSRunningApplication
import Defaults
import KeyboardShortcuts
import Observation

enum PopupChord {
  static func matches(_ event: NSEvent) -> Bool {
    guard let shortcut = KeyboardShortcuts.Name.popup.shortcut else { return false }
    guard shortcut.key?.rawValue == Int(event.keyCode) else { return false }
    return event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      == shortcut.modifiers.intersection(.deviceIndependentFlagsMask)
  }

  static func matchesKey(_ event: NSEvent) -> Bool {
    guard let shortcut = KeyboardShortcuts.Name.popup.shortcut else { return false }
    return shortcut.key?.rawValue == Int(event.keyCode)
  }
}

@Observable
class Popup {
  static let verticalSeparatorPadding = 6.0
  static let horizontalSeparatorPadding = 6.0
  static let horizontalPadding: CGFloat = 5

  // Radius used for items inset by the padding. Ensures they visually have the same curvature
  // as the menu.
  static let cornerRadius: CGFloat = if #available(macOS 26.0, *) {
    7
  } else {
    4
  }

  static let itemHeight: CGFloat = if #available(macOS 26.0, *) {
    24
  } else {
    22
  }

  var needsResize = false
  var height: CGFloat = 0
  var headerHeight: CGFloat = 0
  var extraTopHeight: CGFloat = 0
  var extraBottomHeight: CGFloat = 0
  var footerHeight: CGFloat = 0

  static let visualMinimumHeight: CGFloat = 500

  var minimumHeight: CGFloat {
    let rows = suitableHeight(for: 3 * Popup.itemHeight)
    let screen = NSScreen.forPopup?.visibleFrame.height ?? 900
    let floor = min(Self.visualMinimumHeight, max(280, screen - 48))
    return max(rows, floor)
  }

  private var eventsMonitor: Any?
  /// Carbon `kEventHotKeyPressed` is forwarded with no repeat filter. The menu-open
  /// raw-key path calls the same down handler and can repeat. Hold the edge until up.
  private var hotkeyHeld = false
  private(set) var registeredHotKeyToggles = 0

  init() {
    if !LabRuntime.isIsolated {
      KeyboardShortcuts.onKeyDown(for: .popup, action: deliverRegisteredHotKeyDown)
      KeyboardShortcuts.onKeyUp(for: .popup, action: deliverRegisteredHotKeyUp)
    }
    initEventsMonitor()
  }

  deinit {
    deinitEventsMonitor()
  }

  func initEventsMonitor() {
    guard eventsMonitor == nil else { return }

    self.eventsMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.flagsChanged, .keyDown],
      handler: handleEvent
    )
  }

  func deinitEventsMonitor() {
    guard let eventsMonitor else { return }

    NSEvent.removeMonitor(eventsMonitor)
  }

  func open(height: CGFloat, at popupPosition: PopupPosition = Defaults[.popupPosition]) {
    AppState.shared.appDelegate?.panel.open(height: height, at: popupPosition)
  }

  func reset() {
    KeyboardShortcuts.enable(.popup)
  }

  func close() {
    AppState.shared.panelPresented = false
    AppState.shared.appDelegate?.panel.close()
  }

  func isClosed() -> Bool {
    AppState.shared.appDelegate?.panel.isPresented != true
  }

  func preferredHeight(for newHeight: CGFloat) -> CGFloat {
    _ = newHeight
    let screen = NSScreen.forPopup?.visibleFrame.height ?? 900
    let saved = max(Defaults[.windowSize].height, Self.visualMinimumHeight)
    return min(saved, max(280, screen - 32))
  }

  private func suitableHeight(for historyListHeight: CGFloat) -> CGFloat {
    return historyListHeight + headerHeight + extraTopHeight + extraBottomHeight + footerHeight
  }

  func resize(height: CGFloat) {
    self.height = suitableHeight(for: height)
    AppState.shared.appDelegate?.panel.verticallyResize(to: preferredHeight(for: self.height))
    needsResize = false
  }

  /// Registered with `KeyboardShortcuts.onKeyDown`. A repeat while held does not toggle.
  func deliverRegisteredHotKeyDown() {
    if hotkeyHeld { return }
    hotkeyHeld = true
    registeredHotKeyToggles += 1
    let decision = PopupHotkeyRoute.firstDown(panelClosed: isClosed())
    if decision.open {
      open(height: height)
    } else if decision.close {
      close()
    }
  }

  /// Registered with `KeyboardShortcuts.onKeyUp`. Release does not select, paste, or reset.
  func deliverRegisteredHotKeyUp() {
    hotkeyHeld = false
    _ = PopupHotkeyRoute.modifiersReleased()
  }

  private func handleEvent(_ event: NSEvent) -> NSEvent? {
    switch event.type {
    case .keyDown:
      return handleKeyDown(event)
    case .flagsChanged:
      return handleFlagsChanged(event)
    default:
      return event
    }
  }

  private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
    if PopupChord.matches(event) {
      let decision = PopupHotkeyRoute.localChord()
      return decision.consume ? nil : event
    }

    if PopupChord.matchesKey(event), let item = History.shared.pressedShortcutItem {
      AppState.shared.navigator.select(item: item)
      let modifierFlags = NSEvent.ModifierFlags.currentModifierFlags
      Task { @MainActor in
        AppState.shared.history.select(item, flags: modifierFlags)
      }
      return nil
    }

    return event
  }

  private func handleFlagsChanged(_ event: NSEvent) -> NSEvent? {
    let decision = PopupHotkeyRoute.modifiersReleased()
    if decision.select || decision.resetSelection || decision.highlightNext || decision.close {
      return nil
    }
    return event
  }
}
