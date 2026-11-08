import KeyboardShortcuts

extension KeyboardShortcuts.Name {
  static let popup = Self("popup", default: Shortcut(.v, modifiers: [.command, .shift, .option]))
  static let pin = Self("pin", default: Shortcut(.p, modifiers: [.option]))
  static let tag = Self("tag", default: Shortcut(.t, modifiers: [.option]))
  static let delete = Self("delete", default: Shortcut(.delete, modifiers: [.option]))
  static let togglePreview = Self("togglePreview", default: Shortcut(.space, modifiers: [.control]))
}
