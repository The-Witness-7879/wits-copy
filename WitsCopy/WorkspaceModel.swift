import Foundation

/// 工作区筛选与条目标签模型。
/// 描述"当前显示什么"，不拥有历史数据。

enum WorkspaceSection: String, CaseIterable, Identifiable, Sendable {
  case all
  case tags
  case pins
  case ignore

  var id: String { rawValue }

  /// Sidebar section buttons. Tag filters are per-label rail items, not a page.
  /// `tags`, `pins` and `ignore` stay on the enum only so older in-memory state
  /// can resolve. Pins are a row action, not a second list.
  static let primaryRail: [WorkspaceSection] = [.all]

  /// Opening the panel must not land on a removed page.
  static func resolvedForOpen(_ section: WorkspaceSection) -> WorkspaceSection {
    switch section {
    case .all: return section
    case .tags, .pins, .ignore: return .all
    }
  }

  var showsHistory: Bool { true }
}


/// Rail selection that does not own a view. Repeat tag clicks keep the filter.
enum WorkspaceRailPolicy {
  static func accessibilityIdentifier(for tag: String) -> String {
    "lab-rail-tag-\(tag)"
  }

  static func isAllSelected(section: WorkspaceSection, tagFilter: String?) -> Bool {
    section == .all && tagFilter == nil
  }

  /// Pins is an aggregate, not a category. A tag filter and this highlight cannot both be on.
  static func isPinsSelected(section: WorkspaceSection, tagFilter: String?) -> Bool {
    section == .pins && tagFilter == nil
  }

  static func isTagSelected(_ tag: String, tagFilter: String?) -> Bool {
    guard let tagFilter else { return false }
    return tagFilter.caseInsensitiveCompare(tag) == .orderedSame
  }

  static func editFailureMessage(storageError: String?) -> String {
    if let storageError, !storageError.isEmpty {
      return storageError
    }
    return NSLocalizedString("tag_edit_failed", comment: "")
  }

  @MainActor
  static func selectAll(_ appState: AppState) {
    appState.workspaceSection = .all
    appState.history.tagFilter = nil
  }

  /// Selecting a tag never clears it. `selectTag` keeps an equal filter.
  @MainActor
  static func selectTag(_ raw: String, in appState: AppState) {
    appState.workspaceSection = .all
    appState.history.selectTag(raw)
  }

  @MainActor
  @discardableResult
  static func rename(_ tag: String, to draft: String, in appState: AppState) -> Bool {
    appState.storageError = nil
    guard appState.history.renameTag(from: tag, to: draft) else { return false }
    appState.workspaceSection = .all
    if let name = HistoryItem.normalizedTag(draft) {
      appState.history.selectTag(name)
    }
    return true
  }

  @MainActor
  @discardableResult
  static func merge(_ tag: String, into draft: String, in appState: AppState) -> Bool {
    rename(tag, to: draft, in: appState)
  }

  @MainActor
  @discardableResult
  static func delete(_ tag: String, in appState: AppState) -> Bool {
    let wasCurrent = isTagSelected(tag, tagFilter: appState.history.tagFilter)
    appState.storageError = nil
    guard appState.history.deleteTag(named: tag) else { return false }
    if wasCurrent {
      appState.workspaceSection = .all
      appState.history.tagFilter = nil
    }
    return true
  }
}


enum WorkspaceRowAction: String, Equatable, Sendable {
  case tag
  case pin
  case delete
}


enum WorkspacePresentation {
  /// The only condition that may construct the preview renderer, including Quick Look.
  static func allowsPreview(
    panelPresented: Bool,
    previewOpen: Bool,
    section: WorkspaceSection
  ) -> Bool {
    panelPresented && previewOpen && section.showsHistory
  }
}


enum WorkspaceTagCatalog {
  /// Rename or merge a label. The item list itself is not an input that can shrink.
  static func rename(_ tags: [String], from rawFrom: String, to rawTo: String) -> [String]? {
    guard let from = HistoryItem.normalizedTag(rawFrom),
          let to = HistoryItem.normalizedTag(rawTo) else { return nil }
    let mapped = tags.map { $0.caseInsensitiveCompare(from) == .orderedSame ? to : $0 }
    return HistoryItem.unionTags([], mapped)
  }

  static func remove(_ tags: [String], named raw: String) -> [String]? {
    guard let name = HistoryItem.normalizedTag(raw) else { return nil }
    return tags.filter { $0.caseInsensitiveCompare(name) != .orderedSame }
  }
}


struct WorkspaceItemLabel: Equatable, Sendable {
  var rowTitle: String
  var tooltip: String?
  var isFile: Bool

  /// Display only. Callers must not write this back into pasteboard contents.
  static func make(storedTitle: String, filePaths: [String]) -> WorkspaceItemLabel {
    if let path = filePaths.first(where: { !$0.isEmpty }) {
      let name = URL(fileURLWithPath: path).lastPathComponent
      return WorkspaceItemLabel(
        rowTitle: name.isEmpty ? storedTitle : name,
        tooltip: path,
        isFile: true
      )
    }
    if storedTitle.hasPrefix("file://"),
       let url = URL(string: storedTitle),
       !url.lastPathComponent.isEmpty {
      let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
      return WorkspaceItemLabel(rowTitle: name, tooltip: storedTitle, isFile: true)
    }
    return WorkspaceItemLabel(rowTitle: storedTitle, tooltip: nil, isFile: false)
  }
}
