import Defaults
import SwiftUI

enum SelectionAppearance {
  case none
  case topConnection
  case bottomConnection
  case topBottomConnection

  func rect(cornerRadius: CGFloat) -> some Shape {
    var cornerRadii = RectangleCornerRadii()
    switch self {
    case .none:
      cornerRadii.topLeading = cornerRadius
      cornerRadii.topTrailing = cornerRadius
      cornerRadii.bottomLeading = cornerRadius
      cornerRadii.bottomTrailing = cornerRadius
    case .topConnection:
      cornerRadii.bottomLeading = cornerRadius
      cornerRadii.bottomTrailing = cornerRadius
    case .bottomConnection:
      cornerRadii.topLeading = cornerRadius
      cornerRadii.topTrailing = cornerRadius
    case .topBottomConnection:
      break
    }
    return .rect(cornerRadii: cornerRadii)
  }
}

struct ListItemView<Title: View, ID: Hashable>: View {
  var id: ID
  var selectionId: UUID
  var appIcon: ApplicationImage?
  var image: NSImage?
  var showsTitleWithImage: Bool = false
  var accessoryImage: NSImage?
  var attributedTitle: AttributedString?
  var shortcuts: [KeyShortcut]
  var isSelected: Bool
  var subtitle: String? = nil
  var pathTooltip: String? = nil
  /// History rows only. Footer and paste-stack rows keep the legacy layout.
  var previewSlotID: String? = nil
  var bodyExcerpt: String? = nil
  /// 所属分类。单标签模型，最多一个；与侧栏共用图标和颜色。
  var categoryTag: String? = nil
  /// 置顶标记。和分类正交：「常用」里的条目仍然属于它自己的分类。
  var isPinned: Bool = false
  /// 整行是否被悬停。置顶按钮用它控制显隐——复用外层已有的 hover，
  /// 不在这里另开 tracking area（两层 hover 会把渲染卡死）。
  var isRowHovered: Bool = false
  var captionText: String = ""
  var selectionIndex: Int?
  var help: LocalizedStringKey?
  var selectionAppearance: SelectionAppearance = .none
  /// Off when the parent paints one highlight across the row and its actions.
  var drawsSelectionBackground: Bool = true
  /// Off when the parent paints hover across tags, padding, and the action strip.
  var drawsHover: Bool = true
  /// Parent hover, so an image row can paint a mark the opaque thumbnail cannot hide.
  var imageStateVisible: Bool = false
  @ViewBuilder var title: () -> Title

  @Default(.showApplicationIcons) private var showIcons
  @Default(.compactRows) private var compactRows
  @Environment(AppState.self) private var appState
  @Environment(ModifierFlags.self) private var modifierFlags

  private var rowHeight: CGFloat {
    if compactRows {
      return Popup.itemHeight
    }
    return 44
  }

  private var historyContentHeight: CGFloat {
    if compactRows {
      return Popup.itemHeight
    }
    return HistoryRowMetrics.contentHeight
  }

  var body: some View {
    if previewSlotID == nil {
      legacyBody
    } else {
      historyBody
    }
  }

