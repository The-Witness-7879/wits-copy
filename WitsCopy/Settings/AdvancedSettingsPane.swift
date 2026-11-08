import SwiftUI
import Defaults

struct AdvancedSettingsPane: View {
  var body: some View {
    SettingsLayout.form {
      // Shared metrics fix the column even on this single-section page.
      SettingsLayout.row("Clearing", table: "AdvancedSettings") {
        Defaults.Toggle(key: .clearOnQuit) {
          Text("ClearHistoryOnQuit", tableName: "AdvancedSettings")
        }.help(Text("ClearHistoryOnQuitTooltip", tableName: "AdvancedSettings"))

        Defaults.Toggle(key: .clearSystemClipboard) {
          Text("ClearSystemClipboard", tableName: "AdvancedSettings")
        }.help(Text("ClearSystemClipboardTooltip", tableName: "AdvancedSettings"))
      }
    }
  }
}

#Preview {
  AdvancedSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
}
