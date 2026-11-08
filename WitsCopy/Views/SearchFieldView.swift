import Defaults
import SwiftUI

struct SearchFieldView: View {
  var placeholder: LocalizedStringKey
  @Binding var query: String

  @Environment(AppState.self) private var appState
  @Default(.searchMode) private var searchMode

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: Popup.cornerRadius, style: .continuous)
        .fill(Color.secondary)
        .opacity(0.1)
        .frame(height: 23)

      HStack {
        Image(systemName: "magnifyingglass")
          .frame(width: 11, height: 11)
          .padding(.leading, 5)
          .opacity(0.8)

        TextField(placeholder, text: $query)
          .disableAutocorrection(true)
          .lineLimit(1)
          .textFieldStyle(.plain)
          .accessibilityIdentifier("lab-search-field")
          .onSubmit {
            appState.select(flags: .currentModifierFlags)
          }

        if Self.showsInvalidRegexp(mode: searchMode, query: query) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .frame(width: 11, height: 11)
            .accessibilityHidden(true)
            .overlay(InvalidRegexpMark().frame(width: 11, height: 11).allowsHitTesting(false))
        }

        if !query.isEmpty {
          Button {
            query = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
              .frame(width: 11, height: 11)
              .padding(.trailing, 5)
          }
          .buttonStyle(.plain)
          .opacity(0.9)
          .accessibilityIdentifier("lab-search-clear")
          .iconHelp(NSLocalizedString("search_clear_help", value: "Clear search", comment: ""))
        }
      }
    }
  }

  /// Visible only for a non-empty regexp query that ICU rejects. Mixed is not a terminal error.
  static func showsInvalidRegexp(mode: Search.Mode, query: String) -> Bool {
    guard mode == .regexp, !query.isEmpty else { return false }
    return (try? NSRegularExpression(pattern: query)) == nil
  }
}

/// SwiftUI `.help` / `.accessibilityIdentifier` do not land on an AppKit view in the sealed host.
/// The visible symbol stays the image; this overlay is the accessible mark.
private struct InvalidRegexpMark: NSViewRepresentable {
  func makeNSView(context: Context) -> InvalidRegexpMarkView {
    let view = InvalidRegexpMarkView(frame: NSRect(x: 0, y: 0, width: 11, height: 11))
    apply(view)
    return view
  }

  func updateNSView(_ view: InvalidRegexpMarkView, context: Context) {
    apply(view)
  }

  private func apply(_ view: InvalidRegexpMarkView) {
    let text = NSLocalizedString("search_invalid_regex", comment: "")
    view.setAccessibilityElement(true)
    view.setAccessibilityIdentifier("lab-search-invalid-regex")
    view.setAccessibilityLabel(text)
    view.setAccessibilityHelp(text)
    view.toolTip = text
  }
}

private final class InvalidRegexpMarkView: NSView {
  override var isOpaque: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

#Preview {
  return List {
    SearchFieldView(placeholder: "search_placeholder", query: .constant(""))
    SearchFieldView(placeholder: "search_placeholder", query: .constant("search"))
  }
  .frame(width: 300)
  .environment(\.locale, .init(identifier: "en"))
}