  private var legacyBody: some View {
    HStack(spacing: 0) {
      if showIcons, let appIcon {
        VStack {
          Spacer(minLength: 0)
          AppImageView(appImage: appIcon, size: NSSize(width: 15, height: 15))
          Spacer(minLength: 0)
        }
        .padding(.leading, 4)
        .padding(.vertical, 5)
      }

      Spacer()
        .frame(width: showIcons ? 5 : 10)

      if let accessoryImage {
        Image(nsImage: accessoryImage)
          .accessibilityIdentifier("copy-history-item")
          .padding(.trailing, 5)
          .padding(.vertical, 5)
      }

      if let image {
        Group {
          if showsTitleWithImage {
            Image(nsImage: image)
              .resizable()
              .aspectRatio(contentMode: .fit)
              .frame(width: 48, height: max(16, rowHeight - 4))
          } else {
            Image(nsImage: image)
          }
        }
        .accessibilityIdentifier("copy-history-item")
        .padding(.trailing, 5)
        .padding(.vertical, 5)
      }
      if image == nil || showsTitleWithImage {
        VStack(alignment: .leading, spacing: 1) {
          ListItemTitleView(attributedTitle: attributedTitle, title: title)
          if let subtitle, !compactRows {
            Text(subtitle)
              .font(.caption2)
              .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
              .lineLimit(1)
          }
        }
        .padding(.trailing, 5)
      }

      Spacer()

      HStack(spacing: 5) {
        if let index = selectionIndex {
          Text("\(index + 1)")
            .font(.caption)
            .frame(minWidth: 10, alignment: .center)
            .padding(3)
            .background(
              Color.secondary.opacity(isSelected ? 0.5 : 0.8),
              in: Capsule()
            )
            .foregroundStyle(Color.white)
        }

        if !shortcuts.isEmpty {
          ZStack(alignment: .trailing) {
            ForEach(shortcuts) { shortcut in
              let visible = shortcut.isVisible(shortcuts, modifierFlags.flags)
              KeyboardShortcutView(shortcut: shortcut)
                .opacity(visible ? 1 : 0)
                .frame(width: visible ? nil : 0)
            }
          }
        }
      }
      .padding(.trailing, 10)
    }
    .frame(minHeight: rowHeight)
    .padding(.vertical, 1)
    .id(id)
    .frame(maxWidth: .infinity, alignment: .leading)
    .foregroundStyle(isSelected ? Color.white : .primary)
    // macOS 26 broke hovering if no background is present.
    // The slight opcaity white background is a workaround
    .background(drawsSelectionBackground
      ? (isSelected ? Color.accentColor.opacity(0.8) : .white.opacity(0.001))
      : Color.clear)
    .clipShape(RoundedRectangle(cornerRadius: drawsSelectionBackground ? Popup.cornerRadius : 0))
    .hoverSelectionId(selectionId)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .modifier(PathTooltipModifier(text: pathTooltip))
  }

