import Defaults
import KeyboardShortcuts
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
  var panel: FloatingPanel<ContentView>!

  @objc
  private lazy var statusItem: NSStatusItem = {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.behavior = .removalAllowed
    statusItem.button?.action = #selector(performStatusItemClick)
    statusItem.button?.image = Defaults[.menuIcon].image
    statusItem.button?.imagePosition = .imageLeft
    statusItem.button?.target = self
    return statusItem
  }()

  private var isStatusItemDisabled: Bool {
    Defaults[.enabledPasteboardTypes].isEmpty && !Defaults[.saveVideos] && !Defaults[.saveAudio]
  }

  private var statusItemVisibilityObserver: NSKeyValueObservation?

  func applicationWillFinishLaunching(_ notification: Notification) { // swiftlint:disable:this function_body_length
    LabDefaults.resetIsolatedSuite()

    // Bridge FloatingPanel via AppDelegate.
    AppState.shared.appDelegate = self

    Clipboard.shared.onNewCopy { History.shared.add($0) }
    refreshClipboardMonitor()

    Task {
      for await _ in Defaults.updates(.clipboardCheckInterval, initial: false) {
        Clipboard.shared.restart()
      }
    }

    Task {
      for await enabled in Defaults.updates(.captureClipboard, initial: false) {
        if LabRuntime.shouldMonitorPasteboard(settingEnabled: enabled) {
          Clipboard.shared.start()
        } else {
          Clipboard.shared.stop()
        }
      }
    }

    statusItemVisibilityObserver = observe(\.statusItem.isVisible, options: .new) { _, change in
      if let newValue = change.newValue, Defaults[.showInStatusBar] != newValue {
        Defaults[.showInStatusBar] = newValue
      }
    }

    Task {
      for await value in Defaults.updates(.showInStatusBar) {
        statusItem.isVisible = value
      }
    }

    Task {
      for await value in Defaults.updates(.menuIcon, initial: false) {
        statusItem.button?.image = value.image
      }
    }

    synchronizeMenuIconText()
    Task {
      for await value in Defaults.updates(.showRecentCopyInMenuBar) {
        if value {
          statusItem.button?.title = AppState.shared.menuIconText
        } else {
          statusItem.button?.title = ""
        }
      }
    }

    Task {
      for await _ in Defaults.updates([.enabledPasteboardTypes, .saveVideos, .saveAudio]) {
        statusItem.button?.appearsDisabled = isStatusItemDisabled
      }
    }
  }

  func applicationDidFinishLaunching(_ aNotification: Notification) {
    migrateUserDefaults()
    disableUnusedGlobalHotkeys()
    // Older builds leaked content rows on duplicate merge. Drop rows that
    // belong to no item and give the space back to the disk.
    if Storage.shared.purgeOrphanedContents() > 0 {
      Storage.shared.compactInBackground()
    }

    let split = AppState.shared.preview.currentSplit
    panel = FloatingPanel(
      contentRect: NSRect(origin: .zero, size: NSSize(width: split.totalWidth, height: split.height)),
      identifier: Bundle.main.bundleIdentifier ?? LabRuntime.bundleIdentifier,
      statusBarButton: statusItem.button,
      onClose: { AppState.shared.popup.reset() }
    ) {
      ContentView()
    }

    if LabRuntime.isSmoke {
      Task { @MainActor in
        try? await History.shared.load()
        guard !self.panel.isPresented else { return }
        self.panel.open(height: split.height, at: .center)
        let frame = self.panel.frame
        fputs(
          "WitsCopy smoke frame \(Int(frame.width))x\(Int(frame.height)) preview=\(AppState.shared.preview.state)\n",
          stdout
        )
        if LabRuntime.isNarrowSmoke {
          let controller = AppState.shared.preview
          let total = controller.layoutListWidth + controller.layoutPreviewWidth
          controller.contentWidth = PanelSplit.minimumList
          controller.slideoutWidth = max(0, total - controller.layoutListWidth)
          fputs("WitsCopy narrow smoke list=\(controller.layoutListWidth) preview=\(controller.layoutPreviewWidth)\n", stderr)
        }
        if LabRuntime.isAliasSmoke {
          if let image = AppState.shared.history.items.first(where: { $0.item.image != nil }) {
            if !image.isPinned { AppState.shared.performRowAction(.pin, on: image) }
            AppState.shared.navigator.select(item: image)
            fputs("WitsCopy alias smoke item=\(image.title) pinned=\(image.isPinned)\n", stdout)
          }
        }
        if LabRuntime.isManySmoke {
          AppState.shared.navigator.select(item: History.shared.unpinnedItems.last ?? History.shared.items.last)
        }
        if LabRuntime.isEditorSmoke {
          try? await Task.sleep(for: .milliseconds(250))
          AppState.shared.beginTagEdit()
          fputs("WitsCopy editor smoke ready\n", stdout)
        } else if LabRuntime.isPreviewSmoke {
          try? await Task.sleep(for: .milliseconds(250))
          let file = History.shared.items.first { !$0.item.fileURLs.isEmpty }
          AppState.shared.navigator.select(item: file ?? History.shared.items.first)
          fputs("WitsCopy preview smoke ready\n", stdout)
        } else if LabRuntime.isReopenSmoke {
          try? await Task.sleep(for: .milliseconds(250))
          let target = History.shared.items.first { $0.title.contains("Standup") }
            ?? History.shared.items.last
          AppState.shared.navigator.select(item: target)
          fputs("WitsCopy reopen target=\(target?.title ?? "nil") immediate=\(AppState.shared.navigator.leadHistoryItem?.title ?? "nil")\n", stdout)
          try? await Task.sleep(for: .milliseconds(200))
          fputs("WitsCopy reopen before=\(AppState.shared.navigator.leadHistoryItem?.title ?? "nil")\n", stdout)
          self.panel.close()
          try? await Task.sleep(for: .milliseconds(300))
          self.panel.open(height: split.height, at: .center)
          try? await Task.sleep(for: .milliseconds(500))
          fputs("WitsCopy reopen after=\(AppState.shared.navigator.leadHistoryItem?.title ?? "nil")\n", stdout)
        } else {
          fputs("WitsCopy smoke ready\n", stdout)
        }
        if LabRuntime.isImageSmoke, let big = AppState.shared.history.items.first(where: { $0.title == "合成大图" }) {
          AppState.shared.navigator.select(item: big)
          fputs("WitsCopy image smoke selected=\(big.title)\n", stdout)
        }
        fflush(stdout)
      }
    }
  }

  private func refreshClipboardMonitor() {
    if LabRuntime.shouldMonitorPasteboard(settingEnabled: Defaults[.captureClipboard]) {
      Clipboard.shared.start()
    } else {
      Clipboard.shared.stop()
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    panel.toggle(height: AppState.shared.popup.height)
    return true
  }

  func applicationWillTerminate(_ notification: Notification) {
    if LabRuntime.isSmoke { LabSmokeCanvas.cleanup() }
    if Defaults[.clearOnQuit] {
      AppState.shared.history.clear()
    }
  }

  private func ensureMigration(key: String, _ action: () -> Void) {
    if Defaults[.migrations][key] != true {
      action()
      Defaults[.migrations][key] = true
    }
  }

  private func migrateUserDefaults() {
    ensureMigration(key: "2024-07-01-version-2") {
      // Retain the live search-visibility preference from older versions.
      let suite = LabDefaults.suite
      if suite.object(forKey: "hideSearch") != nil {
        Defaults[.showSearch] = !suite.bool(forKey: "hideSearch")
        suite.removeObject(forKey: "hideSearch")
      }
    }
    if LabDefaults.suite.string(forKey: "menuIcon") == "witsCopy" {
      Defaults[.menuIcon] = .clipboard
    }
    ensureMigration(key: "2025-07-04-add-jpeg-heic") {
      var types = Defaults[.enabledPasteboardTypes]
      if !types.intersection(StorageType.images.types).isEmpty {
        types.formUnion(StorageType.images.types)
      }
      Defaults[.enabledPasteboardTypes] = types
    }
    ensureMigration(key: "2026-11-09-no-preview-shortcut") {
      // The old ⌃Space default was stored on first launch; drop it so the
      // preview has no shortcut, matching the new default.
      KeyboardShortcuts.setShortcut(nil, for: .togglePreview)
    }

    // The following defaults are not used in Maccy 2.x
    // and should be removed in 3.x.
    // - LaunchAtLogin__hasMigrated
    // - avoidTakingFocus
    // - saratovSeparator
    // - maxMenuItemLength
    // - maxMenuItems
  }

  @objc
  private func performStatusItemClick() {
    panel.toggle(height: AppState.shared.popup.height, at: .statusItem)
  }

  private func synchronizeMenuIconText() {
    _ = withObservationTracking {
      AppState.shared.menuIconText
    } onChange: {
      DispatchQueue.main.async {
        if Defaults[.showRecentCopyInMenuBar] {
          self.statusItem.button?.title = AppState.shared.menuIconText
        }
        self.synchronizeMenuIconText()
      }
    }
  }

  private func disableUnusedGlobalHotkeys() {
    guard !LabRuntime.isIsolated else { return }
    let names: [KeyboardShortcuts.Name] = [.delete, .pin, .tag, .togglePreview]
    KeyboardShortcuts.disable(names)

    NotificationCenter.default.addObserver(
      forName: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange"),
      object: nil,
      queue: nil
    ) { notification in
      if let name = notification.userInfo?["name"] as? KeyboardShortcuts.Name, names.contains(name) {
        KeyboardShortcuts.disable(name)
      }
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if AppState.shared.quitAuthorized || Defaults[.suppressQuitAlert] {
      return .terminateNow
    }
    AppState.shared.quit()
    return .terminateCancel
  }
}
