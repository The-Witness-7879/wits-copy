import Foundation

/// 面板关闭与焦点策略。
/// 这些类型只描述"关闭面板时该做什么"，不持有窗口或状态；
/// AppState 和 FloatingPanel 读取它们做决定。

enum PanelDismissReason: Equatable, Sendable {
  case resignKey
  case externalClick
  case copyCommit
  /// Opening the item in its own app. Same contract as copying: an unpinned
  /// panel hides; a pinned panel stays.
  case externalHandoff
  case escape
  case explicit
  case settings
}


struct PanelFocusContext: Equatable, Sendable {
  var windowPinned = false
  var tagPopoverPresented = false
  var confirmationPresented = false
  /// An AppKit menu is tracking. Resigning key for that must not close the panel.
  var menuPresented = false
}


enum PanelCloseDecision: Equatable, Sendable {
  case close
  case stay
  /// Pinned panel stays up, but must drop below the settings window.
  case stayAndYieldToSettings
}


// INPUT-STABILITY-BEGIN
enum PopupHotkeyRoute {
  struct Decision: Equatable {
    var open = false
    var close = false
    var highlightNext = false
    var select = false
    var resetSelection = false
    var consume = false
  }

  /// One chord edge toggles visibility. It never cycles, selects, or pastes.
  static func firstDown(panelClosed: Bool) -> Decision {
    Decision(open: panelClosed, close: !panelClosed, consume: true)
  }

  /// Repeats and any other local delivery of the same chord are swallowed.
  /// The global shortcut owns the toggle, so this must not close or open again.
  static func localChord() -> Decision {
    Decision(consume: true)
  }

  /// Releasing modifiers does not accept the row and does not move the lead.
  static func modifiersReleased() -> Decision {
    Decision()
  }
}


enum PanelOutsideClick {
  /// Unpinned panel, click outside every window this app owns. Exceptions match resignKey.
  static func shouldDismiss(
    presented: Bool,
    insideOwnedWindow: Bool,
    windowPinned: Bool,
    tagPopover: Bool,
    confirmation: Bool,
    menu: Bool
  ) -> Bool {
    guard presented, !insideOwnedWindow else { return false }
    if tagPopover || confirmation || menu || windowPinned { return false }
    return true
  }
}


enum PanelBrowsingKeys {
  enum Delivery: Equatable {
    case pass
    case passToEditor
    case consumeCancel
    case consumeHide
  }

  /// One Esc is exactly one of these. Editor/IME owns the event, or the monitor
  /// cancels and swallows, or the monitor hides and swallows. Never both.
  static func delivery(
    isEscape: Bool,
    confirmationPresented: Bool,
    menuPresented: Bool,
    editorOwnsEscape: Bool,
    markedText: Bool,
    sessionActive: Bool,
    cancelArmed: Bool
  ) -> Delivery {
    guard isEscape else { return .pass }
    if confirmationPresented || menuPresented { return .pass }
    if markedText || editorOwnsEscape { return .passToEditor }
    if sessionActive && !cancelArmed { return .consumeCancel }
    return .consumeHide
  }

  static func consumes(_ delivery: Delivery) -> Bool {
    switch delivery {
    case .consumeCancel, .consumeHide: return true
    case .pass, .passToEditor: return false
    }
  }
}


/// Session-tap gate for a non-key browsing Esc. Does not create a tap, prompt,
/// or record keys. A key window is left to the local monitor so the same Esc
/// is not applied twice. Missing trust stays blocked instead of intercepting.
enum PanelEscapeTap {
  enum Gate: Equatable {
    case install
    case blockedUntrusted
    case skipped
  }

  static let escapeKeyCode: Int64 = 53

  static func gate(visible: Bool, trusted: Bool, unitTest: Bool, alreadyInstalled: Bool) -> Gate {
    if alreadyInstalled || !visible || unitTest { return .skipped }
    if !trusted { return .blockedUntrusted }
    return .install
  }

  /// Non-escape keys are not swallowed. A key panel is not swallowed here.
  static func shouldSwallow(keyCode: Int64, panelIsKey: Bool, delivery: PanelBrowsingKeys.Delivery) -> Bool {
    guard keyCode == escapeKeyCode, !panelIsKey else { return false }
    return PanelBrowsingKeys.consumes(delivery)
  }
}


enum PanelEscapeHandoff {
  static var editorOwnsCurrent = false
  static func beginEditorEscape() { editorOwnsCurrent = true }
  static func endEditorEscape() { editorOwnsCurrent = false }
}


enum PanelRootEscape {
  static func ignoresClose(editorOwnsCurrent: Bool = PanelEscapeHandoff.editorOwnsCurrent) -> Bool {
    editorOwnsCurrent
  }
}

// INPUT-STABILITY-END

enum PanelClosePolicy {
  static func decide(_ reason: PanelDismissReason, context: PanelFocusContext) -> PanelCloseDecision {
    switch reason {
    case .escape, .explicit:
      return .close
    case .settings:
      return context.windowPinned ? .stayAndYieldToSettings : .close
    case .resignKey, .externalClick:
      if context.tagPopoverPresented || context.confirmationPresented || context.menuPresented || context.windowPinned {
        return .stay
      }
      return .close
    case .copyCommit, .externalHandoff:
      return context.windowPinned ? .stay : .close
    }
  }

  static func clearsSearchAfterCopy(windowPinned: Bool) -> Bool {
    !windowPinned
  }

  /// Background of a still-presented pinned window must keep the query.
  static func clearsSearchOnBackground(windowPinned: Bool, panelPresented: Bool) -> Bool {
    !(windowPinned && panelPresented)
  }

  static func treatsResignAsBackground(windowPinned: Bool, panelPresented: Bool) -> Bool {
    !(windowPinned && panelPresented)
  }
}
