import AppKit
import SwiftUI
import Defaults

struct AppearanceSettingsPane: View {
  @Default(.popupPosition) private var popupAt
  @Default(.popupScreen) private var popupScreen
  @Default(.pinTo) private var pinTo
  @Default(.imageMaxHeight) private var imageHeight
  @Default(.highlightMatch) private var highlightMatch
  @Default(.menuIcon) private var menuIcon
  @Default(.showInStatusBar) private var showInStatusBar
  @Default(.windowPosition) private var windowPosition

  @State private var screens = NSScreen.screens

  private let imageHeightFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.minimum = 1
    formatter.maximum = 200
    return formatter
  }()

  var body: some View {
    SettingsLayout.form {
      // Where the panel appears.
      SettingsLayout.row("PopupAt", table: "AppearanceSettings") {
        HStack(spacing: 6) {
          Picker("", selection: $popupAt) {
            ForEach(PopupPosition.allCases) { position in
              Text(position.description).tag(position)
            }
          }
          .settingsPickerWidth()
          .help(Text("PopupAtTooltip", tableName: "AppearanceSettings"))

          if popupAt == .lastPosition {
            Button {
              _windowPosition.reset()
            } label: {
              Image(systemName: "arrow.uturn.backward.circle.fill")
                .imageScale(.large)
            }
            .buttonStyle(.borderless)
            .iconHelp(NSLocalizedString("PopupAtLastLocationReset", tableName: "AppearanceSettings", comment: ""))
            .disabled(windowPosition == _windowPosition.defaultValue)
          }
        }

        if showsScreenPicker {
          Picker("", selection: $popupScreen) {
            Text(labelForScreen(index: 0)).tag(0)
            ForEach(screens.indices, id: \.self) { index in
              Text(labelForScreen(index: index + 1)).tag(index + 1)
            }
          }
          .settingsPickerWidth()
        }
      }

      SettingsLayout.row("PinTo", table: "AppearanceSettings") {
        Picker("", selection: $pinTo) {
          ForEach(PinsPosition.allCases) { position in
            Text(position.description)
          }
        }
        .settingsPickerWidth()
        .help(Text("PinToTooltip", tableName: "AppearanceSettings"))
      }

      SettingsLayout.sectionBreak()

      // What the panel shows.
      SettingsLayout.row("Panel", table: "AppearanceSettings") {
        Defaults.Toggle(key: .openPreviewAutomatically) {
          Text("OpenPreviewAutomatically", tableName: "AppearanceSettings")
        }
        .help(Text("OpenPreviewAutomaticallyTooltip", tableName: "AppearanceSettings"))
        Defaults.Toggle(key: .showSearch) {
          Text("ShowSearchField", tableName: "AppearanceSettings")
        }
        Defaults.Toggle(key: .showApplicationIcons) {
          Text("ShowApplicationIcons", tableName: "AppearanceSettings")
        }
      }

      SettingsLayout.sectionBreak()

      // How each history item is drawn.
      SettingsLayout.row("HighlightMatches", table: "AppearanceSettings") {
        Picker("", selection: $highlightMatch) {
          ForEach(HighlightMatch.allCases) { match in
            Text(match.description)
          }
        }
        .settingsPickerWidth()
        .help(Text("HighlightMatchesTooltip", tableName: "AppearanceSettings"))
      }

      SettingsLayout.row("ImageHeight", table: "AppearanceSettings") {
        HStack(spacing: SettingsLayout.stepperSpacing) {
          SettingsNumberField(value: $imageHeight, formatter: imageHeightFormatter)
            .help(Text("ImageHeightTooltip", tableName: "AppearanceSettings"))
          HelpedStepper(
            value: $imageHeight,
            range: 1...200,
            help: NSLocalizedString(
              "ImageHeightStepperHelp",
              tableName: "AppearanceSettings",
              value: "Change the image preview height",
              comment: ""
            ),
            identifier: "lab-image-height-stepper"
          )
          .fixedSize()
        }
      }

      SettingsLayout.row("Items", table: "AppearanceSettings") {
        Defaults.Toggle(key: .showSpecialSymbols) {
          Text("ShowSpecialSymbols", tableName: "AppearanceSettings")
        }
        .help(Text("ShowSpecialSymbolsTooltip", tableName: "AppearanceSettings"))
        Defaults.Toggle(key: .showHexColorSwatch) {
          Text("ShowHexColorSwatch", tableName: "AppearanceSettings")
        }
        .help(Text("ShowHexColorSwatchTooltip", tableName: "AppearanceSettings"))
        Defaults.Toggle(key: .compactRows) {
          Text("CompactRows", tableName: "AppearanceSettings")
        }
      }

      SettingsLayout.sectionBreak()

      // The status bar item.
      SettingsLayout.row("MenuBar", table: "AppearanceSettings") {
        SettingsLayout.inlineCheckboxLine {
          Defaults.Toggle(key: .showInStatusBar) {
            Text("ShowMenuIcon", tableName: "AppearanceSettings")
          }
          Picker("", selection: $menuIcon) {
            ForEach(MenuIcon.allCases) { icon in
              Image(nsImage: icon.image)
            }
          }
          .labelsHidden()
          .controlSize(.small)
          .fixedSize()
          .disabled(!showInStatusBar)
        }
        SettingsLayout.dependent {
          Defaults.Toggle(key: .showRecentCopyInMenuBar) {
            Text("ShowRecentCopyInMenuBar", tableName: "AppearanceSettings")
          }
          .disabled(!showInStatusBar)
        }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
      screens = NSScreen.screens
    }
  }

  private var showsScreenPicker: Bool {
    screens.count > 1 && (popupAt == .center || popupAt == .lastPosition)
  }

  private func labelForScreen(index screenIndex: Int) -> String {
    switch screenIndex {
    case 0:
      return String(localized: "ActiveScreen", table: "AppearanceSettings")
    case _:
      return screens[screenIndex - 1].localizedName
    }
  }
}

#Preview {
  AppearanceSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
}
