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

  /// The name the Accessibility list shows for this build.
  ///
  /// The list is keyed by the *executable* name, and several builds can share it:
  /// a lab copy and the installed copy both show up as "WitsCopy". Reading the name
  /// from the bundle keeps the prompt honest instead of naming a build the user
  /// may not be running.
  static var listedExecutableName: String {
    (Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String)
      ?? ProcessInfo.processInfo.processName
  }

  /// Display name, falling back to the executable name.
  static var displayName: String {
    if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
       !name.isEmpty {
      return name
    }
    if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
       !name.isEmpty {
      return name
    }
    return listedExecutableName
  }

  /// Full bundle path, so a same-named entry in the list can be told apart.
  static var bundlePath: String {
    Bundle.main.bundlePath
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
      let detail = String(
        format: NSLocalizedString("paste_permission_alert_detail", comment: ""),
        Accessibility.listedExecutableName,
        Accessibility.bundlePath
      )
      message = String(
        format: NSLocalizedString("paste_permission_alert_body", comment: ""),
        Accessibility.displayName,
        detail
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