  private var historyBody: some View {
    HStack(alignment: .top, spacing: 0) {
      // 左列只表示来源；标签名称在元信息行前部，不再靠颜色猜归属。
      if showIcons {
        VStack(alignment: .center, spacing: 5) {
          if showIcons, let appIcon {
            AppImageView(appImage: appIcon, size: NSSize(width: 30, height: 30))
          } else if showIcons {
            Color.clear.frame(width: 30, height: 30)
          }
          Spacer(minLength: 0)
        }
        .frame(width: 30)
        .padding(.top, 2)
        .padding(.leading, 4)
      }

      Spacer()
        .frame(width: showIcons ? 6 : 10)

      historyCenter
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: historyContentHeight)
        .layoutPriority(1)

      // 和快捷键、⋯ 同一级：固定槽位，不另开 tracking area。
      // 显隐只看外层已有的 hover；置顶后常驻并着色。点击由 ImmediateActionButton
      // 在 mouseDown 吃掉，不冒泡成粘贴。
      ImmediateIconButton(
        systemName: isPinned ? WorkspaceSymbols.itemPinFilled : WorkspaceSymbols.itemPin,
        help: NSLocalizedString(isPinned ? "selection_unpin" : "item_pin", comment: ""),
        identifier: RowPinSlot.accessibilityIdentifier(slotID: previewSlotID ?? ""),
        label: NSLocalizedString(isPinned ? "selection_unpin" : "item_pin", comment: ""),
        value: isPinned ? "pinned" : "",
        tint: RowPinSlot.tint(pinned: isPinned, selected: isSelected),
        enabled: pinShown,
        action: {
          guard let target = appState.history.all.first(where: { $0.id == shortcutItemID }) else { return }
          appState.performRowAction(.pin, on: target)
        }
      )
      .frame(width: HistoryRowMetrics.pinWidth, height: HistoryRowMetrics.pinButtonHeight)
      // Same vertical center as the shortcut glyph and the ellipsis. Top-aligning
      // the 22pt button in this HStack leaves it a row above those peers.
      .frame(width: HistoryRowMetrics.pinWidth, height: historyContentHeight, alignment: .center)
      .opacity(pinShown ? 1 : 0)
      .allowsHitTesting(pinShown)
      .accessibilityHidden(!pinShown)

      historyShortcuts
        .frame(width: HistoryRowMetrics.shortcutWidth, height: historyContentHeight)
        .padding(.leading, HistoryRowMetrics.pinShortcutGap)
        .padding(.trailing, HistoryRowMetrics.shortcutTrailing)
        .layoutPriority(2)
    }
    .frame(minHeight: historyContentHeight)
    .frame(maxWidth: .infinity, alignment: .leading)
    .foregroundStyle(isSelected ? Color.white : .primary)
    .background(drawsSelectionBackground
      ? (isSelected ? Color.accentColor.opacity(0.8) : .white.opacity(0.001))
      : Color.clear)
    .clipShape(RoundedRectangle(cornerRadius: drawsSelectionBackground ? Popup.cornerRadius : 0))
    .modifier(RowHoverGate(enabled: drawsHover, id: selectionId))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .modifier(PathTooltipModifier(text: pathTooltip))
  }

  private var historyCenter: some View {
    ZStack(alignment: .topLeading) {
      if let image {
        if compactRows {
          HStack(spacing: 6) {
            if let tag = visibleCategory {
              categoryBadge(tag)
                .frame(maxWidth: 100, alignment: .leading)
                .layoutPriority(1)
            }
            historyThumbnail(image)
          }
          .frame(height: historyContentHeight)
        } else {
          VStack(alignment: .leading, spacing: HistoryRowMetrics.metadataGap) {
            historyThumbnail(image)
            historyMetadata
          }
          .frame(height: historyContentHeight)
        }
      } else {
        RowSlotBox(identifier: rowPreviewID)
          .allowsHitTesting(false)
          .frame(maxWidth: .infinity, minHeight: historyContentHeight, maxHeight: historyContentHeight)
          .overlay(alignment: .topLeading) {
            HStack(alignment: .top, spacing: 4) {
              if let accessoryImage {
                Image(nsImage: accessoryImage)
                  .accessibilityIdentifier("copy-history-item")
                  .frame(width: 14, height: 14)
              }
              VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                  if compactRows, let tag = visibleCategory {
                    categoryBadge(tag)
                      .frame(maxWidth: 100)
                      .layoutPriority(1)
                  }
                  ListItemTitleView(
                    attributedTitle: attributedTitle,
                    lineLimit: compactRows || showsHistoryExcerpt ? 1 : 2,
                    title: title
                  )
                }
                if showsHistoryExcerpt, let bodyExcerpt {
                  Text(bodyExcerpt)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.9) : .secondary)
                    .lineLimit(2)
                    .accessibilityIdentifier("copy-history-item")
                }
                if !compactRows {
                  historyMetadata
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.trailing, 4)
          }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .overlay(alignment: .topTrailing) {
      if let index = selectionIndex {
        Text("\(index + 1)")
          .font(.caption)
          .padding(3)
          .background(Color.secondary.opacity(isSelected ? 0.5 : 0.8), in: Capsule())
          .foregroundStyle(Color.white)
          .padding(2)
      }
    }
    .clipped()
    .accessibilityElement(children: .contain)
  }

  private func historyThumbnail(_ image: NSImage) -> some View {
    let height = compactRows ? historyContentHeight : HistoryRowMetrics.thumbnailHeight
    return RowMiniImage(image: image, identifier: rowPreviewID)
      .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
      .allowsHitTesting(false)
      .overlay {
        if isSelected || imageStateVisible {
          ImageStateMark(identifier: "lab-row-image-state-\(previewSlotID ?? "")")
            .allowsHitTesting(false)
        }
      }
      .overlay(alignment: .bottomLeading) {
        if showsTitleWithImage {
          OpaqueRowCaption(text: captionText)
            .allowsHitTesting(false)
            .padding(.horizontal, 4)
            .padding(.bottom, 2)
        }
      }
  }

  /// 在具体分类里左栏已经给出了归属；聚合浏览才需要每行显示名称。
  private var visibleCategory: String? {
    guard let tag = categoryTag else { return nil }
    if let filter = appState.history.tagFilter, filter.caseInsensitiveCompare(tag) == .orderedSame { return nil }
    return tag
  }

  private func categoryBadge(_ tag: String) -> some View {
    WorkspaceTagBadge(tag: tag, selected: isSelected)
      .background(RowCategoryAnchor(identifier: "lab-row-category-\(tag)"))
  }

  private var sourceCaption: some View {
    Text(verbatim: subtitle ?? "")
      .font(.caption2)
      .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
      .lineLimit(1)
      .truncationMode(.tail)
      .background(RowCategoryAnchor(identifier: "lab-row-source-\(previewSlotID ?? "")"))
      .accessibilityIdentifier("lab-row-source-\(previewSlotID ?? "")")
  }

  @ViewBuilder private var historyMetadata: some View {
    if let tag = visibleCategory {
      TagFirstMetadataLayout {
        categoryBadge(tag)
        sourceCaption
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } else if subtitle != nil {
      sourceCaption
    }
  }

  private var historyShortcuts: some View {
    let recording = pinRecording
    return HistoryShortcutSlot(
      containerID: rowShortcutID,
      controlID: "lab-pin-shortcut-\(previewSlotID ?? "")",
      itemID: shortcutItemID,
      pinned: shortcutPinned,
      recording: recording,
      message: appState.pinShortcutMessage(for: shortcutItemID),
      error: appState.pinShortcutError(for: shortcutItemID)
    )
    .frame(width: HistoryRowMetrics.shortcutWidth, height: historyContentHeight)
    // 居中而不是靠右：槽里靠右会在图钉和 ⌘ 之间空出一大截，
    // 看起来不像同一排的同级按钮。槽宽只留够 ⌘X。
    .overlay(alignment: .center) {
      if !recording,
         appState.pinShortcutMessage(for: shortcutItemID) == nil,
         appState.pinShortcutError(for: shortcutItemID) == nil,
         !shortcuts.isEmpty {
        ForEach(shortcuts) { shortcut in
          let visible = shortcut.isVisible(shortcuts, modifierFlags.flags)
          KeyboardShortcutView(shortcut: shortcut)
            .opacity(visible ? 1 : 0)
            .frame(width: visible ? nil : 0)
            .allowsHitTesting(false)
        }
      }
    }
    .clipped()
  }

  private var shortcutItemID: UUID {
    if let selectionId = selectionId as UUID? { return selectionId }
    return UUID()
  }

  private var shortcutPinned: Bool {
    previewSlotID != nil && appState.history.all.contains { $0.id == shortcutItemID && $0.isPinned && !$0.isRemoved }
  }

  private var pinShown: Bool {
    RowPinSlot.shown(pinned: isPinned, rowHovered: isRowHovered)
  }

  private var pinRecording: Bool {
    appState.pinRecordingItemID == shortcutItemID
  }

  private var rowPreviewID: String {
    "lab-row-preview-\(previewSlotID ?? "")"
  }

  private var rowShortcutID: String {
    "lab-row-shortcuts-\(previewSlotID ?? "")"
  }

  private var showsHistoryExcerpt: Bool {
    guard !compactRows, let bodyExcerpt, !bodyExcerpt.isEmpty else { return false }
    return true
  }
}

