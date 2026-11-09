import AppKit
import Defaults

struct StorageType {
  static let files = StorageType(types: [.fileURL])
  static let images = StorageType(types: [.png, .tiff, .jpeg, .heic])
  static let text = StorageType(types: [.html, .rtf, .string])
  static let all = StorageType(types: files.types + images.types + text.types)

  var types: [NSPasteboard.PasteboardType]
}

/// Splits `.fileURL` captures into videos and other files, using the same
/// extension rule as `HistoryItem.contentKind`, so the storage switches agree
/// with the panel's type filter.
enum CaptureFilePolicy {
  enum Decision: Equatable {
    case none
    case allowed
    case rejected
  }

  static func decision(for item: NSPasteboardItem, filesEnabled: Bool, videosEnabled: Bool) -> Decision {
    guard item.types.contains(.fileURL) else { return .none }
    let url = item.string(forType: .fileURL).flatMap(URL.init(string:))
    return decision(for: url, filesEnabled: filesEnabled, videosEnabled: videosEnabled)
  }

  static func decision(for url: URL?, filesEnabled: Bool, videosEnabled: Bool) -> Decision {
    let isVideo = url.map(HistoryItem.isMovieFile) ?? false
    return (isVideo ? videosEnabled : filesEnabled) ? .allowed : .rejected
  }
}

extension Defaults.Keys {
  private static var preferencesSuite: UserDefaults { LabDefaults.suite }

  static let captureClipboard = Key<Bool>("captureClipboard", default: false, suite: preferencesSuite)
  static let protectSensitiveContent = Key<Bool>("protectSensitiveContent", default: true, suite: preferencesSuite)
  static let ignoredApps = Key<[String]>("ignoredApps", default: [], suite: preferencesSuite)
  static let ignoreAllAppsExceptListed = Key<Bool>("ignoreAllAppsExceptListed", default: false, suite: preferencesSuite)
  static let compactRows = Key<Bool>("compactRows", default: false, suite: preferencesSuite)
  static let clearOnQuit = Key<Bool>("clearOnQuit", default: false, suite: preferencesSuite)
  static let clearSystemClipboard = Key<Bool>("clearSystemClipboard", default: false, suite: preferencesSuite)
  static let clipboardCheckInterval = Key<Double>("clipboardCheckInterval", default: 0.5, suite: preferencesSuite)
  static let enabledPasteboardTypes = Key<Set<NSPasteboard.PasteboardType>>(
    "enabledPasteboardTypes", default: Set(StorageType.all.types), suite: preferencesSuite
  )
  /// Videos arrive as file URLs, so they cannot be told apart by pasteboard type.
  /// This switch decides movie-file URLs; `.fileURL` in enabledPasteboardTypes
  /// decides every other file.
  static let saveVideos = Key<Bool>("saveVideos", default: true, suite: preferencesSuite)
  static let highlightMatch = Key<HighlightMatch>("highlightMatch", default: .bold, suite: preferencesSuite)
  static let imageMaxHeight = Key<Int>("imageMaxHeight", default: 40, suite: preferencesSuite)
  static let menuIcon = Key<MenuIcon>("menuIcon", default: .clipboard, suite: preferencesSuite)
  static let migrations = Key<[String: Bool]>("migrations", default: [:], suite: preferencesSuite)
  static let pasteByDefault = Key<Bool>("pasteByDefault", default: false, suite: preferencesSuite)
  static let pinTo = Key<PinsPosition>("pinTo", default: .top, suite: preferencesSuite)
  static let popupPosition = Key<PopupPosition>("popupPosition", default: .center, suite: preferencesSuite)
  static let popupScreen = Key<Int>("popupScreen", default: 0, suite: preferencesSuite)
  static let openPreviewAutomatically = Key<Bool>("openPreviewAutomatically", default: true, suite: preferencesSuite)
  static let removeFormattingByDefault = Key<Bool>("removeFormattingByDefault", default: false, suite: preferencesSuite)
  static let searchMode = Key<Search.Mode>("searchMode", default: .exact, suite: preferencesSuite)
  static let showInStatusBar = Key<Bool>("showInStatusBar", default: true, suite: preferencesSuite)
  static let showRecentCopyInMenuBar = Key<Bool>("showRecentCopyInMenuBar", default: false, suite: preferencesSuite)
  static let showSearch = Key<Bool>("showSearch", default: true, suite: preferencesSuite)
  static let showSpecialSymbols = Key<Bool>("showSpecialSymbols", default: true, suite: preferencesSuite)
  static let size = Key<Int>("historySize", default: 200, suite: preferencesSuite)
  static let sortBy = Key<Sorter.By>("sortBy", default: .lastCopiedAt, suite: preferencesSuite)
  static let suppressClearAlert = Key<Bool>("suppressClearAlert", default: false, suite: preferencesSuite)
  static let suppressQuitAlert = Key<Bool>("suppressQuitAlert", default: false, suite: preferencesSuite)
  static let windowSize = Key<NSSize>("windowSize", default: NSSize(width: PanelSplit.defaultList, height: PanelSplit.defaultHeight), suite: preferencesSuite)
  static let windowPosition = Key<NSPoint>("windowPosition", default: NSPoint(x: 0.5, y: 0.8), suite: preferencesSuite)
  static let showApplicationIcons = Key<Bool>("showApplicationIcons", default: true, suite: preferencesSuite)
  static let showHexColorSwatch = Key<Bool>("showHexColorSwatch", default: true, suite: preferencesSuite)
  static let listColumnWidth = Key<CGFloat>("listColumnWidth", default: PanelSplit.defaultList, suite: preferencesSuite)
  static let previewColumnWidth = Key<CGFloat>("previewColumnWidth", default: PanelSplit.defaultPreview, suite: preferencesSuite)
  static let windowPinned = Key<Bool>("windowPinned", default: false, suite: preferencesSuite)
  /// Rail is always present; this flag widens it to show category names.
  /// Narrow (false) keeps the icons and loses the names; expanded (true) trades
  /// horizontal room for the full labels.
  static let managementRailVisible = Key<Bool>("managementRailVisible", default: false, suite: preferencesSuite)
  /// 展开档的宽度。默认 108，拖窗口左边缘可以拉宽，用来放下很长的分类名。
  static let managementRailWidth = Key<CGFloat>("managementRailWidth", default: 108, suite: preferencesSuite)
  static let workspaceTagDirectory = Key<[String]>(
    WorkspaceTagDirectoryPersistence.keyName,
    default: [],
    suite: preferencesSuite
  )
  static let workspaceTagStyles = Key<[String: WorkspaceTagStyle]>(
    "workspaceTagStyles",
    default: [:],
    suite: preferencesSuite
  )
}
