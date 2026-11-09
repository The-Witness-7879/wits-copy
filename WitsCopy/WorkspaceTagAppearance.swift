import AppKit
import Defaults
import Foundation

struct WorkspaceTagStyle: Codable, Defaults.Serializable, Equatable {
  /// nil 表示原来的纯色圆点。
  var symbol: String? = nil
  /// nil 表示沿用标签名的自动配色。
  var colorIndex: Int? = nil
}

enum WorkspaceTagAppearance {
  /// 实心图形：填色面里把线条挖空。选择器按 9 列排，加圆点正好三行。
  static let symbols: [String] = [
    "folder.fill", "star.fill", "bookmark.fill", "tag.fill", "flag.fill", "heart.fill", "lightbulb.fill", "checkmark.circle.fill", "clock.fill",
    "doc.text.fill", "book.fill", "archivebox.fill", "briefcase.fill", "curlybraces.square.fill", "terminal.fill", "link.circle.fill", "photo.fill", "music.note",
    "envelope.fill", "globe.asia.australia.fill", "person.fill", "house.fill", "cart.fill", "creditcard.fill", "calendar.circle.fill", "graduationcap.fill"
  ]

  /// 早期构建保存的空心图形名，读取时换成对应的实心图形，不丢用户的选择。
  private static let outlineSuccessors: [String: String] = [
    "folder": "folder.fill", "star": "star.fill", "bookmark": "bookmark.fill",
    "chevron.left.forwardslash.chevron.right": "curlybraces.square.fill", "link": "link.circle.fill", "photo": "photo.fill",
    "briefcase": "briefcase.fill", "person": "person.fill", "lightbulb": "lightbulb.fill",
    "checkmark.circle": "checkmark.circle.fill", "doc": "doc.text.fill", "heart": "heart.fill",
    "house": "house.fill", "cart": "cart.fill", "creditcard": "creditcard.fill",
    "calendar": "calendar.circle.fill", "clock": "clock.fill", "book": "book.fill",
    "graduationcap": "graduationcap.fill", "terminal": "terminal.fill", "envelope": "envelope.fill",
    "globe": "globe.asia.australia.fill", "archivebox": "archivebox.fill"
  ]

  static let selectableColorIndices: [Int] = [0, 1, 2, 3, 4, 5, 7, 8]

  static func style(for tag: String, in styles: [String: WorkspaceTagStyle]) -> WorkspaceTagStyle {
    guard let key = key(for: tag) else { return WorkspaceTagStyle() }
    return sanitized(styles[key] ?? WorkspaceTagStyle())
  }

  static func color(for tag: String, style: WorkspaceTagStyle) -> NSColor {
    guard let index = sanitized(style).colorIndex else { return WorkspaceTagDot.color(for: tag) }
    let item = WorkspaceTagDot.palette[index]
    return NSColor(srgbRed: item.r, green: item.g, blue: item.b, alpha: 1)
  }

  static func setting(
    _ style: WorkspaceTagStyle,
    for tag: String,
    in styles: [String: WorkspaceTagStyle]
  ) -> [String: WorkspaceTagStyle] {
    guard let key = key(for: tag) else { return styles }
    var next = removing(styles, named: tag)
    let style = sanitized(style)
    // 恢复默认是移除覆写，而不是保存一份会妨碍自动配色的默认值。
    if style != WorkspaceTagStyle() { next[key] = style }
    return next
  }

  static func renaming(
    _ styles: [String: WorkspaceTagStyle],
    from: String,
    to: String,
    merging: Bool
  ) -> [String: WorkspaceTagStyle] {
    guard let oldName = HistoryItem.normalizedTag(from), let newName = HistoryItem.normalizedTag(to),
          let fromKey = key(for: from), let toKey = key(for: to) else { return styles }
    // 未改名字直接确认不创建颜色覆写。按字节判断，保留 Unicode 换拼写时的旧色。
    if Array(oldName.utf8) == Array(newName.utf8) { return styles }
    if merging {
      // 目标没有覆写也有自己的自动外观；绝不把源样式带过去。
      let target = style(for: to, in: styles)
      let remaining = fromKey == toKey ? styles : removing(styles, named: from)
      return setting(target, for: to, in: remaining)
    }
    var style = style(for: from, in: styles)
    // 自动色也属于改名前的视觉；冻结原索引，随后恢复默认才重新按新名配色。
    if style.colorIndex == nil { style.colorIndex = WorkspaceTagDot.index(for: oldName) }
    return setting(style, for: to, in: removing(styles, named: from))
  }

  static func removing(_ styles: [String: WorkspaceTagStyle], named tag: String) -> [String: WorkspaceTagStyle] {
    guard let key = key(for: tag) else { return styles }
    return styles.filter { self.key(for: $0.key) != key }
  }

  private static func key(for tag: String) -> String? {
    guard let name = HistoryItem.normalizedTag(tag) else { return nil }
    return WorkspaceTagDot.colorKey(name.precomposedStringWithCanonicalMapping)
      .precomposedStringWithCanonicalMapping
  }

  private static func sanitized(_ style: WorkspaceTagStyle) -> WorkspaceTagStyle {
    WorkspaceTagStyle(
      symbol: style.symbol.map { outlineSuccessors[$0] ?? $0 }.flatMap { symbols.contains($0) ? $0 : nil },
      // 不限于 UI 的八项：重命名可能需要冻结其余合法的自动色。
      colorIndex: style.colorIndex.flatMap { WorkspaceTagDot.palette.indices.contains($0) ? $0 : nil }
    )
  }
}