enum HistoryRowMetrics {
  /// One height for every history row. A thumbnail, a two-line excerpt, or a
  /// long title must never stretch a single row: the list reads as one grid.
  /// 60 leaves room for title + two-line excerpt + source line.
  static let contentHeight: CGFloat = 60
  static let metadataHeight: CGFloat = 16
  static let metadataGap: CGFloat = 2
  static var thumbnailHeight: CGFloat { contentHeight - metadataHeight - metadataGap }
  static let shortcutWidth: CGFloat = 26
  /// Row-end pin slot, immediately left of the shortcut lane.
  static let pinWidth: CGFloat = 22
  /// 图钉和快捷键是同级按钮：槽位相邻，只留 2pt，不再隔出一大段空档。
  static let pinShortcutGap: CGFloat = 2
  /// 行尾不再挂 ⋯，快捷键槽自己留一点贴边距离。
  static let shortcutTrailing: CGFloat = 6
  static let pinButtonHeight: CGFloat = 22

  static let fadeLength: CGFloat = 12
  static let verticalInset: CGFloat = 6
  static let rowGap: CGFloat = 5
  static let compactVerticalInset: CGFloat = 2
  static let compactRowGap: CGFloat = 2
}

struct RowMiniImage: NSViewRepresentable {
  var image: NSImage
  var identifier: String

