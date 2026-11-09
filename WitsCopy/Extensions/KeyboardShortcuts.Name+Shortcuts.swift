import KeyboardShortcuts

extension KeyboardShortcuts.Name {
  static let popup = Self("popup", default: Shortcut(.v, modifiers: [.command, .shift, .option]))
  static let pin = Self("pin", default: Shortcut(.p, modifiers: [.option]))
  static let tag = Self("tag", default: Shortcut(.t, modifiers: [.option]))
  static let delete = Self("delete", default: Shortcut(.delete, modifiers: [.option]))
  /// No default. ⌃Space is the system input-source switch, so it never reached
  /// the panel; the preview opens and closes from its toolbar button.
  static let togglePreview = Self("togglePreview")
}
