import Defaults
import SwiftUI

struct HistoryItemView: View {
  @Bindable var item: HistoryItemDecorator
  var previous: HistoryItemDecorator?
  var next: HistoryItemDecorator?
  var index: Int

  private var visualIndex: Int? {
    if appState.navigator.isMultiSelectInProgress && item.selectionIndex >= 0 {
      return item.selectionIndex
    }
    return nil
  }

  private var selectionAppearance: SelectionAppearance {
    let previousSelected = previous?.isSelected ?? false
    let nextSelected = next?.isSelected ?? false
    switch (previousSelected, nextSelected) {
    case (true, false):
      return .topConnection
    case (false, true):
      return .bottomConnection
    case (true, true):
      return .topBottomConnection
    default:
      return .none
    }
  }

  @Default(.showHexColorSwatch) private var showHexColorSwatch
  @Default(.compactRows) private var compactRows
  @Environment(AppState.self) private var appState
  @State private var hovered = false

  private var colorSwatchImage: NSImage? {
    guard showHexColorSwatch else { return nil }
    return ColorImage.from(item.title)
  }

  @ViewBuilder
  var body: some View {
    if !item.isRemoved {
      rowContent
    }
  }

  @ViewBuilder
  private var rowContent: some View {
    let label = WorkspaceItemLabel.make(
      storedTitle: item.title,
      filePaths: item.item.fileURLs.map(\.path)
    )
    let inset = compactRows ? HistoryRowMetrics.compactVerticalInset : HistoryRowMetrics.verticalInset
    let gap = compactRows ? HistoryRowMetrics.compactRowGap : HistoryRowMetrics.rowGap
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 0) {
        ListItemView(
          id: item.id,
          selectionId: item.id,
          appIcon: item.applicationImage,
          image: item.thumbnailImage,
          showsTitleWithImage: !item.title.isEmpty,
          accessoryImage: item.thumbnailImage != nil ? nil : colorSwatchImage,
          attributedTitle: label.isFile ? nil : item.attributedTitle,
          shortcuts: item.shortcuts,
          isSelected: item.isSelected,
          subtitle: item.rowCaption,
          pathTooltip: label.tooltip,
          previewSlotID: item.id.uuidString,
          bodyExcerpt: item.hasImage ? nil : item.rowExcerpt,
          categoryTag: item.item.tags.first,
          isPinned: item.isPinned,
          isRowHovered: hovered,
          captionText: item.title.isEmpty ? "" : label.rowTitle,
          selectionIndex: visualIndex,
          selectionAppearance: selectionAppearance,
          drawsSelectionBackground: false,
          drawsHover: false,
          imageStateVisible: hovered
        ) {
          Text(verbatim: label.rowTitle)
        }
        .onAppear {
          item.ensureThumbnailImage()
        }
        .overlay {
          RowDragSurface(
            itemID: item.id,
            title: item.title,
            pinSlotWidth: RowPinSlot.exemptWidth(pinned: item.isPinned, rowHovered: hovered)
          ) { clickCount, flags in
            appState.handleRowClick(
              item,
              clickCount: RowClickCount.resolve(fallback: clickCount),
              flags: flags
            )
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityAction(.default) {
          appState.handleRowClick(item, clickCount: 1, flags: .currentModifierFlags)
        }
        .accessibilityAction(named: Text("row_copy")) {
          appState.commitRow(item, flags: .currentModifierFlags)
        }

      }

      // 分类不再在标题下方排一行带字的胶囊：
      // 它现在是左侧来源图标下方的那个颜色圆点，和左栏同一个颜色。
    }
    .padding(.vertical, inset)
    .fixedSize(horizontal: false, vertical: true)
    .background {
      RowHighlightPlate(
        selected: item.isSelected,
        hovered: hovered && !item.isSelected,
        identifier: "lab-row-highlight-\(item.id.uuidString)"
      )
      .allowsHitTesting(false)
    }
    .onHover { inside in
      hovered = inside
    }
    .padding(.bottom, gap)
    .overlay {
      RowEdgeDragSurface(
        itemID: item.id,
        title: item.title,
        top: inset,
        bottom: inset + gap
      ) { clickCount, flags in
        appState.handleRowClick(
          item,
          clickCount: RowClickCount.resolve(fallback: clickCount),
          flags: flags
        )
      }
    }
    .popover(
      isPresented: Binding(
        get: { appState.presentsTagEditor(item, at: .row) },
        set: { presented in
          if !presented { appState.dismissTagEditor(itemID: item.id, anchor: .row) }
        }
      ),
      arrowEdge: .trailing
    ) {
      TagEditorPopover(item: item, compact: true)
        .environment(appState)
        .accessibilityIdentifier("lab-row-tag-editor")
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("lab-row-chrome-\(item.id.uuidString)")
    .contextMenu { rowContextMenu }
  }

  /// 原来行尾那颗 ⋯ 按钮撤掉了：同一份菜单现在挂在整行的右键上，
  /// 删除也仍然可以从右下角预览区进。行尾不再为菜单预留 28pt。
  @ViewBuilder
  private var rowContextMenu: some View {
    let pinned = item.isPinned
    Button(action: { appState.beginTagEdit(for: item, anchor: .row) }) {
      Label(
        NSLocalizedString("row_tag", comment: ""),
        systemImage: item.item.tags.isEmpty ? "tag" : "tag.fill"
      )
    }
    .accessibilityIdentifier("lab-row-tag-\(item.id.uuidString)")
    .iconHelp(NSLocalizedString("row_tag_help", value: "编辑这一条的标签。", comment: ""))

    Button(action: { appState.performRowAction(.pin, on: item) }) {
      Label(
        NSLocalizedString(pinned ? "selection_unpin" : "item_pin", comment: ""),
        systemImage: pinned ? WorkspaceSymbols.itemUnpin : WorkspaceSymbols.itemPin
      )
    }
    .accessibilityIdentifier("lab-row-pin-\(item.id.uuidString)")
    .iconHelp(NSLocalizedString("row_pin_help", value: "置顶或取消置顶这一条。", comment: ""))

    Divider()

    Button(action: { appState.requestDelete([item]) }) {
      Label(NSLocalizedString("row_delete", comment: ""), systemImage: "trash")
    }
    .accessibilityIdentifier("lab-row-delete-\(item.id.uuidString)")
    .iconHelp(NSLocalizedString("row_delete_help", value: "删除这一条。", comment: ""))
  }
}

struct TagEditorPopover: View {
  var item: HistoryItemDecorator
  var compact = false
  @Environment(AppState.self) private var appState
  @State private var draft = ""

