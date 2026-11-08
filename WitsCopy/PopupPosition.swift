import AppKit.NSEvent
import Defaults
import Foundation

struct PopupScreenBox: Equatable, Sendable {
  var frame: CGRect
  var visibleFrame: CGRect
}

/// Geometry needed to choose one screen and place the panel. Tests build this without a second display.
struct PopupPlacementContext: Equatable, Sendable {
  var screens: [PopupScreenBox]
  var mouseLocation: CGPoint
  /// 1-based index into `screens`. `0` or out of range means the active screen.
  var explicitScreen: Int
  var activeScreenIndex: Int
  var statusItemScreenIndex: Int?
  var statusItemFrame: CGRect?
  var frontmostWindowFrame: CGRect?
  var savedAnchor: CGPoint

  var resolvedExplicitIndex: Int {
    if explicitScreen > 0, screens.indices.contains(explicitScreen - 1) {
      return explicitScreen - 1
    }
    if screens.indices.contains(activeScreenIndex) {
      return activeScreenIndex
    }
    return screens.isEmpty ? 0 : 0
  }

  func screenIndex(containing point: CGPoint) -> Int? {
    screens.firstIndex { $0.frame.contains(point) }
  }

  func screenIndex(containing rect: CGRect) -> Int? {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    if let hit = screenIndex(containing: center) {
      return hit
    }
    return screens.indices.max { lhs, rhs in
      intersectionArea(screens[lhs].frame, rect) < intersectionArea(screens[rhs].frame, rect)
    }
  }

  private func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    let hit = lhs.intersection(rhs)
    guard !hit.isNull, !hit.isInfinite, hit.width > 0, hit.height > 0 else { return 0 }
    return hit.width * hit.height
  }
}

extension PopupPlacementContext {
  @MainActor
  static func live(statusBarButton: NSStatusBarButton?) -> PopupPlacementContext {
    let screens = NSScreen.screens.map {
      PopupScreenBox(frame: $0.frame, visibleFrame: $0.visibleFrame)
    }
    let active = NSScreen.screens.firstIndex { $0 == NSScreen.main } ?? 0
    var statusIndex: Int?
    var statusFrame: CGRect?
    if let button = statusBarButton, let window = button.window {
      statusIndex = NSScreen.screens.firstIndex { $0 == window.screen }
      let rectInWindow = button.convert(button.bounds, to: nil)
      statusFrame = window.convertToScreen(rectInWindow)
    }
    var mouseLocation = NSEvent.mouseLocation
    var explicitScreen = Defaults[.popupScreen]
    var activeIndex = active
    var frontmostWindow = NSWorkspace.shared.frontmostApplication?.windowFrame

    // Smoke runs never appear on the user's working display. Ask the display itself
    // rather than trusting `main` or `screens[0]`, which can be an external monitor.
    if LabRuntime.isSmoke,
       let builtIn = NSScreen.builtIn,
       let builtInIndex = NSScreen.screens.firstIndex(of: builtIn) {
      let center = CGPoint(x: builtIn.frame.midX, y: builtIn.frame.midY)
      mouseLocation = center
      explicitScreen = builtInIndex + 1
      activeIndex = builtInIndex
      statusIndex = builtInIndex
      statusFrame = nil
      frontmostWindow = builtIn.frame
    }

    return PopupPlacementContext(
      screens: screens,
      mouseLocation: mouseLocation,
      explicitScreen: explicitScreen,
      activeScreenIndex: activeIndex,
      statusItemScreenIndex: statusIndex,
      statusItemFrame: statusFrame,
      frontmostWindowFrame: frontmostWindow,
      savedAnchor: Defaults[.windowPosition]
    )
  }
}

enum PopupPosition: String, CaseIterable, Identifiable, CustomStringConvertible, Defaults.Serializable {
  case cursor
  case statusItem
  case window
  case center
  case lastPosition

  var id: Self { self }

  var description: String {
    switch self {
    case .cursor:
      return NSLocalizedString("PopupAtCursor", tableName: "AppearanceSettings", comment: "")
    case .statusItem:
      return NSLocalizedString("PopupAtMenuBarIcon", tableName: "AppearanceSettings", comment: "")
    case .window:
      return NSLocalizedString("PopupAtWindowCenter", tableName: "AppearanceSettings", comment: "")
    case .center:
      return NSLocalizedString("PopupAtScreenCenter", tableName: "AppearanceSettings", comment: "")
    case .lastPosition:
      return NSLocalizedString("PopupAtLastPosition", tableName: "AppearanceSettings", comment: "")
    }
  }

  func targetScreenIndex(in context: PopupPlacementContext) -> Int? {
    guard !context.screens.isEmpty else { return nil }
    switch self {
    case .center, .lastPosition:
      return context.resolvedExplicitIndex
    case .statusItem:
      if let index = context.statusItemScreenIndex, context.screens.indices.contains(index) {
        return index
      }
      return context.screenIndex(containing: context.mouseLocation) ?? context.resolvedExplicitIndex
    case .window:
      if let frame = context.frontmostWindowFrame, let index = context.screenIndex(containing: frame) {
        return index
      }
      return context.screenIndex(containing: context.mouseLocation) ?? context.resolvedExplicitIndex
    case .cursor:
      return context.screenIndex(containing: context.mouseLocation) ?? context.resolvedExplicitIndex
    }
  }

  func targetScreen(in context: PopupPlacementContext) -> PopupScreenBox? {
    guard let index = targetScreenIndex(in: context) else { return nil }
    return context.screens[index]
  }

  func placedFrame(size: CGSize, listWidth: CGFloat, in context: PopupPlacementContext) -> CGRect {
    let visible = targetScreen(in: context)?.visibleFrame
      ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    switch self {
    case .center:
      let origin = PanelSplit.centeredOrigin(of: size, in: visible)
      return PanelSplit.constrainedFrame(proposed: CGRect(origin: origin, size: size), in: visible)
    case .window:
      let anchorFrame = context.frontmostWindowFrame ?? visible
      let origin = PanelSplit.centeredOrigin(of: size, in: anchorFrame)
      return PanelSplit.constrainedFrame(proposed: CGRect(origin: origin, size: size), in: visible)
    case .statusItem:
      let origin: CGPoint
      if let button = context.statusItemFrame {
        origin = CGPoint(x: button.minX, y: button.minY - size.height)
      } else {
        origin = CGPoint(x: context.mouseLocation.x, y: context.mouseLocation.y - size.height)
      }
      return PanelSplit.constrainedFrame(proposed: CGRect(origin: origin, size: size), in: visible)
    case .lastPosition:
      return PanelSplit.constrainedFrame(
        size: size,
        listWidth: listWidth,
        relativeAnchor: context.savedAnchor,
        in: visible
      )
    case .cursor:
      let origin = CGPoint(x: context.mouseLocation.x, y: context.mouseLocation.y - size.height)
      return PanelSplit.constrainedFrame(proposed: CGRect(origin: origin, size: size), in: visible)
    }
  }

  /// Fit and place against the same screen. Explicit `popupScreen` still wins for center and last position.
  func layout(saved: PanelSplit, in context: PopupPlacementContext) -> (split: PanelSplit, frame: CGRect) {
    let visible = targetScreen(in: context)?.visibleFrame
      ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    let fitted = saved.fitted(availableWidth: visible.width, availableHeight: visible.height)
    let extra = AppState.shared.preview.railExtraWidth
    let frame = placedFrame(
      size: CGSize(width: fitted.totalWidth + extra, height: fitted.height),
      listWidth: fitted.listWidth + extra,
      in: context
    )
    return (fitted, frame)
  }

}
