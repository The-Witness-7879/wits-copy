import SwiftUI
import Defaults
import KeyboardShortcuts
import LaunchAtLogin

struct GeneralSettingsPane: View {
  private let notificationsURL = URL(
    string: "x-apple.systempreferences:com.apple.preference.notifications?id=\(Bundle.main.bundleIdentifier ?? "")"
  )

  @Default(.searchMode) private var searchMode

  @State private var copyModifier = HistoryItemAction.copy.modifierFlags.description
  @State private var pasteModifier = HistoryItemAction.paste.modifierFlags.description
  @State private var pasteWithoutFormatting = HistoryItemAction.pasteWithoutFormatting.modifierFlags.description

  var body: some View {
    SettingsLayout.form {
      SettingsLayout.group {
        SettingsLayout.inlineCheckboxLine {
          Toggle(isOn: Binding(
            get: { AppState.shared.softwareUpdater.automaticallyChecksForUpdates },
            set: { AppState.shared.softwareUpdater.setAutomaticallyChecksForUpdates($0) }
          )) {
            Text("CheckForUpdates", tableName: "GeneralSettings")
          }
          .help(Text("CheckForUpdatesTooltip", tableName: "GeneralSettings"))
          Button {
            AppState.shared.softwareUpdater.checkForUpdates()
          } label: {
            Text("CheckNow", tableName: "GeneralSettings")
          }
          // Small, so it overhangs the checkbox line by only 1.5pt each side.
          .controlSize(.small)
          .disabled(!AppState.shared.softwareUpdater.canCheckForUpdates)
          .help(Text("CheckNowTooltip", tableName: "GeneralSettings"))
        }
        LaunchAtLogin.Toggle {
          Text("LaunchAtLogin", tableName: "GeneralSettings")
        }
        .help(Text("LaunchAtLoginTooltip", tableName: "GeneralSettings"))
        Defaults.Toggle(key: .captureClipboard) {
          Text("RecordClipboard", tableName: "GeneralSettings")
        }
        .help(Text("RecordClipboardHelp", tableName: "GeneralSettings"))
      }

      SettingsLayout.sectionBreak()

      SettingsLayout.row("Open", table: "GeneralSettings") {
        SettingsShortcutRecorder(name: .popup, onChange: { newShortcut in
          if newShortcut == nil {
            // No shortcut is recorded. Remove keys monitor
            AppState.shared.popup.deinitEventsMonitor()
          } else {
            // User is using shortcut. Ensure keys monitor is initialized
            AppState.shared.popup.initEventsMonitor()
          }
        })
          .help(Text("OpenTooltip", tableName: "GeneralSettings"))
      }

      SettingsLayout.row("Search", table: "GeneralSettings") {
        Picker("", selection: $searchMode) {
          ForEach(Search.Mode.allCases) { mode in
            Text(mode.description)
          }
        }
        .settingsPickerWidth()
        .help(Text("SearchModeTooltip", tableName: "GeneralSettings"))
      }

      SettingsLayout.sectionBreak()

      SettingsLayout.row("Behavior", table: "GeneralSettings") {
        Defaults.Toggle(key: .pasteByDefault) {
          Text("PasteAutomatically", tableName: "GeneralSettings")
        }
        .onChange(refreshModifiers)
        .help(Text("PasteAutomaticallyTooltip", tableName: "GeneralSettings"))
        .fixedSize()

        Defaults.Toggle(key: .removeFormattingByDefault) {
          Text("PasteWithoutFormatting", tableName: "GeneralSettings")
        }
        .onChange(refreshModifiers)
        .help(Text("PasteWithoutFormattingTooltip", tableName: "GeneralSettings"))
        .fixedSize()

        SettingsLayout.formattedDescription("Modifiers", table: "GeneralSettings", copyModifier, pasteModifier, pasteWithoutFormatting)
      }

      SettingsLayout.sectionBreak()

      SettingsLayout.group {
        if let notificationsURL = notificationsURL {
          Link(destination: notificationsURL, label: {
            Text("NotificationsAndSounds", tableName: "GeneralSettings")
          })
          .help(Text("NotificationsAndSoundsTooltip", tableName: "GeneralSettings"))
        }
      }
    }
  }

  private func refreshModifiers(_ sender: Sendable) {
    copyModifier = HistoryItemAction.copy.modifierFlags.description
    pasteModifier = HistoryItemAction.paste.modifierFlags.description
    pasteWithoutFormatting = HistoryItemAction.pasteWithoutFormatting.modifierFlags.description
  }
}

#Preview {
  GeneralSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
}
