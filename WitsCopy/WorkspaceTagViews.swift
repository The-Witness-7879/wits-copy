import AppKit
import Defaults
import SwiftUI

/// 标签的形状、颜色在侧栏、列表、预览和选择器中共用。
struct WorkspaceTagGlyph: View {
  var tag: String
  var size: CGFloat = 12
  var selected = false
  @Default(.workspaceTagStyles) private var styles

  var body: some View {
    let style = WorkspaceTagAppearance.style(for: tag, in: styles)
    let color = selected ? Color.white : Color(nsColor: WorkspaceTagAppearance.color(for: tag, style: style))
    Group {
      if let symbol = style.symbol {
        Image(systemName: symbol)
          .font(.system(size: size, weight: .medium))
      } else {
        Circle().frame(width: size * 0.65, height: size * 0.65)
      }
    }
    .foregroundStyle(color)
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

struct WorkspaceTagBadge: View {
  var tag: String
  var selected = false
  @Default(.workspaceTagStyles) private var styles

  var body: some View {
    let style = WorkspaceTagAppearance.style(for: tag, in: styles)
    let color = Color(nsColor: WorkspaceTagAppearance.color(for: tag, style: style))
    HStack(spacing: 4) {
      WorkspaceTagGlyph(tag: tag, size: 10, selected: selected)
      Text(verbatim: tag)
        .font(.system(size: 10))
        .foregroundStyle(selected ? Color.white : Color.primary)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(Capsule().fill(selected ? Color.white.opacity(0.16) : color.opacity(0.14)))
    .overlay(Capsule().strokeBorder(selected ? Color.white.opacity(0.18) : color.opacity(0.22), lineWidth: 0.5))
    .help(tag)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: tag))
  }
}

/// 先给标签分配宽度，来源只用剩余空间。短标签按内容占位，长标签有上限；
/// 不能仅靠 HStack 的排列顺序，长来源名仍可能参与等比分配、把标签挤掉。
struct TagFirstMetadataLayout: Layout {
  var maximumTagWidth: CGFloat = 144
  var spacing: CGFloat = 6

  private func sizes(_ proposal: ProposedViewSize, _ subviews: Subviews) -> (CGSize, CGSize, CGFloat) {
    guard subviews.count == 2 else { return (.zero, .zero, 0) }
    let tagIdeal = subviews[0].sizeThatFits(.unspecified)
    let sourceIdeal = subviews[1].sizeThatFits(.unspecified)
    let width = max(0, proposal.width ?? tagIdeal.width + spacing + sourceIdeal.width)
    let tagWidth = min(width, maximumTagWidth, tagIdeal.width)
    let tagHeight = subviews[0].sizeThatFits(ProposedViewSize(width: tagWidth, height: nil)).height
    let gap = min(spacing, max(0, width - tagWidth))
    let sourceWidth = max(0, width - tagWidth - gap)
    let sourceHeight = subviews[1].sizeThatFits(ProposedViewSize(width: sourceWidth, height: nil)).height
    return (CGSize(width: tagWidth, height: tagHeight), CGSize(width: sourceWidth, height: sourceHeight), gap)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let (tag, source, gap) = sizes(proposal, subviews)
    return CGSize(width: proposal.width ?? tag.width + gap + source.width, height: max(tag.height, source.height))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard subviews.count == 2 else { return }
    let (tag, source, gap) = sizes(ProposedViewSize(width: bounds.width, height: bounds.height), subviews)
    subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                      proposal: ProposedViewSize(width: tag.width, height: tag.height))
    subviews[1].place(at: CGPoint(x: bounds.minX + tag.width + gap, y: bounds.midY), anchor: .leading,
                      proposal: ProposedViewSize(width: source.width, height: source.height))
  }
}

/// 展开的侧栏里点标签图标打开。选择立即生效，点外或 Esc 关闭。
/// 一张 9 列网格：第一行是配色（自动＋八色），下面三行是形状（圆点＋实心图形）。
/// 两项默认（圆点、自动配色）都在网格里，所以不需要「恢复默认」和「完成」按钮。
struct WorkspaceTagAppearancePopover: View {
  var tag: String
  @Environment(\.dismiss) private var dismiss
  @Default(.workspaceTagStyles) private var styles

  static let cell: CGFloat = 22
  static let spacing: CGFloat = 3
  private let columns = Array(
    repeating: GridItem(.fixed(WorkspaceTagAppearancePopover.cell), spacing: WorkspaceTagAppearancePopover.spacing),
    count: 9
  )

  private var style: WorkspaceTagStyle { WorkspaceTagAppearance.style(for: tag, in: styles) }
  private var tint: NSColor { WorkspaceTagAppearance.color(for: tag, style: style) }

  private var colorIndices: [Int] {
    let choices = WorkspaceTagAppearance.selectableColorIndices
    // 改名保留下来的旧自动色可能不在八色里；仍要显示出来，并标为当前选中。
    if let current = style.colorIndex, !choices.contains(current) { return choices + [current] }
    return choices
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      LazyVGrid(columns: columns, spacing: Self.spacing) {
        choice(
          symbol: "a.circle.fill", tint: WorkspaceTagDot.color(for: tag),
          label: NSLocalizedString("tag_color_auto", comment: ""),
          identifier: "lab-tag-color-auto", selected: style.colorIndex == nil
        ) { setColor(nil) }
        ForEach(colorIndices, id: \.self) { index in
          choice(
            symbol: "circle.fill",
            tint: WorkspaceTagAppearance.color(for: tag, style: WorkspaceTagStyle(colorIndex: index)),
            label: NSLocalizedString("tag_color_\(index)", comment: ""),
            identifier: "lab-tag-color-\(index)", selected: style.colorIndex == index
          ) { setColor(index) }
        }
      }
      Divider()
      LazyVGrid(columns: columns, spacing: Self.spacing) {
        symbolButton(nil)
        ForEach(WorkspaceTagAppearance.symbols, id: \.self) { symbol in
          symbolButton(symbol)
        }
      }
    }
    .padding(10)
    .fixedSize()
    .onExitCommand { dismiss() }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("tag_appearance_title"))
    .accessibilityIdentifier("lab-tag-appearance-popover")
  }

  private func symbolButton(_ symbol: String?) -> some View {
    choice(
      symbol: symbol ?? "circle.fill", tint: tint,
      label: NSLocalizedString("tag_symbol_\(symbol ?? "dot")", comment: ""),
      identifier: "lab-tag-symbol-\(symbol ?? "dot")", selected: style.symbol == symbol
    ) {
      var next = style
      next.symbol = symbol
      save(next)
    }
  }

  private func choice(
    symbol: String, tint: NSColor, label: String, identifier: String,
    selected: Bool, action: @escaping () -> Void
  ) -> some View {
    ImmediateIconButton(
      systemName: symbol, help: label, identifier: identifier,
      label: label, value: selected ? "selected" : "", tint: tint, action: action
    )
    .frame(width: Self.cell, height: Self.cell)
    .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(selected ? 0.18 : 0)))
    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor.opacity(selected ? 0.85 : 0), lineWidth: 1))
  }

  private func setColor(_ index: Int?) {
    var next = style
    next.colorIndex = index
    save(next)
  }

  private func save(_ style: WorkspaceTagStyle) {
    styles = WorkspaceTagAppearance.setting(style, for: tag, in: styles)
  }
}
