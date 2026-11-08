import SwiftUI

struct HeaderView: View {
  @State private var appState = AppState.shared

  let controller: SlideoutController
  @FocusState.Binding var searchFocused: Bool

  var body: some View {
    HStack(alignment: .center, spacing: 2) {
      // 交通灯占窄档那一截。左栏展开的宽度在下面那一列，
      // 不要再在搜索框前面垫一段空白。
      Color.clear
        .frame(width: PanelSplit.trafficLightReserve)
        .allowsHitTesting(false)
        .accessibilityHidden(true)

      ListHeaderView(
        searchFocused: $searchFocused,
        searchQuery: $appState.history.searchQuery
      )
      .layoutPriority(1)

      typeMenu
      railToggle
      previewToggle
      windowPin
      WorkspaceOptionsButton(arrowEdge: .bottom, hit: CGSize(width: 28, height: 24))
        .modifier(LabToolbarChrome(nativePassthrough: true))
    }
    .padding(.vertical, WorkspaceInsets.headerVertical)
    .padding(.horizontal, 6)
    .padding(.trailing, Popup.horizontalPadding)
    .transaction { $0.animation = nil }
    .background {
      TitleBarDragStrip()
    }
    .readHeight(appState, into: \.popup.headerHeight)
    .onChange(of: appState.tagEditorItem != nil) {
      if appState.tagEditorItem != nil {
        searchFocused = false
      }
    }
  }

  private var typeMenu: some View {
    ImmediateMenuButton(
      systemName: "line.3.horizontal.decrease.circle",
      help: typeHelp,
      identifier: "lab-type-button",
      label: NSLocalizedString("type_filter", comment: ""),
      entries: [
        typeEntry(nil, title: "type_all", identifier: "lab-type-all"),
        typeEntry(.text, title: "kind_text", identifier: "lab-type-text"),
        typeEntry(.image, title: "kind_image", identifier: "lab-type-image"),
        typeEntry(.video, title: "kind_video", identifier: "lab-type-video"),
        typeEntry(.file, title: "kind_file", identifier: "lab-type-file")
      ]
    )
    .frame(width: 28, height: 24)
    .modifier(LabToolbarChrome(nativePassthrough: true))
    .accessibilityIdentifier("lab-type-button")
    .accessibilityLabel(Text("type_filter"))
  }

  private func typeEntry(
    _ kind: HistoryItem.ContentKind?,
    title: String,
    identifier: String
  ) -> ImmediateMenuEntry {
    ImmediateMenuEntry(
      title: NSLocalizedString(title, comment: ""),
      identifier: identifier,
      action: { appState.history.typeFilter = kind }
    )
  }

  private var typeHelp: String {
    let kind: String
    switch appState.history.typeFilter {
    case .text:
      kind = NSLocalizedString("kind_text", comment: "")
    case .image:
      kind = NSLocalizedString("kind_image", comment: "")
    case .video:
      kind = NSLocalizedString("kind_video", comment: "")
    case .file:
      kind = NSLocalizedString("kind_file", comment: "")
    case nil:
      kind = NSLocalizedString("type_all", comment: "")
    }
    return "\(NSLocalizedString("type_filter_help", comment: "")): \(kind)"
  }

  private var railToggle: some View {
    let expanded = appState.managementRailVisible
    return ImmediateIconButton(
      systemName: expanded ? "sidebar.leading" : "sidebar.squares.leading",
      help: NSLocalizedString(WorkspaceHelp.rail(expanded: expanded), comment: ""),
      identifier: "lab-rail-button",
      label: NSLocalizedString("nav_rail", comment: ""),
      value: expanded ? "expanded" : "narrow",
      // 和窗口置顶同一个约定：展开态是 accent，窄态是次要色。
      tint: expanded ? .controlAccentColor : .secondaryLabelColor,
      action: { appState.managementRailVisible.toggle() }
    )
    .frame(width: 28, height: 24)
    .modifier(LabToolbarChrome(nativePassthrough: true))
    .accessibilityIdentifier("lab-rail-button")
    .accessibilityLabel(Text("nav_rail"))
    .accessibilityValue(Text(expanded ? "expanded" : "narrow"))
  }

  private var previewToggle: some View {
    let open = controller.state.isOpen
    return ImmediateIconButton(
      systemName: "sidebar.right",
      help: ShortcutHelp.appended(
        .togglePreview,
        to: NSLocalizedString(WorkspaceHelp.preview(open: open), comment: "")
      ),
      identifier: "lab-preview-button",
      label: NSLocalizedString("preview_button", comment: ""),
      value: open ? "open" : "closed",
      // 展开时点亮，收起时回到次要色。
      tint: open ? .controlAccentColor : .secondaryLabelColor,
      action: { controller.togglePreview() }
    )
    .frame(width: 28, height: 24)
    .modifier(LabToolbarChrome(nativePassthrough: true))
    .accessibilityIdentifier("lab-preview-button")
    .accessibilityLabel(Text("preview_button"))
    .accessibilityValue(Text(open ? "open" : "closed"))
  }

  private var windowPin: some View {
    let pinned = appState.windowPinned
    return ImmediateIconButton(
      systemName: WorkspaceSymbols.windowPin,
      help: NSLocalizedString(WorkspaceHelp.windowPin(on: pinned), comment: ""),
      identifier: "lab-window-pin",
      label: NSLocalizedString("window_pin", comment: ""),
      value: pinned ? "on" : "off",
      tint: pinned ? .controlAccentColor : .secondaryLabelColor,
      action: { appState.windowPinned.toggle() }
    )
    .frame(width: 28, height: 24)
    .modifier(LabToolbarChrome(tint: pinned ? Color.blue : nil, nativePassthrough: true))
    .accessibilityIdentifier("lab-window-pin")
    .accessibilityLabel(Text("window_pin"))
  }
}
