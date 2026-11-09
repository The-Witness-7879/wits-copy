import Sauce
import Defaults
import SwiftUI

struct KeyHandlingView<Content: View>: View {
  @Binding var searchQuery: String
  @FocusState.Binding var searchFocused: Bool
  @ViewBuilder let content: () -> Content

  @Environment(AppState.self) private var appState

  var body: some View {
    content()
      .onKeyPress { _ in
        // Unfortunately, key presses don't allow access to
        // key code and don't properly work with multiple inputs,
        // so pressing ⌘, on non-English layout doesn't open
        // preferences. Stick to NSEvent to fix this behavior.

        if searchFocused {
          // Ignore input when candidate window is open
          // https://stackoverflow.com/questions/73677444/how-to-detect-the-candidate-window-when-using-japanese-keyboard
          if let inputClient = NSApp.keyWindow?.firstResponder as? NSTextInputClient,
             inputClient.hasMarkedText() {
            return .ignored
          }
        }

        if appState.tagEditorItem != nil {
          return .ignored
        }

        if appState.pinRecordingItemID != nil,
           let recorder = NSApp.keyWindow?.firstResponder as? PinnedShortcutRecorder,
           recorder.recording {
          return .ignored
        }

        if PanelKeyPolicy.defersToLocalEditor(NSApp.keyWindow?.firstResponder) {
          return .ignored
        }

        // A bare Space used to toggle the preview column. It collapsed the
        // column holding keyboard focus, so the next Space reached nothing and
        // never reopened it. The preview is toggled by its toolbar button only;
        // Space plays or pauses the selected video or audio.
        if !searchFocused,
           let playback = MediaPlayback.current,
           let event = NSApp.currentEvent,
           event.type == .keyDown,
           Sauce.shared.key(for: Int(event.keyCode)) == .space,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
          playback.toggle()
          return .handled
        }

        if searchFocused,
           let event = NSApp.currentEvent,
           PanelKeyPolicy.isNativeTextEdit(event) {
          return .ignored
        }

        if let event = NSApp.currentEvent, PopupChord.matches(event) {
          return .handled
        }

        if let item = appState.history.pressedShortcutItem {
          appState.navigator.select(item: item)
          Task {
            try? await Task.sleep(for: .milliseconds(50))
            appState.history.select(item, flags: .currentModifierFlags)
          }
          return .handled
        }

        switch KeyChord(NSApp.currentEvent) {
        case .clearHistory:
          if let item = appState.footer.items.first(where: { $0.title == "clear" }),
             item.confirmation != nil {
            appState.presentFooterConfirmation(item)
            return .handled
          } else {
            return .ignored
          }
        case .clearHistoryAll:
          if let item = appState.footer.items.first(where: { $0.title == "clear_all" }),
             item.confirmation != nil {
            appState.presentFooterConfirmation(item)
            return .handled
          } else {
            return .ignored
          }
        case .clearSearch:
          searchQuery = ""
          return .handled
        case .deleteCurrentItem:
          if appState.navigator.pasteStackSelected {
            appState.removePasteStack()
          } else {
            appState.deleteSelection()
          }
          return .handled
        case .deleteOneCharFromSearch:
          searchFocused = true
          _ = searchQuery.popLast()
          return .handled
        case .deleteLastWordFromSearch:
          searchFocused = true
          let newQuery = searchQuery.split(separator: " ").dropLast().joined(separator: " ")
          if newQuery.isEmpty {
            searchQuery = ""
          } else {
            searchQuery = "\(newQuery) "
          }

          return .handled
        case .moveToNext:
          guard NSApp.characterPickerWindow == nil else {
            return .ignored
          }

          appState.navigator.highlightNext()
          return .handled
        case .moveToLast:
          guard NSApp.characterPickerWindow == nil else {
            return .ignored
          }

          appState.navigator.highlightLast()
          return .handled
        case .moveToPrevious:
          guard NSApp.characterPickerWindow == nil else {
            return .ignored
          }

          appState.navigator.highlightPrevious()
          return .handled
        case .moveToFirst:
          guard NSApp.characterPickerWindow == nil else {
            return .ignored
          }

          appState.navigator.highlightFirst()
          return .handled
        case .extendToNext:
          guard NSApp.characterPickerWindow == nil else {
            return .ignored
          }
          guard AppState.shared.multiSelectionEnabled else {
            return .ignored
          }
          appState.navigator.extendHighlightToNext()
          return .handled
        case .extendToLast:
          guard NSApp.characterPickerWindow == nil else {
            return .ignored
          }
          guard AppState.shared.multiSelectionEnabled else {
            return .ignored
          }
          appState.navigator.extendHighlightToLast()
          return .handled
        case .extendToPrevious:
          guard NSApp.characterPickerWindow == nil else {
            return .ignored
          }
          guard AppState.shared.multiSelectionEnabled else {
            return .ignored
          }
          appState.navigator.extendHighlightToPrevious()
          return .handled
        case .extendToFirst:
          guard NSApp.characterPickerWindow == nil else {
            return .ignored
          }
          guard AppState.shared.multiSelectionEnabled else {
            return .ignored
          }
          appState.navigator.extendHighlightToFirst()
          return .handled
        case .openPreferences:
          appState.openPreferences()
          return .handled
        case .pinOrUnpin:
          appState.togglePin()
          return .handled
        case .tagOrUntag:
          appState.beginTagEdit()
          return .handled
        case .selectCurrentItem:
          appState.select(flags: .currentModifierFlags)
          return .handled
        case .close:
          if PanelRootEscape.ignoresClose() { return .ignored }
          appState.popup.close()
          return .handled
        case .quit:
          appState.quit()
          return .handled
        case .togglePreview:
          appState.preview.togglePreview()
          return .handled
        default:
          ()
        }

        return .ignored
      }
  }
}

enum PanelKeyPolicy {
  @MainActor
  static func defersToLocalEditor(_ responder: NSResponder?) -> Bool {
    if WorkspaceTagNameField.owns(responder) { return true }
    if responder is RichTextBodyView { return true }
    if let recorder = responder as? PinnedShortcutRecorder, recorder.recording { return true }
    if responder is OriginalTextBodyView { return true }
    return false
  }

  static func isSearchFieldEditor(_ responder: NSResponder?) -> Bool {
    guard let editor = responder as? NSTextView, editor.isFieldEditor else { return false }
    return true
  }

  static func isNativeTextEdit(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags == .command || flags == [.command, .shift] else { return false }
    switch event.keyCode {
    case 0, 8, 9, 7, 6:
      return true
    default:
      return false
    }
  }
}

enum PanelPinRoute {
  @MainActor
  static func consume(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown else { return false }
    if PopupChord.matches(event) { return true }
    let flags = event.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting([.capsLock, .numericPad, .function])
    guard HistoryItemAction(flags) != .unknown else { return false }
    let key = Sauce.shared.key(for: Int(event.keyCode))
    guard let item = History.shared.items.first(where: { decorator in
      !decorator.isRemoved && decorator.shortcuts.contains(where: { $0.key == key })
    }) else { return false }
    AppState.shared.navigator.select(item: item)
    AppState.shared.history.select(item, flags: flags)
    return true
  }
}
