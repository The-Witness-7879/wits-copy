import Defaults
import SwiftUI

@Observable
class Footer: ItemsContainer {
  var items: [FooterItem] = []

  var selectedItem: FooterItem? {
    willSet {
      selectedItem?.isSelected = false
      newValue?.isSelected = true
    }
  }

  var suppressClearAlert = Binding<Bool>(
    get: { Defaults[.suppressClearAlert] },
    set: { Defaults[.suppressClearAlert] = $0 }
  )

  var suppressQuitAlert = Binding<Bool>(
    get: { Defaults[.suppressQuitAlert] },
    set: { Defaults[.suppressQuitAlert] = $0 }
  )

  var containerVisible: Bool { true }

  init() { // swiftlint:disable:this function_body_length
    items = [
      FooterItem(
        title: "clear_all",
        shortcuts: [KeyShortcut(key: .delete, modifierFlags: [.command, .option, .shift])],
        help: "clear_all_tooltip",
        confirmation: .init(
          message: "clear_all_alert_message",
          comment: "clear_all_alert_comment",
          confirm: "clear_alert_confirm",
          cancel: "clear_alert_cancel",
          confirmHelp: "clear_alert_confirm_help",
          cancelHelp: "clear_alert_cancel_help",
          suppressHelp: "clear_alert_suppress_help"
        ),
        suppressConfirmation: suppressClearAlert
      ) {
        Task { @MainActor in
          AppState.shared.history.clearAll()
        }
      },
      FooterItem(
        title: "preferences",
        shortcuts: [KeyShortcut(key: .comma)]
      ) {
        Task { @MainActor in
          AppState.shared.openPreferences()
        }
      },
      FooterItem(
        title: "about",
        help: "about_tooltip"
      ) {
        AppState.shared.openAbout()
      },
      FooterItem(
        title: "quit",
        shortcuts: [KeyShortcut(key: .q)],
        help: "quit_tooltip",
        confirmation: .init(
          message: "quit_alert_message",
          comment: "quit_alert_comment",
          confirm: "quit",
          cancel: "clear_alert_cancel",
          confirmHelp: "quit_alert_confirm_help",
          cancelHelp: "quit_alert_cancel_help",
          suppressHelp: "quit_alert_suppress_help"
        ),
        suppressConfirmation: suppressQuitAlert
      ) {
        AppState.shared.commitQuit()
      }
    ]
  }
}
