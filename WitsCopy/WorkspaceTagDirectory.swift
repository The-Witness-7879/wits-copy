import AppKit
import Defaults
import Foundation

/// Ordered tag names that exist even when no history item carries them.
/// Creating a name writes this directory only. It must not insert a history item.
enum WorkspaceTagDirectory {
  /// Catalog order, then item-only tags in the order given. First spelling wins.
  /// An empty catalog entry stays when `itemTags` is empty.
  static func ordered(stored: [String], itemTags: [String]) -> [String] {
    var result: [String] = []
    func append(_ raw: String) {
      guard let name = HistoryItem.normalizedTag(raw) else { return }
      if result.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return }
      result.append(name)
    }
    stored.forEach(append)
    itemTags.forEach(append)
    return result
  }

  /// New name is last, so it sits immediately above the add button.
  /// Item tags missing from the catalog are adopted in front of that new name.
  static func inserting(_ raw: String, into stored: [String], itemTags: [String]) -> Result<[String], WorkspaceTagDirectoryError> {
    guard let name = HistoryItem.normalizedTag(raw) else { return .failure(.invalidName) }
    let current = ordered(stored: stored, itemTags: itemTags)
    if current.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
      return .failure(.duplicate)
    }
    return .success(current + [name])
  }

  /// What a typed name means when the user confirms the create form.
  /// A name that already exists is not an error to show in a create sheet:
  /// it is that category, so confirming it switches there.
  enum CreateResolution: Equatable {
    case selectExisting(String)
    case create(String)
    case invalid
  }

  static func resolveCreate(_ raw: String, in existing: [String]) -> CreateResolution {
    guard let name = HistoryItem.normalizedTag(raw) else { return .invalid }
    if let match = existing.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
      return .selectExisting(match)
    }
    return .create(name)
  }

  static func removing(_ stored: [String], named raw: String) -> [String]? {
    WorkspaceTagCatalog.remove(stored, named: raw)
  }

  /// Keeps the renamed label in its previous slot. Invalid names return nil.
  static func renaming(_ stored: [String], from rawFrom: String, to rawTo: String) -> [String]? {
    WorkspaceTagCatalog.rename(stored, from: rawFrom, to: rawTo)
  }
}

enum WorkspaceTagDirectoryError: Equatable, Error {
  case invalidName
  case duplicate
  case persistFailed
  case historyFailed
  case dropRejected
  case assignFailed

  var messageKey: String {
    switch self {
    case .invalidName: return "tag_directory_invalid"
    case .duplicate: return "tag_directory_duplicate"
    case .persistFailed: return "tag_directory_persist_failed"
    case .historyFailed: return "tag_edit_failed"
    case .dropRejected: return "tag_drop_rejected"
    case .assignFailed: return "tag_drop_assign_failed"
    }
  }

  var message: String { WorkspaceTagCopy.text(messageKey) }
}

protocol WorkspaceTagDirectoryWriting {
  func loadNames() -> [String]
  func saveNames(_ names: [String]) -> Bool
}

enum WorkspaceTagDirectoryPersistence {
  /// Defaults key names cannot contain a dot.
  static let keyName = "workspaceTagDirectory"
}

struct DefaultsTagDirectoryWriter: WorkspaceTagDirectoryWriting {
  func loadNames() -> [String] {
    WorkspaceTagDirectory.ordered(stored: Defaults[.workspaceTagDirectory], itemTags: [])
  }

  func saveNames(_ names: [String]) -> Bool {
    let previous = Defaults[.workspaceTagDirectory]
    Defaults[.workspaceTagDirectory] = names
    if Defaults[.workspaceTagDirectory] == names { return true }
    Defaults[.workspaceTagDirectory] = previous
    return false
  }
}

enum WorkspaceTagCreateDecision: Equatable {
  case commit(String)
  case cancel
}

/// Sidebar hit and glyph growth that still fits the existing 36pt rail.
/// Widening the rail would shrink list content; 25% is the largest step that does not.
enum WorkspaceRailMetrics {
  static let baselineHit: CGFloat = 28
  static let growth: CGFloat = 1.25
  static var hit: CGFloat { baselineHit * growth }
  static var cornerRadius: CGFloat { 6 * growth }
  /// 选中底色离窗体左缘 8pt，与关闭按钮同一条左边线；右侧不再留白，
  /// 条目列自带的 8pt 就是行与条目之间的间距，左右两边因此一样宽。
  /// 行内 6pt 让 16pt 图标槽在收缩态的正中（行宽 28，左右各 6），
  /// 展开态也沿用同一个值，图标不因换档而横移。
  static let railLeading: CGFloat = WorkspaceInsets.outer
  static let railTrailing: CGFloat = 0
  static let leadingInset: CGFloat = 6
}

