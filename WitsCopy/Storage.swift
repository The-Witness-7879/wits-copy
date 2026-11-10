import Foundation
import SQLite3
import SwiftData

/// Process identity and isolation. Storage location, notifications and pasteboard
/// access all hang off this, so tests and smoke runs never touch real user data.
enum LabRuntime {
  static let bundleIdentifier = "local.thewitness.WitsCopy"
  static let displayName = "Wit's Copy"
  static let storageFolderName = "Wit's Copy"
  static let isolatedDefaultsSuite = "local.thewitness.WitsCopy.isolated"
  static var isPreview: Bool {
    ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
  }

  static var isUnitTestProcess: Bool {
    let env = ProcessInfo.processInfo.environment
    if env["XCTestConfigurationFilePath"] != nil || env["XCTestSessionIdentifier"] != nil {
      return true
    }
    return NSClassFromString("XCTestCase") != nil
  }

  static let snippetSource = "local.thewitness.WitsCopy.snippet"

  static var fixturesDirectory: URL? {
    guard let flag = CommandLine.arguments.firstIndex(of: "--lab-fixtures"),
          CommandLine.arguments.indices.contains(flag + 1) else {
      return nil
    }
    let url = URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  /// Opens the tag editor after the smoke panel. Display only, not an interaction pass.
  static var isEditorSmoke: Bool {
    CommandLine.arguments.contains("--lab-editor-smoke")
  }

  static var isPreviewSmoke: Bool {
    CommandLine.arguments.contains("--lab-preview-smoke")
  }

  /// Fill the list with synthetic rows and scroll to the end, for spacing checks.
  static var isManySmoke: Bool {
    CommandLine.arguments.contains("--lab-many-smoke")
  }

  /// Drag the divider to the narrowest allowed list, to check the header still fits.
  static var isNarrowSmoke: Bool {
    CommandLine.arguments.contains("--lab-narrow-smoke")
  }

  /// Add a large synthetic image and select it, to check preview bounds.
  static var isImageSmoke: Bool {
    CommandLine.arguments.contains("--lab-image-smoke")
  }

  /// Select and pin the synthetic image so title editing can be exercised on non-text content.
  static var isAliasSmoke: Bool {
    CommandLine.arguments.contains("--lab-alias-smoke")
  }

  /// One in-memory rich item. Still isolated: no pasteboard read and no real history.
  static var isRichSmoke: Bool {
    CommandLine.arguments.contains("--lab-rich-smoke")
  }

  /// Hide and reopen the smoke panel without any user input, printing the restored selection.
  static var isReopenSmoke: Bool {
    CommandLine.arguments.contains("--lab-reopen-smoke")
  }

  /// Adds one synthetic link and selects it, so the preview's open button can
  /// be clicked for real. Still isolated: no pasteboard read and no real history.
  static var isLinkSmoke: Bool {
    CommandLine.arguments.contains("--lab-link-smoke")
  }

  static var isSmoke: Bool {
    CommandLine.arguments.contains("--lab-smoke") || isEditorSmoke || isPreviewSmoke || isReopenSmoke || isManySmoke || isNarrowSmoke || isAliasSmoke || isImageSmoke || isRichSmoke || isLinkSmoke
  }

  static var isEnableTesting: Bool {
    CommandLine.arguments.contains("enable-testing")
  }

  /// Tests, previews, smoke, and enable-testing never open a file store or the real pasteboard.
  static var isIsolated: Bool {
    isPreview || isUnitTestProcess || isSmoke || isEnableTesting
  }

  static var captureRequested: Bool {
    CommandLine.arguments.contains("--capture")
  }

  static func shouldMonitorPasteboard(settingEnabled: Bool) -> Bool {
    if isIsolated { return false }
    return captureRequested || settingEnabled
  }

  static var defaultStoreURL: URL {
    URL.applicationSupportDirectory
      .appending(path: storageFolderName, directoryHint: .isDirectory)
      .appending(path: "Storage.sqlite")
  }


  static var storeURL: URL { defaultStoreURL }

  /// Tests, previews and smoke instances never post notifications.
  static var suppressesNotifications: Bool { isIsolated }

  /// Upstream Maccy hardcodes Application Support/Maccy/Storage.sqlite. "Wit's Copy" must not match.
  static func isUpstreamStore(_ url: URL) -> Bool {
    url.standardizedFileURL.path.hasSuffix("/Maccy/Storage.sqlite")
  }
}

enum LabDefaults {
  static var suite: UserDefaults {
    guard LabRuntime.isIsolated else { return .standard }
    return UserDefaults(suiteName: LabRuntime.isolatedDefaultsSuite) ?? .standard
  }