  var body: some View {
    let _ = item.tagRevision
    VStack(alignment: .leading, spacing: 8) {
      // 不显示条目标题：这个浮窗就锚在那一行旁边，标题在行里已经有了，
      // 再写一遍只是重复占位。
      if let message = appState.storageError {
        Text(message)
          .font(.caption)
          .foregroundStyle(.red)
          .accessibilityIdentifier("lab-tag-error")
      }

      HStack {
        TagDraftField(text: $draft, onSubmit: addDraft)
          .frame(minWidth: 120, minHeight: GlassField.height, maxHeight: GlassField.height)
        Button(action: addDraft) {
          Text("tag_add")
        }
        .accessibilityIdentifier("lab-tag-add")
        .iconHelp(NSLocalizedString("tag_add_help", value: "Add tag", comment: ""))
        .disabled(HistoryItem.normalizedTag(draft) == nil)
      }

      if !item.item.tags.isEmpty {
        Text("tag_on_item")
          .font(.caption2)
          .foregroundStyle(.secondary)
        tagButtons(item.item.tags, assigns: false)
      }

      let known = knownTags
      if !known.isEmpty {
        Text("tag_existing")
          .font(.caption2)
          .foregroundStyle(.secondary)
        tagButtons(known, assigns: true)
      }
    }
    .padding(compact ? 8 : 12)
    .frame(width: compact ? 220 : 280, alignment: .topLeading)
    .accessibilityElement(children: .contain)
  }

  private var knownTags: [String] {
    let query = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    return appState.history.knownTags.filter { tag in
      let already = item.item.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
      let matches = query.isEmpty || tag.localizedCaseInsensitiveContains(query)
      return !already && matches
    }
  }

  private func tagButtons(_ tags: [String], assigns: Bool) -> some View {
    FlexibleTagRow(tags: tags, identifierPrefix: assigns ? "lab-tag-known" : "lab-tag-remove") { tag in
      if assigns {
        _ = appState.history.assignTag(item, named: tag)
      } else {
        _ = appState.history.removeTag(item, named: tag)
      }
    }
  }

