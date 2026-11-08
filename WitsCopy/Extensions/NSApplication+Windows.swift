import AppKit

extension NSApplication {
  /// A dismissed panel can remain in `windows` after `orderOut`. Only a visible panel is a live confirmation.
  var alertWindow: NSWindow? {
    windows.first { $0.className == "_NSAlertPanel" && $0.isVisible }
  }
  var characterPickerWindow: NSWindow? { windows.first { $0.className == "NSPanelViewBridge" } }
}
