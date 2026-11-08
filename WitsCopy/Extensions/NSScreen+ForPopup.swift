import AppKit.NSScreen
import CoreGraphics
import Defaults

extension NSScreen {
  /// 1-based popup screen. `0` or an out-of-range index is the active screen.
  /// Center and last-position keep this choice. Cursor, window, and status item pick their own screen.
  static func screen(forPopupIndex index: Int) -> NSScreen? {
    if index <= 0 || index > screens.count {
      return main
    }
    return screens[index - 1]
  }

  static var forPopup: NSScreen? {
    screen(forPopupIndex: Defaults[.popupScreen])
  }

  /// Ask the display itself, not `screens[0]` or `main`, which follow the menu bar.
  var isBuiltInDisplay: Bool {
    guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
      return false
    }
    return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
  }

  static var builtIn: NSScreen? {
    screens.first { $0.isBuiltInDisplay }
  }
}
