import SwiftUI

@Observable
class FooterItem: Equatable, Identifiable, HasVisibility {
  struct Confirmation {
    var message: LocalizedStringKey
    var comment: LocalizedStringKey
    var confirm: LocalizedStringKey
    var cancel: LocalizedStringKey
    var confirmHelp: LocalizedStringKey
    var cancelHelp: LocalizedStringKey
    var suppressHelp: LocalizedStringKey
    var messageKey: String
    var commentKey: String
    var confirmKey: String
    var cancelKey: String
    var confirmHelpKey: String
    var cancelHelpKey: String
    var suppressHelpKey: String

    init(
      message: String,
      comment: String,
      confirm: String,
      cancel: String,
      confirmHelp: String,
      cancelHelp: String,
      suppressHelp: String
    ) {
      self.message = LocalizedStringKey(message)
      self.comment = LocalizedStringKey(comment)
      self.confirm = LocalizedStringKey(confirm)
      self.cancel = LocalizedStringKey(cancel)
      self.confirmHelp = LocalizedStringKey(confirmHelp)
      self.cancelHelp = LocalizedStringKey(cancelHelp)
      self.suppressHelp = LocalizedStringKey(suppressHelp)
      messageKey = message
      commentKey = comment
      confirmKey = confirm
      cancelKey = cancel
      confirmHelpKey = confirmHelp
      cancelHelpKey = cancelHelp
      suppressHelpKey = suppressHelp
    }
  }

  static func == (lhs: FooterItem, rhs: FooterItem) -> Bool {
    return lhs.id == rhs.id
  }

  let id = UUID()

  var title: String
  var shortcuts: [KeyShortcut] = []
  var help: LocalizedStringKey?
  var isSelected: Bool = false
  var confirmation: Confirmation?
  var showConfirmation: Bool = false
  var suppressConfirmation: Binding<Bool>?
  var isVisible: Bool = true
  var action: () -> Void

  init(
    title: String,
    shortcuts: [KeyShortcut] = [],
    help: LocalizedStringKey? = nil,
    confirmation: Confirmation? = nil,
    suppressConfirmation: Binding<Bool>? = nil,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.shortcuts = shortcuts
    self.help = help
    self.confirmation = confirmation
    self.suppressConfirmation = suppressConfirmation
    self.action = action
  }
}