/// Top-aligned content order: section, tags, add. Y grows downward.
/// Frames are content coordinates. The add button is never pinned to the viewport bottom.
enum WorkspaceRailFlow {
  static let spacing: CGFloat = 4
  static let verticalPadding: CGFloat = 6
}

enum WorkspaceTagDot {
  static let palette: [(r: CGFloat, g: CGFloat, b: CGFloat)] = [
    (0.90, 0.30, 0.28),
    (0.95, 0.55, 0.18),
    (0.92, 0.74, 0.18),
    (0.36, 0.72, 0.32),
    (0.16, 0.68, 0.62),
    (0.20, 0.52, 0.90),
    (0.40, 0.36, 0.86),
    (0.62, 0.32, 0.82),
    (0.86, 0.32, 0.58),
    (0.55, 0.40, 0.28),
    (0.20, 0.45, 0.72),
    (0.72, 0.28, 0.28)
  ]

  static func colorKey(_ tag: String) -> String {
    tag.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
  }

  static func index(for tag: String) -> Int {
    var hash: UInt32 = 2166136261
    for byte in colorKey(tag).utf8 {
      hash ^= UInt32(byte)
      hash &*= 16777619
    }
    return Int(hash % UInt32(palette.count))
  }

  static func color(for tag: String) -> NSColor {
    let item = palette[index(for: tag)]
    return NSColor(srgbRed: item.r, green: item.g, blue: item.b, alpha: 1)
  }
}

enum WorkspaceRailFeedback {
  static func accessibilityValue(selected: Bool, dropTarget: Bool) -> String {
    switch (selected, dropTarget) {
    case (false, false): return ""
    case (true, false): return "selected"
    case (false, true): return "drop-target"
    case (true, true): return "selected drop-target"
    }
  }
}

enum WorkspaceDropHighlight {
  enum Event: Equatable {
    case entered(Bool)
    case updated(Bool)
    case exited
    case performed
    case concluded
    case ended
  }

  static func highlighted(after event: Event) -> Bool {
    switch event {
    case .entered(let allowed), .updated(let allowed):
      return allowed
    case .exited, .performed, .concluded, .ended:
      return false
    }
  }

  /// `.copy` keeps the source row. It does not duplicate the history item; the drop appends a tag.
  static func operation(allowed: Bool) -> NSDragOperation {
    allowed ? .copy : []
  }
}

enum WorkspaceTagCreatePlacement {
  static let formWidth: CGFloat = 220

  // One shared set of metrics, so the form view and `formSize` cannot drift:
  // the panel is exactly as tall as the content it holds.
  static let contentInset: CGFloat = 12
  static let titleHeight: CGFloat = 17
  static let fieldHeight: CGFloat = GlassField.height
  static let buttonHeight: CGFloat = 24
  static let errorHeight: CGFloat = 16
  static let titleToField: CGFloat = 8
  static let fieldToButtons: CGFloat = 10
  static let buttonGap: CGFloat = 8
  static let errorGap: CGFloat = 8

  /// Height follows content: no error row when there is no error.
  static func formSize(showsError: Bool) -> CGSize {
    var height = contentInset + titleHeight + titleToField + fieldHeight
      + fieldToButtons + buttonHeight + contentInset
    if showsError {
      height += errorGap + errorHeight
    }
    return CGSize(width: formWidth, height: height)
  }
}

enum WorkspaceTagDirectoryActions {
  @discardableResult
  static func apply(
    _ decision: WorkspaceTagCreateDecision,
    stored: [String],
    itemTags: [String],
    save: ([String]) -> Bool
  ) -> Result<[String], WorkspaceTagDirectoryError> {
    switch decision {
    case .cancel:
      return .success(stored)
    case .commit(let draft):
      switch WorkspaceTagDirectory.inserting(draft, into: stored, itemTags: itemTags) {
      case .failure(let error):
        return .failure(error)
      case .success(let next):
        guard save(next) else { return .failure(.persistFailed) }
        return .success(next)
      }
    }
  }

  static func create(
    draft: String,
    itemTags: [String],
    writer: WorkspaceTagDirectoryWriting = DefaultsTagDirectoryWriter()
  ) -> Result<String, WorkspaceTagDirectoryError> {
    let stored = writer.loadNames()
    switch apply(.commit(draft), stored: stored, itemTags: itemTags, save: writer.saveNames) {
    case .failure(let error):
      return .failure(error)
    case .success(let next):
      guard let name = next.last else { return .failure(.persistFailed) }
      return .success(name)
    }
  }

