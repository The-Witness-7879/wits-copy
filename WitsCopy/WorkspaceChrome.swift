import Foundation

/// 界面图标、帮助文案与尺寸常量。
/// 集中放置纯展示层常量，避免散落到各视图。


/// Workspace policy that does not own a window. AppState publishes the live values.

enum WorkspaceSymbols {
  static let windowPin = "macwindow"
  static let itemPin = "pin"
  static let itemPinFilled = "pin.fill"
  static let itemUnpin = "pin.slash"
  static let pinManagement = "bookmark.square"
}


enum WorkspaceHelp {
  static func windowPin(on: Bool) -> String { on ? "window_pin_help_on" : "window_pin_help_off" }
  static func pinManagement(selected: Bool) -> String { selected ? "nav_pins_help_on" : "nav_pins_help_off" }
  static func rail(expanded: Bool) -> String { expanded ? "nav_rail_help_narrow" : "nav_rail_help_expand" }
  static func preview(open: Bool) -> String { open ? "preview_help_hide" : "preview_help_show" }
}


/// Where the single tag editor is anchored. Row and preview must not share a host.
enum TagEditorAnchor: String, Equatable, Sendable {
  case row
  case preview
}


enum ListToolbarLayout {
  /// Nil means the preview column is absent, so the toolbar may fill the row.
  /// A value is the list column only — never list width plus preview width.
  static func constrainedWidth(listWidth: CGFloat, previewColumnVisible: Bool) -> CGFloat? {
    previewColumnVisible ? listWidth : nil
  }

  static let minimumSearchWidth: CGFloat = 56

  /// Narrowest list column. Stays at the legacy 320 default so a stored width
  /// is not rewritten up to the wider fresh-install default. Header fixed
  /// content is about 235pt, leaving room for the search field. The preview
  /// column is what compresses, never the toolbar.
  static let minimumContentWidth: CGFloat = 320
}


/// Shared whitespace for the list column. Scroll indicators get their own lane,
/// and neither the search field nor the last row touches the panel edge.
enum WorkspaceInsets {
  /// Outer margin of the panel. The close button sits 8pt from the top and left
  /// edges; the search field top, the rail's left edge and the gaps that face
  /// them (search → first row, rail row → list row) all use the same value.
  static let outer: CGFloat = 8
  /// Height of the search/tool row (24pt buttons). The close button is centred on it.
  static let toolBand: CGFloat = 24
  /// The search field draws 0.5pt inside the 24pt tool band, so a 7.5pt band
  /// offset puts its visible top exactly `outer` below the panel edge.
  static let headerTop: CGFloat = outer - 0.5
  /// Below the band: together with `columnTop` the first row starts `outer`
  /// below the search field's visible bottom.
  static let headerBottom: CGFloat = outer - 0.5 - columnTop
  /// Both columns start this far below the header.
  static let columnTop: CGFloat = 6
  /// Both columns keep this much space between their content and the panel bottom.
  static let columnBottom: CGFloat = 10
  /// Outer gutter between the list column and the panel frame.
  static let listOuter: CGFloat = 6
  /// Inner list buffer; together with listOuter it matches columnBottom exactly.
  static var listBottom: CGFloat { columnBottom - listOuter }
  /// Compact scroller lane: 6pt between row icons and the knob, none outside it.
  static let listTrailing: CGFloat = 13
  /// Overlay scrollers keep a built-in 3pt trailing margin; cancel it so the knob
  /// sits flush against the list/preview divider instead of floating in a gap.
  static let scrollerFlushOffset: CGFloat = 3
}


struct WorkspaceChrome: Equatable, Sendable {
  static func railWidth(expanded: Bool) -> CGFloat {
    guard expanded else { return PanelSplit.navigationRailWidth }
    return AppState.shared.effectiveRailWidth
  }
}