  private func addDraft() {
    guard appState.history.assignTag(item, named: draft) else { return }
    draft = ""
  }
}

/// SwiftUI TextField does not publish lab-tag-field unless the panel can already
/// become key. The opening click returns before that field exists, so the
/// identifier has to live on a real text field.
struct TagDraftField: NSViewRepresentable {
  @Binding var text: String
  var onSubmit: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, onSubmit: onSubmit)
  }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    var text: Binding<String>
    var onSubmit: () -> Void
    init(text: Binding<String>, onSubmit: @escaping () -> Void) {
      self.text = text
      self.onSubmit = onSubmit
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      text.wrappedValue = field.stringValue
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
      if commandSelector == #selector(NSResponder.insertNewline(_:)) {
        onSubmit()
        return true
      }
      return false
    }
  }

  func makeNSView(context: Context) -> NSTextField {
    let field = GlassTextField(frame: .zero)
    field.stringValue = text
    field.isEditable = true
    field.isSelectable = true
    field.delegate = context.coordinator
    field.placeholderString = NSLocalizedString("tag_placeholder", comment: "")
    field.setAccessibilityIdentifier("lab-tag-field")
    return field
  }

  func updateNSView(_ field: NSTextField, context: Context) {
    context.coordinator.text = $text
    context.coordinator.onSubmit = onSubmit
    let editing = (field.window?.firstResponder as? NSText)?.delegate === field
    if !editing && field.stringValue != text {
      field.stringValue = text
    }
    field.setAccessibilityIdentifier("lab-tag-field")
    if let window = field.window, window.canBecomeKey, !editing, window.firstResponder !== field {
      window.makeFirstResponder(field)
    }
  }
}

private struct FlexibleTagRow: View {
  var tags: [String]
  var identifierPrefix: String
  var action: (String) -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(tags, id: \.self) { tag in
          Button {
            action(tag)
          } label: {
            Text(tag)
              .font(.caption)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(
                Color(nsColor: .controlAccentColor).opacity(0.28),
                in: Capsule()
              )
          }
          .buttonStyle(.plain)
          .iconHelp(NSLocalizedString(
            identifierPrefix == "lab-tag-known" ? "tag_assign_help" : "tag_remove_help",
            value: identifierPrefix == "lab-tag-known" ? "Add this tag" : "Remove this tag",
            comment: ""
          ))
          .accessibilityIdentifier("\(identifierPrefix)-\(tag)")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxHeight: 96)
  }
}

private struct RowDragSurface: NSViewRepresentable {
  var itemID: UUID
  var title: String
  var pinSlotWidth: CGFloat = 0
  var onClick: (Int, NSEvent.ModifierFlags) -> Void

  func makeNSView(context: Context) -> RowDragSurfaceView {
    let view = RowDragSurfaceView()
    view.itemID = itemID
    view.itemTitle = title
    view.pinSlotWidth = pinSlotWidth
    view.onClick = onClick
    return view
  }

  func updateNSView(_ view: RowDragSurfaceView, context: Context) {
    view.itemID = itemID
    view.itemTitle = title
    view.pinSlotWidth = pinSlotWidth
    view.onClick = onClick
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    nsView: RowDragSurfaceView,
    context: Context
  ) -> CGSize? {
    CGSize(
      width: proposal.width ?? nsView.bounds.width,
      height: proposal.height ?? nsView.bounds.height
    )
  }
}

/// Claims only the row's vertical padding and the gap under it. The middle
/// returns nil so image edges, shortcut slots, tag chips, and the action
/// button keep their own hit targets. Pins use the same row, so they are covered.
private struct RowEdgeDragSurface: NSViewRepresentable {
  var itemID: UUID
  var title: String
  var top: CGFloat
  var bottom: CGFloat
  var onClick: (Int, NSEvent.ModifierFlags) -> Void

  func makeNSView(context: Context) -> RowDragSurfaceView {
    let view = configured(RowDragSurfaceView())
    return view
  }

  func updateNSView(_ view: RowDragSurfaceView, context: Context) {
    _ = configured(view)
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    nsView: RowDragSurfaceView,
    context: Context
  ) -> CGSize? {
    CGSize(width: proposal.width ?? 10, height: proposal.height ?? top + bottom)
  }

