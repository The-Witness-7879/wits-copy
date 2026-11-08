// swiftlint:disable file_length
import AppKit
import Defaults
import Foundation
import Logging
import Observation
import Sauce
import SwiftData

@Observable
class History: ItemsContainer { // swiftlint:disable:this type_body_length
  static let shared = History()
  let logger = Logger(label: "local.thewitness.WitsCopy")

  var items: [HistoryItemDecorator] = []
  var pasteStack: PasteStack?

  var pinnedItems: [HistoryItemDecorator] { items.filter(\.isPinned) }
  var unpinnedItems: [HistoryItemDecorator] { items.filter(\.isUnpinned) }

  var searchQuery: String = "" {
    didSet {
      // Reassigning the same query must not reset the user's selection.
      guard searchQuery != oldValue else { return }
      throttler.throttle { [self] in
        applySearch(highlightFirst: true)
      }
    }
  }

  var tagFilter: String? {
    didSet {
      guard tagFilter != oldValue else { return }
      applySearch(highlightFirst: true)
    }
  }

  var typeFilter: HistoryItem.ContentKind? {
    didSet {
      guard typeFilter != oldValue else { return }
      applySearch(highlightFirst: true)
    }
  }

  var pressedShortcutItem: HistoryItemDecorator? {
    guard let event = NSApp.currentEvent else {
      return nil
    }

    let modifierFlags = event.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting(.capsLock)

    guard HistoryItemAction(modifierFlags) != .unknown else {
      return nil
    }

    let key = Sauce.shared.key(for: Int(event.keyCode))
    return items.first { $0.shortcuts.contains(where: { $0.key == key }) }
  }

  private let search = Search()
  private let sorter = Sorter()
  private let throttler = Throttler(minimumDelay: 0.2)

  @ObservationIgnored
  private var sessionLog: [Int: HistoryItem] = [:]

  // The distinction between `all` and `items` is the following:
  // - `all` stores all history items, even the ones that are currently hidden by a search
  // - `items` stores only visible history items, updated during a search
  @ObservationIgnored
  var all: [HistoryItemDecorator] = []

  init() {
    Task {
      for await _ in Defaults.updates(.pasteByDefault, initial: false) {
        updateShortcuts()
      }
    }

    Task {
      for await _ in Defaults.updates(.sortBy, initial: false) {
        try? await load()
      }
    }

    Task {
      for await _ in Defaults.updates(.pinTo, initial: false) {
        try? await load()
      }
    }

    Task {
      for await _ in Defaults.updates(.showSpecialSymbols, initial: false) {
        for item in items {
          await updateTitle(item: item, title: item.item.generateTitle())
        }
      }
    }

    Task {
      for await _ in Defaults.updates(.imageMaxHeight, initial: false) {
        for item in items {
          await item.cleanupImages()
        }
      }
    }
  }

