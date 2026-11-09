import KeyboardShortcuts
import SwiftUI

/// Every settings page is one two-column Grid, laid out like a classic macOS
/// preferences form: labels are right-aligned in their own column, and every
/// control — labeled or not — starts on the same x in the control column.
/// Grid rows align on the first text baseline, so a label sits on the line of
/// the control it names. Groups are separated by space, not decorative lines.
/// Panes own only their controls and behavior, not fonts, columns or spacing.
enum SettingsLayout {
  static let labelFont = Font.system(size: 13)
  static let descriptionFont = Font.caption
  /// Minimum label column; a longer translation widens it instead of wrapping.
  static let labelWidth = SettingsMetrics.labelWidth
  /// Minimum control column, so short pages keep the same x as long ones.
  static let contentWidth = SettingsMetrics.controlWidth
  static let columnSpacing: CGFloat = 8
  static let pageHorizontalPadding: CGFloat = 30
  static let pageVerticalPadding: CGFloat = 20
  /// Space between rows inside one group.
  static let rowSpacing: CGFloat = 12
  /// Space between stacked controls inside one row.
  static let controlSpacing: CGFloat = 6
  /// Height of every single-line control (pop-up, stepper, number field,
  /// shortcut recorder). Fields used to be 22pt beside 24pt pop-ups and
  /// steppers, so gaps around them came out 1–2pt larger.
  static let controlHeight: CGFloat = 24
  /// Layout height of one checkbox line.
  static let checkboxLineHeight: CGFloat = 16
  /// Every pop-up menu in the settings window shares this width so their right
  /// edges line up instead of following each selection's text.
  static let pickerWidth: CGFloat = 160
  /// Numeric fields hold at most three digits; the stepper sits right next to them.
  static let numberFieldWidth: CGFloat = 56
  static let stepperSpacing: CGFloat = 4
  /// A dependent option sits under its parent, indented by one checkbox width.
  static let dependentIndent: CGFloat = 20

  /// The page's form. The grid is centered as one block inside the page.
  static func form<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    Grid(alignment: .leading, horizontalSpacing: columnSpacing, verticalSpacing: rowSpacing) {
      content()
    }
    .frame(maxWidth: .infinity, alignment: .top)
  }

  /// A labeled row. `alignment` stays on the first text baseline unless the
  /// first control has no text (a list, an image), where `.top` reads better.
  static func row<Content: View>(
    _ key: String,
    table: String,
    alignment: VerticalAlignment = .firstTextBaseline,
    @ViewBuilder content: () -> Content
  ) -> some View {
    GridRow(alignment: alignment) {
      Text(LocalizedStringKey(key), tableName: table)
        .font(labelFont)
        .fixedSize()
        .frame(minWidth: labelWidth, alignment: .trailing)
        .gridColumnAlignment(.trailing)
        .accessibilityIdentifier("settings-row-label")
      controls(content)
    }
  }

  /// Controls without a label of their own. They live in the control column,
  /// on the same x as every labeled control above and below them.
  static func group<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    GridRow(alignment: .top) {
      Color.clear
        .frame(width: 0, height: 0)
        .gridCellUnsizedAxes([.horizontal, .vertical])
      controls(content)
    }
  }

  /// Ends one group and starts the next. The empty row adds one more
  /// `rowSpacing`, so groups sit twice as far apart as rows within a group.
  static func sectionBreak() -> some View {
    Color.clear
      .frame(height: 0)
      .gridCellUnsizedAxes(.horizontal)
      .gridCellColumns(2)
      .accessibilityHidden(true)
  }

  /// A checkbox or control that only matters while its parent is on.
  static func dependent<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content().padding(.leading, dependentIndent)
  }

  /// A checkbox with a button or pop-up beside it. The line keeps a checkbox's
  /// layout height and lets the taller control overhang equally above and
  /// below, so the checkboxes in a stack stay on one pitch.
  static func inlineCheckboxLine<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    HStack(spacing: 8) { content() }
      .frame(height: checkboxLineHeight, alignment: .leading)
  }

  /// Secondary text under a control. `underCheckbox` lines it up with the
  /// checkbox title instead of the box, as macOS does for a single checkbox.
  static func description(_ key: String, table: String, underCheckbox: Bool = false) -> some View {
    Text(LocalizedStringKey(key), tableName: table)
      .font(descriptionFont)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(width: underCheckbox ? contentWidth - dependentIndent : contentWidth, alignment: .leading)
      .padding(.leading, underCheckbox ? dependentIndent : 0)
  }

  static func formattedDescription(
    _ key: String,
    table: String,
    _ arguments: CVarArg...
  ) -> some View {
    Text(String(format: NSLocalizedString(key, tableName: table, comment: ""), arguments: arguments))
      .font(descriptionFont)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(width: contentWidth, alignment: .leading)
  }

  private static func controls<Content: View>(_ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: controlSpacing) { content() }
      .frame(minWidth: contentWidth, alignment: .leading)
  }
}

extension View {
  /// Pop-up menus hug their selected title by default, so pickers in one
  /// column end at different x. Give them one shared width; on macOS 26 and
  /// later the menu button must also opt into flexible sizing to fill it.
  @ViewBuilder
  func settingsPickerWidth() -> some View {
    if #available(macOS 26, *) {
      self.labelsHidden()
        .buttonSizing(.flexible)
        .frame(width: SettingsLayout.pickerWidth, alignment: .leading)
    } else {
      self.labelsHidden()
        .frame(width: SettingsLayout.pickerWidth, alignment: .leading)
    }
  }
}

// MARK: - Fields on glass (skin lives in GlassField, Views/VisualEffectView.swift)

/// Three-digit numeric field used next to a stepper.
struct SettingsNumberField: View {
  @Binding var value: Int
  let formatter: NumberFormatter

  var body: some View {
    TextField("", value: $value, formatter: formatter)
      .multilineTextAlignment(.trailing)
      .textFieldStyle(.plain)
      .padding(.horizontal, GlassField.horizontalPadding)
      .frame(width: SettingsLayout.numberFieldWidth, height: SettingsLayout.controlHeight)
      .glassFieldChrome()
  }
}

/// KeyboardShortcuts' recorder is an NSSearchField whose bezel paints the same
/// opaque box. Host the same recorder with its bezel and background turned
/// off, inside the shared field skin. Recording behavior is unchanged.
struct SettingsShortcutRecorder: View {
  let name: KeyboardShortcuts.Name
  var onChange: ((KeyboardShortcuts.Shortcut?) -> Void)?

  var body: some View {
    Representable(name: name, onChange: onChange)
      .frame(width: 140, height: SettingsLayout.controlHeight)
      .glassFieldChrome()
  }

  private struct Representable: NSViewRepresentable {
    let name: KeyboardShortcuts.Name
    let onChange: ((KeyboardShortcuts.Shortcut?) -> Void)?

    func makeNSView(context: Context) -> KeyboardShortcuts.RecorderCocoa {
      let recorder = KeyboardShortcuts.RecorderCocoa(for: name, onChange: onChange)
      recorder.isBezeled = false
      recorder.isBordered = false
      recorder.drawsBackground = false
      recorder.backgroundColor = .clear
      recorder.focusRingType = .none
      return recorder
    }

    func updateNSView(_ recorder: KeyboardShortcuts.RecorderCocoa, context: Context) {
      recorder.shortcutName = name
    }
  }
}