  static func sync(
    itemTags: [String],
    writer: WorkspaceTagDirectoryWriting = DefaultsTagDirectoryWriter()
  ) -> Result<[String], WorkspaceTagDirectoryError> {
    let stored = writer.loadNames()
    let next = WorkspaceTagDirectory.ordered(stored: stored, itemTags: itemTags)
    if next == stored { return .success(stored) }
    guard writer.saveNames(next) else { return .failure(.persistFailed) }
    return .success(next)
  }

  static func rename(
    from: String,
    to: String,
    merging: Bool = false,
    itemTagsAfter: () -> [String],
    renameHistory: () -> Bool,
    rollbackHistory: (_ restoredName: String) -> Bool,
    writer: WorkspaceTagDirectoryWriting = DefaultsTagDirectoryWriter()
  ) -> Result<Void, WorkspaceTagDirectoryError> {
    let stored = writer.loadNames()
    guard renameHistory() else { return .failure(.historyFailed) }
    guard let renamed = WorkspaceTagDirectory.renaming(stored, from: from, to: to) else {
      _ = rollbackHistory(from)
      return .failure(.invalidName)
    }
    let next = WorkspaceTagDirectory.ordered(stored: renamed, itemTags: itemTagsAfter())
    guard writer.saveNames(next) else {
      _ = rollbackHistory(from)
      return .failure(.persistFailed)
    }
    // 重命名到已有分类也会合并；和显式合并一样，保留目标外观。
    let targetExisted = HistoryItem.normalizedTag(to).map { target in
      stored.contains { $0.caseInsensitiveCompare(target) == .orderedSame && $0.caseInsensitiveCompare(from) != .orderedSame }
    } ?? false
    // 历史与目录都已成功，才迁移外观；任何失败路径保留原覆写。
    let styles = Defaults[.workspaceTagStyles]
    let nextStyles = WorkspaceTagAppearance.renaming(styles, from: from, to: to, merging: merging || targetExisted)
    if nextStyles != styles { Defaults[.workspaceTagStyles] = nextStyles }
    return .success(())
  }

  static func delete(
    named name: String,
    itemTags: [String],
    deleteHistory: () -> Bool,
    writer: WorkspaceTagDirectoryWriting = DefaultsTagDirectoryWriter()
  ) -> Result<Void, WorkspaceTagDirectoryError> {
    let stored = writer.loadNames()
    guard let stripped = WorkspaceTagDirectory.removing(stored, named: name) else {
      return .failure(.invalidName)
    }
    let remaining = itemTags.filter { $0.caseInsensitiveCompare(name) != .orderedSame }
    let next = WorkspaceTagDirectory.ordered(stored: stripped, itemTags: remaining)
    if next != stored {
      guard writer.saveNames(next) else { return .failure(.persistFailed) }
    }
    guard deleteHistory() else {
      if next != stored {
        _ = writer.saveNames(stored)
      }
      return .failure(.historyFailed)
    }
    Defaults[.workspaceTagStyles] = WorkspaceTagAppearance.removing(Defaults[.workspaceTagStyles], named: name)
    return .success(())
  }
}

struct WorkspaceItemDropLiveItem: Equatable {
  var id: UUID
  var removed: Bool
}

enum WorkspaceItemDrop {
  static func accepts(_ token: UUID, live: [WorkspaceItemDropLiveItem]) -> Bool {
    live.contains { $0.id == token && !$0.removed }
  }

  /// 单标签模型：拖到分类是把条目移到该分类，不是追加。
  static func set(
    token: UUID?,
    tag: String?,
    live: [WorkspaceItemDropLiveItem],
    apply: (UUID, String?) -> Bool
  ) -> Result<Void, WorkspaceTagDirectoryError> {
    guard let token, accepts(token, live: live) else { return .failure(.dropRejected) }
    if let tag, HistoryItem.normalizedTag(tag) == nil { return .failure(.invalidName) }
    guard apply(token, tag) else { return .failure(.assignFailed) }
    return .success(())
  }
}

enum WorkspaceItemDrag {
  /// Not `public.utf8-plain-text`. External text cannot satisfy this type.
  static let typeIdentifier = "local.thewitness.WitsCopy.history-item"
  static var pasteboardType: NSPasteboard.PasteboardType { NSPasteboard.PasteboardType(typeIdentifier) }
  static let suggestedGhostSize = NSSize(width: 220, height: 30)

  static func encode(_ itemID: UUID) -> Data {
    Data(itemID.uuidString.utf8)
  }

