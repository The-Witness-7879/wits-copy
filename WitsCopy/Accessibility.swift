import AppKit
import ApplicationServices

struct Accessibility {
  /// Passed to `AXIsProcessTrustedWithOptions`. Nil does not show the system prompt.
  /// Do not replace this with a dictionary containing `kAXTrustedCheckOptionPrompt`.
  static let promptOptions: CFDictionary? = nil

  /// Test seam. Production reads the trust bit and never prompts.
  static var trustProbe: (() -> Bool)?

  static var isTrusted: Bool {
    if let trustProbe { return trustProbe() }
    return AXIsProcessTrustedWithOptions(promptOptions)
  }

  /// Registers this app with the system and lets macOS show its own prompt.
  ///
  /// This has to run *before* opening the settings pane. An app that has never
  /// asked does not appear in the Accessibility list, so sending the user there
  /// would land them on a pane where they cannot find it.
  @discardableResult
  static func requestSystemAuthorization() -> Bool {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
    return AXIsProcessTrustedWithOptions(options as CFDictionary)
  }

  /// Deep link straight to the Accessibility pane.
  static var systemSettingsURL: URL? {
    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
  }

  /// The name shown in the Accessibility list.
  static var displayName: String {
    for key in ["CFBundleDisplayName", "CFBundleName"] {
      if let name = Bundle.main.object(forInfoDictionaryKey: key) as? String, !name.isEmpty {
        return name
      }
    }
    return ProcessInfo.processInfo.processName
  }

  /// Ask the system first, then land the user on the exact switch to flip.
  static func openSystemSettings() {
    _ = requestSystemAuthorization()
    if let url = systemSettingsURL {
      NSWorkspace.shared.open(url)
    }
  }
}

/// Title and message for the alert shown when a double-click cannot paste.
struct PasteFailureCopy: Equatable {
  let title: String
  let message: String

  init(_ failure: ExplicitPasteFailure) {
    switch failure {
    case .accessibilityDenied:
      title = NSLocalizedString("paste_accessibility_denied", comment: "")
      message = String(
        format: NSLocalizedString("paste_permission_alert_body", comment: ""),
        Accessibility.displayName
      )
    case .noTarget:
      title = NSLocalizedString("paste_no_target", comment: "")
      message = NSLocalizedString("paste_no_target_body", comment: "")
    case .targetInvalid:
      title = NSLocalizedString("paste_target_invalid", comment: "")
      message = NSLocalizedString("paste_target_invalid_body", comment: "")
    }
  }
}