  private func configured(_ view: RowDragSurfaceView) -> RowDragSurfaceView {
    view.itemID = itemID
    view.itemTitle = title
    view.onClick = onClick
    view.claimsEdgesOnly = true
    view.topInset = top
    view.bottomInset = bottom
    return view
  }
}

/// Pin control next to the shortcut lane. Visibility comes from the row's
/// existing hover, not a second tracking area.
enum RowPinSlot {
  static func shown(pinned: Bool, rowHovered: Bool) -> Bool {
    pinned || rowHovered
  }

  static func exemptWidth(pinned: Bool, rowHovered: Bool) -> CGFloat {
    shown(pinned: pinned, rowHovered: rowHovered) ? HistoryRowMetrics.pinWidth : 0
  }

  /// Distinct from the row menu item `lab-row-pin-<id>`.
  static func accessibilityIdentifier(slotID: String) -> String {
    "lab-row-pin-button-\(slotID)"
  }

  static func tint(pinned: Bool, selected: Bool) -> NSColor {
    if pinned { return .controlAccentColor }
    return selected ? .white : .secondaryLabelColor
  }
}

final class RowDragSurfaceView: NSView {
  static let retainedWorkspaceItemDragSource = WorkspaceItemDragSource()
  var itemID = UUID()
  var itemTitle = ""
  var onClick: ((Int, NSEvent.ModifierFlags) -> Void)?
  /// Width of the interactive pin slot, measured from the left edge of the shortcut lane.
  var pinSlotWidth: CGFloat = 0
  var claimsEdgesOnly = false
  var topInset: CGFloat = 0
  var bottomInset: CGFloat = 0
  private var trackingClick = false
  private var trackingStart = NSPoint.zero
  private var trackingFlags: NSEvent.ModifierFlags = []

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    // AppKit passes the superview's coordinates. bounds is local.
    guard superview != nil else { return nil }
    let local = convert(point, from: superview)
    return RowDragHit.view(self, at: local, in: bounds)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      trackingClick = false
    }
  }

  override func mouseDown(with event: NSEvent) {
    trackingClick = true
    trackingStart = convert(event.locationInWindow, from: nil)
    trackingFlags = event.modifierFlags
  }

  override func mouseDragged(with event: NSEvent) {
    guard trackingClick else { return }
    let point = convert(event.locationInWindow, from: nil)
    guard RowPointerDrag.exceeded(
      dx: Double(point.x - trackingStart.x),
      dy: Double(point.y - trackingStart.y)
    ) else { return }
    trackingClick = false
    WorkspaceItemDragSession.begin(
      from: self,
      event: event,
      itemID: itemID,
      title: itemTitle,
      source: Self.retainedWorkspaceItemDragSource
    )
  }

  override func mouseUp(with event: NSEvent) {
    guard trackingClick else { return }
    trackingClick = false
    onClick?(event.clickCount, trackingFlags)
  }
}

/// Drag tracking must not invent a double-click. KitDefined current events throw on clickCount.
private enum RowClickCount {
  static func resolve(fallback: Int) -> Int {
    guard let event = NSApp.currentEvent, event.type != .appKitDefined else { return fallback }
    return NSApp.currentEvent?.clickCount ?? fallback
  }
}

/// Hit policy for row drags. Padding, the gap, and the content face (including
/// image edges) start an item drag. The shortcut lane does not, so recording
/// still receives the click. y grows downward.
enum RowDragHit {
  static func claims(
    point: CGPoint,
    bounds: CGRect,
    edgesOnly: Bool,
    topInset: CGFloat,
    bottomInset: CGFloat,
    shortcutWidth: CGFloat = HistoryRowMetrics.shortcutWidth,
    pinSlotWidth: CGFloat = 0
  ) -> Bool {
    guard bounds.contains(point) else { return false }
    if edgesOnly {
      return point.y < topInset || point.y > bounds.maxY - bottomInset
    }
    return point.x <= bounds.maxX - shortcutWidth - pinSlotWidth
  }

  static func view(_ view: RowDragSurfaceView, at point: NSPoint, in bounds: NSRect) -> NSView? {
    claims(
      point: point,
      bounds: bounds,
      edgesOnly: view.claimsEdgesOnly,
      topInset: view.topInset,
      bottomInset: view.bottomInset,
      pinSlotWidth: view.pinSlotWidth
    ) ? view : nil
  }
}