  static func token(typeIdentifiers: [String], data: Data?) -> UUID? {
    guard typeIdentifiers.contains(typeIdentifier), let data else { return nil }
    guard let raw = String(data: data, encoding: .utf8) else { return nil }
    return UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// In-process source, our type, and a live non-removed decorator id. All three are required.
  static func acceptedItemID(
    typeIdentifiers: [String],
    data: Data?,
    sourceInProcess: Bool,
    live: [WorkspaceItemDropLiveItem]
  ) -> UUID? {
    guard sourceInProcess, let token = token(typeIdentifiers: typeIdentifiers, data: data) else { return nil }
    return WorkspaceItemDrop.accepts(token, live: live) ? token : nil
  }

  static func acceptedItemID(
    pasteboard: NSPasteboard,
    sourceInProcess: Bool,
    live: [WorkspaceItemDropLiveItem]
  ) -> UUID? {
    let types = pasteboard.types?.map(\.rawValue) ?? []
    return acceptedItemID(
      typeIdentifiers: types,
      data: pasteboard.data(forType: pasteboardType),
      sourceInProcess: sourceInProcess,
      live: live
    )
  }

  /// `.copy` means the row stays. It is not a license to duplicate the history item.
  static func sourceOperation(withinApplication: Bool) -> NSDragOperation {
    withinApplication ? .copy : []
  }

  /// Native drag image. Do not use the pasteboard payload or a decoded preview as the ghost.
  /// Drawn in the panel's own language: a translucent rounded plate like the
  /// row highlight, a hairline edge, secondary icon, label in the row font.
  /// Call inside the source view's drawing appearance so light and dark match.
  static func draggingImage(title: String) -> NSImage {
    let size = suggestedGhostSize
    let image = NSImage(size: size)
    image.lockFocus()
    let rect = NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
    let path = NSBezierPath(roundedRect: rect, xRadius: Popup.cornerRadius, yRadius: Popup.cornerRadius)
    NSColor.windowBackgroundColor.withAlphaComponent(0.82).setFill()
    path.fill()
    NSColor.labelColor.withAlphaComponent(0.06).setFill()
    path.fill()
    NSColor.labelColor.withAlphaComponent(0.14).setStroke()
    path.lineWidth = 1
    path.stroke()
    let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
      .applying(.init(hierarchicalColor: .secondaryLabelColor))
    let symbol = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)?
      .withSymbolConfiguration(config)
    let symbolSize = symbol?.size ?? .zero
    symbol?.draw(in: NSRect(
      x: 10, y: (size.height - symbolSize.height) / 2,
      width: symbolSize.width, height: symbolSize.height
    ))
    let label = title.isEmpty ? WorkspaceTagCopy.text("tag_drop_ghost") : String(title.prefix(60))
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byTruncatingTail
    let string = NSAttributedString(string: label, attributes: [
      .font: NSFont.systemFont(ofSize: 12),
      .foregroundColor: NSColor.labelColor,
      .paragraphStyle: style
    ])
    let textHeight = string.size().height
    string.draw(in: NSRect(x: 30, y: (size.height - textHeight) / 2, width: size.width - 40, height: textHeight))
    image.unlockFocus()
    return image
  }
}

/// Keys listed for integration. Do not treat a missing strings entry as an empty tooltip.
enum WorkspaceTagCopy {
  static let english: [String: String] = [
    "tag_directory_add": "New tag",
    "tag_directory_add_help": "New tag",
    "tag_directory_create": "Create",
    "tag_directory_create_help": "Create tag",
    "tag_directory_cancel": "Cancel",
    "tag_directory_cancel_help": "Cancel",
    "tag_directory_name": "Tag name",
    "tag_directory_persist_failed": "Could not save the tag directory.",
    "tag_directory_invalid": "A tag cannot be empty, contain spaces, or be longer than 32 characters.",
    "tag_directory_duplicate": "That tag already exists.",
    "tag_drop_rejected": "Only a still-existing item from this app can be dropped onto a tag.",
    "tag_drop_assign_failed": "Could not add the tag to that item.",
    "tag_drop_ghost": "Item"
  ]

  static let chinese: [String: String] = [
    "tag_directory_add": "新建标签",
    "tag_directory_add_help": "新建标签",
    "tag_directory_create": "创建",
    "tag_directory_create_help": "创建标签",
    "tag_directory_cancel": "取消",
    "tag_directory_cancel_help": "取消",
    "tag_directory_name": "标签名",
    "tag_directory_persist_failed": "未能保存标签目录。",
    "tag_directory_invalid": "标签不能为空、不能含空格，且不能超过 32 个字符。",
    "tag_directory_duplicate": "这个标签已经存在。",
    "tag_drop_rejected": "只能把本应用里仍存在的内容拖到标签上。",
    "tag_drop_assign_failed": "未能把标签加到这条上。",
    "tag_drop_ghost": "内容"
  ]

  static func text(_ key: String) -> String {
    let localized = NSLocalizedString(key, comment: "")
    if localized != key { return localized }
    let chinesePreferred = Locale.preferredLanguages.first?.hasPrefix("zh") == true
    return (chinesePreferred ? chinese : english)[key] ?? english[key] ?? key
  }
}