  @MainActor
  func load() async throws {
    let descriptor = FetchDescriptor<HistoryItem>()
    let results = try Storage.shared.context.fetch(descriptor)
    let sorted = sorter.sort(results)
    var kept: [PersistentIdentifier: HistoryItemDecorator] = [:]
    for decorator in all where !decorator.isRemoved {
      kept[decorator.item.persistentModelID] = decorator
    }
    all = sorted.map { model in
      kept[model.persistentModelID] ?? HistoryItemDecorator(model)
    }
    if LabRuntime.isSmoke && all.isEmpty {
      installSmokeSamples()
    }
    refreshVisibleItems(highlightFirst: false)

    limitHistorySize(to: Defaults[.size])

    updateShortcuts()
    // Ensure that panel size is proper *after* loading all items.
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  private func limitHistorySize(to maxSize: Int) {
    let disposable = all
      .filter { $0.item.isDisposable }
      .sorted { $0.item.lastCopiedAt > $1.item.lastCopiedAt }
    guard disposable.count > maxSize else { return }
    disposable[maxSize...].forEach(delete)
  }

  @MainActor
  func insertIntoStorage(_ item: HistoryItem) throws {
    logger.info("Inserting item with id '\(item.title)'")
    Storage.shared.context.insert(item)
    Storage.shared.context.processPendingChanges()
    try Storage.shared.save()
  }

  @discardableResult
  @MainActor
  func add(_ item: HistoryItem) -> HistoryItemDecorator {
    if #available(macOS 15.0, *) {
      do {
        try insertIntoStorage(item)
      } catch {
        reportSaveFailure(error)
      }
    } else {
      // On macOS 14 the history item needs to be inserted into storage directly after creating it.
      // It was already inserted after creation in Clipboard.swift
    }

    var removedItemIndex: Int?
    var replaced: HistoryItemDecorator?
    if let existingHistoryItem = findSimilarItem(item) {
      if isModified(item) == nil {
        // The new copy adopts the stored contents. Its own freshly captured
        // contents would otherwise stay in the store with no parent item:
        // one orphaned copy of every re-copied image, forever.
        let discarded = item.contents
        item.contents = existingHistoryItem.contents
        discarded.forEach { Storage.shared.context.delete($0) }
      }
      item.firstCopiedAt = existingHistoryItem.firstCopiedAt
      item.numberOfCopies += existingHistoryItem.numberOfCopies
      item.pin = existingHistoryItem.pin
      item.tags = HistoryItem.unionTags(existingHistoryItem.tags, item.tags)
      item.title = existingHistoryItem.title
      if !item.fromWitsCopy {
        item.application = existingHistoryItem.application
      }
      logger.info("Removing duplicate item '\(item.title)'")
      removedItemIndex = all.firstIndex(where: { $0.item == existingHistoryItem })
      if let removedItemIndex {
        replaced = all[removedItemIndex]
        if let removed = replaced {
          AppState.shared.stashTextDraft(from: removed.id, onto: item)
          _ = RichTextDraftStore.shared.rebind(
            from: RichTextIdentity.modelKey(existingHistoryItem),
            to: RichTextIdentity.modelKey(item)
          )
        }
        cleanup(all[removedItemIndex])
      }
      Storage.shared.context.delete(existingHistoryItem)
      if let removedItemIndex {
        all.remove(at: removedItemIndex)
      }
      do {
        try Storage.shared.save()
      } catch {
        reportSaveFailure(error)
      }
    } else if !LabRuntime.isSmoke {
      Task {
        Notifier.notify(body: item.title, sound: .write)
      }
    }

    // Remove exceeding items. Do this after the item is added to avoid removing something
    // if a duplicate was found as then the size already stayed the same.
    limitHistorySize(to: Defaults[.size] - 1)

    sessionLog[Clipboard.shared.changeCount] = item

    var itemDecorator: HistoryItemDecorator
    if item.pin != nil {
      let pin = item.pin ?? ""
      let shortcuts = pin.isEmpty ? [] : KeyShortcut.create(character: pin)
      itemDecorator = HistoryItemDecorator(item, shortcuts: shortcuts)
      if let removedItemIndex {
        // If pin to bottom -> last element should be inserted to the removedItemIndex - 1
        // Or to the last all array place.
        all.insert(itemDecorator, at: min(removedItemIndex, all.count))
      } else {
        // New snippets are created already pinned. Upstream only reinserted a pin
        // when replacing a duplicate, so a fresh pinned item never appeared.
        let sortedItems = sorter.sort(all.map(\.item) + [item])
        if let index = sortedItems.firstIndex(of: item) {
          all.insert(itemDecorator, at: index)
        }
      }
      applySearch(highlightFirst: false)
      updateShortcuts()
    } else {
      itemDecorator = HistoryItemDecorator(item)

      let sortedItems = sorter.sort(all.map(\.item) + [item])
      if let index = sortedItems.firstIndex(of: item) {
        all.insert(itemDecorator, at: index)
      }

      applySearch(highlightFirst: false)
      updateUnpinnedShortcuts()
    }

    // Dedup deletes the selected decorator and inserts a new id. Point the lead
    // at the survivor before the next main-queue update, or reopen falls back
    // to the first unpinned row and the pin chrome collapses.
    retargetReplacedSelection(replaced, with: itemDecorator)
    AppState.shared.claimStashedDraft(for: item, decoratorID: itemDecorator.id)
    return itemDecorator
  }