  static func resetIsolatedSuite() {
    guard LabRuntime.isIsolated else { return }
    suite.removePersistentDomain(forName: LabRuntime.isolatedDefaultsSuite)
  }
}

@MainActor
class Storage {
  static let shared = Storage()

  var container: ModelContainer
  var context: ModelContext { container.mainContext }
  let isInMemory: Bool
  let url: URL

  /// Tests replace this to observe or fail a save. Nil uses `ModelContext.save`.
  var saveImplementation: (() throws -> Void)?

  func save() throws {
    if let saveImplementation {
      try saveImplementation()
      return
    }
    try context.save()
  }

  var size: String {
    guard !isInMemory,
          let size = try? url.resourceValues(forKeys: [.fileSizeKey]).allValues.first?.value as? Int64,
          size > 1 else {
      return ""
    }
    return ByteCountFormatter().string(fromByteCount: size)
  }

  /// Deletes content rows whose item is gone. Returns how many were removed.
  /// A batch delete: orphans have no relationships left to cascade, and their
  /// image bytes are never loaded into memory.
  @discardableResult
  func purgeOrphanedContents() -> Int {
    let orphans = FetchDescriptor<HistoryItemContent>(predicate: #Predicate { $0.item == nil })
    let count = (try? context.fetchCount(orphans)) ?? 0
    guard count > 0 else { return 0 }
    do {
      try context.delete(model: HistoryItemContent.self, where: #Predicate { $0.item == nil })
      try context.save()
    } catch {
      return 0
    }
    return count
  }

  /// SQLite keeps deleted pages inside the file, so clearing history never
  /// shrank Storage.sqlite. Checkpoint the WAL and VACUUM on a background
  /// connection. Best effort: a busy store is simply left for next time.
  func compactInBackground() {
    guard !isInMemory else { return }
    let path = url.path
    Task.detached(priority: .utility) {
      _ = StoreCompactor.compact(path: path)
    }
  }

  init(inMemory: Bool? = nil, url: URL? = nil) {
    let memory = inMemory ?? LabRuntime.isIsolated
    let resolved = url ?? LabRuntime.storeURL
    precondition(
      !LabRuntime.isUpstreamStore(resolved),
      "Refusing to open the upstream Maccy database at \(resolved.path)"
    )
    self.isInMemory = memory
    self.url = resolved

    let config = memory
      ? ModelConfiguration(isStoredInMemoryOnly: true)
      : ModelConfiguration(url: resolved)

    do {
      container = try ModelContainer(for: HistoryItem.self, configurations: config)
    } catch {
      fatalError("Cannot load database: \(error.localizedDescription).")
    }
  }
}

/// Shrinks the store file after deletes. Runs on its own SQLite connection so
/// it never blocks the main context; SQLite's locking keeps them consistent.
enum StoreCompactor {
  /// Returns true when VACUUM completed.
  @discardableResult
  static func compact(path: String) -> Bool {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
      sqlite3_close(db)
      return false
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 3000)
    guard sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil) == SQLITE_OK,
          sqlite3_exec(db, "VACUUM;", nil, nil, nil) == SQLITE_OK else {
      return false
    }
    // VACUUM in WAL mode writes through the log; fold it back into the file.
    _ = sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
    return true
  }
}