  func makeNSView(context: Context) -> RowMiniImageView {
    let view = RowMiniImageView()
    view.image = image
    view.setAccessibilityElement(true)
    view.setAccessibilityIdentifier(identifier)
    return view
  }

  func updateNSView(_ view: RowMiniImageView, context: Context) {
    view.image = image
    view.setAccessibilityIdentifier(identifier)
    view.needsDisplay = true
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: RowMiniImageView, context: Context) -> CGSize? {
    CGSize(
      width: proposal.width ?? nsView.bounds.width,
      height: proposal.height ?? HistoryRowMetrics.contentHeight
    )
  }
}

final class RowMiniImageView: NSView {
  var image: NSImage? {
    didSet { needsDisplay = true }
  }

  override var isOpaque: Bool { false }
  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    guard let image, image.size.width > 0, image.size.height > 0, bounds.width > 1, bounds.height > 1 else { return }
    let scaledHeight = bounds.width * (image.size.height / image.size.width)
    let overflows = scaledHeight > bounds.height + 0.5
    let dest = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: scaledHeight)
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    ctx.saveGState()
    ctx.clip(to: bounds)
    // Keep the alpha mask local to this image; never erase the row highlight
    // behind the transparent view. In flipped coordinates maxY is the bottom.
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    image.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [
      .interpolation: NSImageInterpolation.medium
    ])
    if overflows {
      let fade = min(HistoryRowMetrics.fadeLength, bounds.height * 0.34)
      let fadeStart = bounds.maxY - fade
      if let gradient = CGGradient(
        colorSpace: CGColorSpaceCreateDeviceRGB(),
        colorComponents: [0, 0, 0, 1, 0, 0, 0, 0],
        locations: [0, 1],
        count: 2
      ) {
        ctx.saveGState()
        ctx.clip(to: NSRect(x: bounds.minX, y: fadeStart, width: bounds.width, height: fade))
        ctx.setBlendMode(.destinationIn)
        ctx.drawLinearGradient(
          gradient,
          start: CGPoint(x: bounds.midX, y: fadeStart),
          end: CGPoint(x: bounds.midX, y: bounds.maxY),
          options: []
        )
        ctx.restoreGState()
      }
    }
    ctx.endTransparencyLayer()
    ctx.restoreGState()
  }
}

/// Fixed-width shortcut lane. The interactive child lives in PinShortcutRecorder.swift.
private struct RowHoverGate: ViewModifier {
  var enabled: Bool
  var id: UUID

  func body(content: Content) -> some View {
    if enabled {
      content.hoverSelectionId(id)
    } else {
      content
    }
  }
}

struct RowSlotBox: NSViewRepresentable {
  var identifier: String

  func makeNSView(context: Context) -> NSView {
    let view = RowSlotView()
    view.setAccessibilityElement(true)
    view.setAccessibilityIdentifier(identifier)
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    view.setAccessibilityIdentifier(identifier)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? 10, height: proposal.height ?? HistoryRowMetrics.contentHeight)
  }
}

final class RowSlotView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class RowCaptionField: NSTextField {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct OpaqueRowCaption: NSViewRepresentable {
  var text: String

  func makeNSView(context: Context) -> NSTextField {
    let field = RowCaptionField(labelWithString: text)
    field.textColor = .white
    field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    field.backgroundColor = NSColor.black.withAlphaComponent(0.72)
    field.drawsBackground = true
    field.isBezeled = false
    field.lineBreakMode = .byTruncatingMiddle
    field.maximumNumberOfLines = 1
    field.alphaValue = 1
    field.setAccessibilityIdentifier("copy-history-item")
    return field
  }

  func updateNSView(_ field: NSTextField, context: Context) {
    if field.stringValue != text { field.stringValue = text }
    field.alphaValue = 1
  }
}

private struct PathTooltipModifier: ViewModifier {
  var text: String?

  @ViewBuilder
  func body(content: Content) -> some View {
    if let text, !text.isEmpty {
      content.iconHelp(text)
    } else {
      content
    }
  }
}

/// Transparent, noninteractive frame marker for row layout measurements.
private struct RowCategoryAnchor: NSViewRepresentable {
  var identifier: String

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.setAccessibilityElement(false)
    view.setAccessibilityIdentifier(identifier)
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    view.setAccessibilityIdentifier(identifier)
  }
}