  @MainActor
  private func withLogging(_ msg: String, _ block: () throws -> Void) rethrows {
    func dataCounts() -> String {
      let historyItemCount = try? Storage.shared.context.fetchCount(FetchDescriptor<HistoryItem>())
      let historyContentCount = try? Storage.shared.context.fetchCount(FetchDescriptor<HistoryItemContent>())
      return "HistoryItem=\(historyItemCount ?? 0) HistoryItemContent=\(historyContentCount ?? 0)"
    }

    logger.info("\(msg) Before: \(dataCounts())")
    try? block()
    logger.info("\(msg) After: \(dataCounts())")
  }

  @MainActor
  func clear() {
    withLogging("Clearing history") {
      let removing = all.filter { $0.item.isDisposable }
      removing.forEach(cleanup)
      all.removeAll { $0.item.isDisposable }
      sessionLog.removeValues { $0.isDisposable }
      items = all

      try? Storage.shared.context.transaction {
        removing.forEach { Storage.shared.context.delete($0.item) }
      }
      Storage.shared.context.processPendingChanges()
      try? Storage.shared.context.save()
    }
    Storage.shared.compactInBackground()

    Clipboard.shared.clear()
    AppState.shared.popup.close()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  func clearAll() {
    withLogging("Clearing all history") {
      all.forEach { item in
        cleanup(item)
      }
      all.removeAll()
      sessionLog.removeAll()
      items = all

      // Batch deletes skip relationship delete rules, so removing HistoryItem
      // alone leaves every content row (image bytes included) behind.
      try? Storage.shared.context.delete(model: HistoryItem.self)
      try? Storage.shared.context.delete(model: HistoryItemContent.self)
      Storage.shared.context.processPendingChanges()
      try? Storage.shared.context.save()
    }
    Storage.shared.compactInBackground()

    Clipboard.shared.clear()
    AppState.shared.popup.close()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  func delete(_ item: HistoryItemDecorator?) {
    guard let item, !item.isRemoved else { return }

    cleanup(item)
    withLogging("Removing history item") {
      Storage.shared.context.delete(item.item)
      Storage.shared.context.processPendingChanges()
      try? Storage.shared.context.save()
    }

    all.removeAll { $0 == item }
    items.removeAll { $0 == item }
    sessionLog.removeValues { $0 == item.item }

    updateUnpinnedShortcuts()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  private func cleanup(_ item: HistoryItemDecorator) {
    item.prepareForRemoval()
    if AppState.shared.tagEditorItem?.id == item.id {
      AppState.shared.clearTagEditor()
    }
    if AppState.shared.ocrItemID == item.id {
      AppState.shared.closeOCR()
    }
    AppState.shared.cancelPinRecording(itemID: item.id)
    AppState.shared.discardTextDraft(itemID: item.id)
    AppState.shared.clearTextEditError(itemID: item.id)
  }

  /// Keep the logical item selected after a duplicate replaces its decorator.
  @MainActor
  private func retargetReplacedSelection(
    _ removed: HistoryItemDecorator?,
    with survivor: HistoryItemDecorator
  ) {
    guard let removed, AppState.shared.navigator.leadHistoryItem?.id == removed.id else { return }
    if items.contains(where: { $0.id == survivor.id }) {
      AppState.shared.navigator.select(item: survivor)
    } else {
      AppState.shared.navigator.select(item: unpinnedItems.first ?? pinnedItems.first)
    }
  }

  @MainActor
  func select(_ item: HistoryItemDecorator?, flags modifierFlags: NSEvent.ModifierFlags) {
    guard let item, !item.isRemoved else {
      return
    }

    let shouldClose = PanelClosePolicy.decide(
      .copyCommit,
      context: AppState.shared.focusContext
    ) == .close
    if shouldClose {
      AppState.shared.popup.close()
    }

    if modifierFlags.isEmpty {
      Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault])
      if Defaults[.pasteByDefault] {
        Clipboard.shared.paste()
      }
    } else {
      switch HistoryItemAction(modifierFlags) {
      case .copy:
        Clipboard.shared.copy(item.item)
      case .paste:
        Clipboard.shared.copy(item.item)
        Clipboard.shared.paste()
      case .pasteWithoutFormatting:
        Clipboard.shared.copy(item.item, removeFormatting: true)
        Clipboard.shared.paste()
      case .unknown:
        return
      }
    }

    if PanelClosePolicy.clearsSearchAfterCopy(windowPinned: AppState.shared.windowPinned) {
      Task {
        searchQuery = ""
      }
    }
  }

  @MainActor
  func startPasteStack(selection: inout Selection<HistoryItemDecorator>, flags modifierFlags: NSEvent.ModifierFlags) {
    guard AppState.shared.multiSelectionEnabled else { return }
    guard let item = selection.first else { return }
    PasteStack.initializeIfNeeded()

    let stack = PasteStack(items: selection.items, modifierFlags: modifierFlags)
    pasteStack = stack

    logger.info("Initialising PasteStack with \(stack.items.count) items")
    logger.info("Copying \(item.item.title) from PasteStack")

    if modifierFlags.isEmpty {
      if PanelClosePolicy.decide(.copyCommit, context: AppState.shared.focusContext) == .close {
        AppState.shared.popup.close()
      }
      Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault])
    } else {
      switch HistoryItemAction(modifierFlags) {
      case .copy:
        if PanelClosePolicy.decide(.copyCommit, context: AppState.shared.focusContext) == .close {
          AppState.shared.popup.close()
        }
        Clipboard.shared.copy(item.item)
      case .paste:
        if PanelClosePolicy.decide(.copyCommit, context: AppState.shared.focusContext) == .close {
          AppState.shared.popup.close()
        }
        Clipboard.shared.copy(item.item)
      case .pasteWithoutFormatting:
        if PanelClosePolicy.decide(.copyCommit, context: AppState.shared.focusContext) == .close {
          AppState.shared.popup.close()
        }
        Clipboard.shared.copy(item.item, removeFormatting: true)
        Clipboard.shared.paste()
      case .unknown:
        return
      }
    }

    if PanelClosePolicy.clearsSearchAfterCopy(windowPinned: AppState.shared.windowPinned) {
      Task {
        searchQuery = ""
      }
    }
  }

  func handlePasteStack() {
    guard let stack = pasteStack else {
      return
    }

    guard let pasted = stack.items.first else {
      pasteStack = nil
      logger.info("PasteStack is empty")
      return
    }

    logger.info("PasteStack pasted \(pasted.item.title)")

    stack.items.removeFirst()

    guard let item = stack.items.first else {
      pasteStack = nil
      logger.info("PasteStack is empty")
      return
    }

    logger.info("Copying \(item.item.title) from PasteStack. \(stack.items.count) items remaining in stack.")

    Task {
      if stack.modifierFlags.isEmpty {
        await Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault])
      } else {
        switch HistoryItemAction(stack.modifierFlags) {
        case .copy:
          await Clipboard.shared.copy(item.item)
        case .paste:
          await Clipboard.shared.copy(item.item)
        case .pasteWithoutFormatting:
          await Clipboard.shared.copy(item.item, removeFormatting: true)
        case .unknown:
          return
        }
      }
    }
  }

  func interruptPasteStack() {
    guard pasteStack != nil else {
      return
    }
    logger.info("Interrupting PasteStack")
    pasteStack = nil
  }

  @MainActor
  func togglePin(_ item: HistoryItemDecorator?) {
    guard let item, !item.isRemoved else { return }

    item.togglePin()
    if item.isUnpinned {
      AppState.shared.cancelPinRecording(itemID: item.id)
    }

    // Rebuild from the sorter. Removing then inserting at the pre-removal
    // index is off by one when the new index is after the old one.
    let sortedItems = sorter.sort(all.map(\.item))
    let decorators = Dictionary(uniqueKeysWithValues: all.map { (ObjectIdentifier($0.item), $0) })
    all = sortedItems.compactMap { decorators[ObjectIdentifier($0)] }

    updateUnpinnedShortcuts()
    applySearch(highlightFirst: false)
    if item.isUnpinned, items.contains(where: { $0.id == item.id }) {
      AppState.shared.navigator.scrollTarget = item.id
    }
  }

  @MainActor
  func selectTag(_ name: String?) {
    guard let name, let normalized = HistoryItem.normalizedTag(name) else {
      tagFilter = nil
      return
    }
    tagFilter = normalized
  }

  @discardableResult
  @MainActor
  func renameTag(from rawFrom: String, to rawTo: String) -> Bool {
    guard WorkspaceTagCatalog.rename([rawFrom], from: rawFrom, to: rawTo) != nil else { return false }
    guard let from = HistoryItem.normalizedTag(rawFrom),
          let to = HistoryItem.normalizedTag(rawTo) else { return false }
    let snapshots = all.map { ($0, $0.item.tags) }
    var changed = false
    for item in all {
      guard let next = WorkspaceTagCatalog.rename(item.item.tags, from: from, to: to) else { continue }
      if next != item.item.tags {
        item.item.tags = next
        item.noteTagsChanged()
        changed = true
      }
    }
    if tagFilter?.caseInsensitiveCompare(from) == .orderedSame {
      tagFilter = to
    }
    guard changed else { return true }
    do {
      try Storage.shared.save()
    } catch {
      for (item, tags) in snapshots {
        item.item.tags = tags
        item.noteTagsChanged()
      }
      reportSaveFailure(error)
      return false
    }
    clearSaveFailure()
    applySearch(highlightFirst: false)
    return true
  }

  @discardableResult
  @MainActor
  func deleteTag(named raw: String) -> Bool {
    guard let name = HistoryItem.normalizedTag(raw) else { return false }
    let snapshots = all.map { ($0, $0.item.tags) }
    var changed = false
    for item in all {
      guard let next = WorkspaceTagCatalog.remove(item.item.tags, named: name) else { continue }
      if next != item.item.tags {
        item.item.tags = next
        item.noteTagsChanged()
        changed = true
      }
    }
    if tagFilter?.caseInsensitiveCompare(name) == .orderedSame {
      tagFilter = nil
    }
    guard changed else { return true }
    do {
      try Storage.shared.save()
    } catch {
      for (item, tags) in snapshots {
        item.item.tags = tags
        item.noteTagsChanged()
      }
      reportSaveFailure(error)
      return false
    }
    clearSaveFailure()
    applySearch(highlightFirst: false)
    return true
  }

  func refreshVisibleItems(highlightFirst: Bool = false) {
    applySearch(highlightFirst: highlightFirst)
  }

  private func scopedPool() -> [HistoryItemDecorator] {
    let section = AppState.shared.workspaceSection
    guard section.showsHistory else { return [] }
    var pool = all
    switch section {
    case .all, .ignore:
      break
    case .tags:
      // Not a rail page. Kept so a direct assignment still means "tagged items" until resolvedForOpen.
      pool = pool.filter { !$0.item.tags.isEmpty }
    case .pins:
      pool = pool.filter(\.isPinned)
    }
    if let typeFilter {
      pool = pool.filter { $0.item.contentKind == typeFilter }
    }
    return pool
  }

  var knownTags: [String] {
    var seen: [String] = []
    for item in all {
      for tag in item.item.tags {
        if !seen.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
          seen.append(tag)
        }
      }
    }
    return seen.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
  }

  /// 双击粘贴等于再用一次：把它提到最前，而不是复制出第二份。
  @MainActor
  func bumpToFront(_ item: HistoryItemDecorator) {
    item.item.lastCopiedAt = .now
    do {
      try Storage.shared.save()
    } catch {
      reportSaveFailure(error)
    }
    applySearch(highlightFirst: false)
  }

  @discardableResult
  @MainActor
  func assignTag(_ item: HistoryItemDecorator?, named raw: String) -> Bool {
    guard let item, let name = HistoryItem.normalizedTag(raw) else { return false }
    if item.item.tags.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
      return true
    }
    let previous = item.item.tags
    item.item.tags.append(name)
    item.noteTagsChanged()
    do {
      try Storage.shared.save()
    } catch {
      item.item.tags = previous
      item.noteTagsChanged()
      reportSaveFailure(error)
      return false
    }
    clearSaveFailure()
    applySearch(highlightFirst: false)
    return true
  }

  @discardableResult
  @MainActor
  func removeTag(_ item: HistoryItemDecorator?, named raw: String) -> Bool {
    guard let item, let name = HistoryItem.normalizedTag(raw) else { return false }
    guard let index = item.item.tags.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
      return false
    }
    let previous = item.item.tags
    item.item.tags.remove(at: index)
    item.noteTagsChanged()
    do {
      try Storage.shared.save()
    } catch {
      item.item.tags = previous
      item.noteTagsChanged()
      reportSaveFailure(error)
      return false
    }
    clearSaveFailure()
    applySearch(highlightFirst: false)
    return true
  }

  /// Empty check uses trim. The stored body keeps indentation and surrounding newlines.
  /// `pin` may be `""`: that is a pin with no shortcut, and it is not disposable.
  @MainActor
  static func makeSnippetItem(title: String, text: String, pin: String) -> HistoryItem? {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    let item = HistoryItem(contents: [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: Data(text.utf8)
      )
    ])
    let alias = title.trimmingCharacters(in: .whitespacesAndNewlines)
    item.title = alias.isEmpty ? item.generateTitle() : alias
    item.pin = pin
    item.application = LabRuntime.snippetSource
    return item
  }

  @discardableResult
  @MainActor
  func createSnippet(title: String, text: String) -> HistoryItemDecorator? {
    guard let item = Self.makeSnippetItem(
      title: title,
      text: text,
      pin: HistoryItem.randomAvailablePin
    ) else { return nil }
    let decorator = add(item)
    do {
      try Storage.shared.save()
    } catch {
      reportSaveFailure(error)
      delete(decorator)
      return nil
    }
    clearSaveFailure()
    return decorator
  }

  @MainActor
  private func reportSaveFailure(_ error: Error) {
    logger.error("Save failed: \(String(describing: error))")
    AppState.shared.storageError = NSLocalizedString("save_failed", comment: "")
  }

  @MainActor
  private func clearSaveFailure() {
    AppState.shared.storageError = nil
  }

  private func applySearch(highlightFirst: Bool) {
    let pool = scopedPool()
    updateItems(search.search(string: searchQuery, within: pool, tag: tagFilter))
    if highlightFirst {
      if searchQuery.isEmpty && tagFilter == nil {
        // Keep the item the user is on when it is still visible; only fall back to row 1.
        AppState.shared.selectOnPanelOpen()
      } else {
        AppState.shared.navigator.highlightFirst()
      }
    }
    AppState.shared.popup.needsResize = true
  }

  @MainActor
  private func installSmokeSamples() {
    func textItem(_ text: String, pin: String? = nil, tags: [String] = [], application: String? = nil) {
      let item = HistoryItem(contents: [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: Data(text.utf8)
        )
      ])
      item.title = text
      item.pin = pin
      item.tags = tags
      item.application = application
      _ = add(item)
    }
    textItem("Office address — 88 Lab Street", pin: "o", application: "com.apple.finder")
    textItem("Company billing address", tags: ["addr"], application: "com.apple.Safari")
    textItem("Standup notes for Monday", application: "com.apple.TextEdit")
    textItem("#release-2.7 checklist", application: "com.apple.TextEdit")
    textItem("Wi-Fi lab-guest", pin: "w", tags: ["net"], application: "com.apple.finder")
    installSmokeRichText()
    installSmokeImage()
    installSmokeFiles()
    if LabRuntime.isManySmoke {
      for index in 1...30 {
        textItem("合成填充条目 \(index)")
      }
    }
  }

  @MainActor
  private func installSmokeRichText() {
    guard LabRuntime.isRichSmoke else { return }
    let display = NSMutableAttributedString(string: "合成粗体保留")
    display.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 18), range: NSRange(location: 0, length: 2))
    guard let rtf = display.rtf(from: NSRange(location: 0, length: display.length), documentAttributes: [:]) else {
      return
    }
    let item = HistoryItem(contents: [
      HistoryItemContent(type: NSPasteboard.PasteboardType.rtf.rawValue, value: rtf),
      HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data("合成粗体保留".utf8))
    ])
    item.title = "合成富文本"
    item.application = LabRuntime.snippetSource
    _ = add(item)
  }

  @MainActor
  private func installSmokeImage() {
    func addImageData(_ data: Data, title: String, type: String) {
      let item = HistoryItem(contents: [
        HistoryItemContent(type: type, value: data)
      ])
      item.title = title
      item.application = "com.apple.Preview"
      _ = add(item)
    }
    let image = NSImage(size: NSSize(width: 96, height: 56))
    image.lockFocus()
    NSColor.systemTeal.setFill()
    NSRect(x: 0, y: 0, width: 96, height: 56).fill()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
      return
    }
    let item = HistoryItem(contents: [
      HistoryItemContent(type: NSPasteboard.PasteboardType.png.rawValue, value: png)
    ])
    item.title = "合成色块"
    item.application = "com.apple.Preview"
    _ = add(item)
    if LabRuntime.isImageSmoke {
      if let png = LabSmokeCanvas.png(pixels: NSSize(width: 2400, height: 1500)) {
        addImageData(png, title: "合成大图", type: NSPasteboard.PasteboardType.png.rawValue)
      }
      if let png = LabSmokeCanvas.png(pixels: NSSize(width: 900, height: 2400)) {
        addImageData(png, title: "合成肖像", type: NSPasteboard.PasteboardType.png.rawValue)
      }
      if let gif = LabSmokeCanvas.gif(pixels: NSSize(width: 240, height: 720), frames: 3),
         let url = LabSmokeCanvas.write(gif, name: "synthetic.gif") {
        let item = HistoryItem(contents: [
          HistoryItemContent(type: NSPasteboard.PasteboardType.fileURL.rawValue, value: url.dataRepresentation),
          HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data("synthetic.gif".utf8))
        ])
        item.title = "合成动图"
        item.application = "com.apple.finder"
        _ = add(item)
      }
    }
    if let url = LabRuntime.fixturesDirectory?.appending(path: "ocr-bilingual.png"),
       let data = try? Data(contentsOf: url) {
      let raw = HistoryItem(contents: [
        HistoryItemContent(type: NSPasteboard.PasteboardType.png.rawValue, value: data)
      ])
      raw.title = "合成识别图片"
      raw.application = "com.apple.Preview"
      _ = add(raw)
    }
  }

  @MainActor
  private func installSmokeFiles() {
    guard let dir = LabRuntime.fixturesDirectory else { return }
    var names = ["note.txt", "sample.png", "sample.pdf", "sample.mp4"]
    let manifest = dir.appending(path: "manifest.json")
    if let data = try? Data(contentsOf: manifest),
       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let entries = object["fixtures"] as? [[String: Any]] {
      names += entries.prefix(64).compactMap { entry in
        guard let name = entry["name"] as? String,
              URL(fileURLWithPath: name).lastPathComponent == name else { return nil }
        return name
      }
    }
    var seen = Set<String>()
    for name in names where seen.insert(name).inserted {
      let url = dir.appending(path: name)
      guard FileManager.default.fileExists(atPath: url.path) else { continue }
      let item = HistoryItem(contents: [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.fileURL.rawValue,
          value: url.dataRepresentation
        ),
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: Data(name.utf8)
        )
      ])
      item.title = name
      item.application = "com.apple.finder"
      _ = add(item)
    }
  }

  @MainActor
  private func findSimilarItem(_ item: HistoryItem) -> HistoryItem? {
    if let duplicate = all.first(where: { $0.item != item && $0.item.supersedes(item) }) {
      return duplicate.item
    }

    return isModified(item)
  }

  private func isModified(_ item: HistoryItem) -> HistoryItem? {
    if let modified = item.modified, sessionLog.keys.contains(modified) {
      return sessionLog[modified]
    }

    return nil
  }

  private func updateItems(_ newItems: [Search.SearchResult]) {
    items = newItems.map { result in
      let item = result.object
      item.highlight(searchQuery, result.ranges)

      return item
    }

    updateUnpinnedShortcuts()
  }

  private func updateShortcuts() {
    for item in pinnedItems {
      if let pin = item.item.pin, !pin.isEmpty {
        item.shortcuts = KeyShortcut.create(character: pin)
      } else if item.item.pin != nil {
        item.shortcuts = []
      }
    }

    updateUnpinnedShortcuts()
  }

  @MainActor
  private func updateTitle(item: HistoryItemDecorator, title: String) {
    item.title = title
    item.item.title = title
  }

  private func updateUnpinnedShortcuts() {
    let visibleUnpinnedItems = unpinnedItems.filter(\.isVisible)
    for item in visibleUnpinnedItems {
      item.shortcuts = []
    }

    var index = 1
    for item in visibleUnpinnedItems.prefix(9) {
      item.shortcuts = KeyShortcut.create(character: String(index))
      index += 1
    }
  }
}
