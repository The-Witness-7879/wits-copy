import AppKit
import Defaults
import Foundation
import SwiftUI

@Observable
class AppState: Sendable {
  static let shared = AppState(history: History.shared, footer: Footer())

  // Upstream set this false to disable paste stack. Enabling it would change
  // keyboard navigation, so tag editing stays single-item: lead selection, or the first row.
  let multiSelectionEnabled = true

  // AppState.shared is created by applicationWillFinishLaunching; retain Sparkle
  // for the entire process rather than starting a new controller per settings view.
  let softwareUpdater = MainActor.assumeIsolated { SoftwareUpdater() }

  var appDelegate: AppDelegate?
  var popup: Popup
  var history: History
  var footer: Footer
  var navigator: NavigationManager
  var preview: SlideoutController

  var searchVisible: Bool {
    Defaults[.showSearch]
  }

  var tagEditorItem: HistoryItemDecorator?
  var tagEditorAnchor: TagEditorAnchor?
  /// Preview-only shortcut editor. The row-end recorder stays the other entry.
  var previewShortcutItemID: UUID?
  var previewShortcutBeginToken = 0
  var deleteConfirmationPresented = false
  /// Set while the paste-failure alert is up, so a second double-click does not stack another.
  var pasteFailureAlertPresented = false
  /// Last explicit paste failure, kept for tests and diagnostics; the user sees an alert.
  var lastPasteFailure: ExplicitPasteFailure?
  /// Temporary OCR column. Not stored on the history item.
  var ocrItemID: UUID?
  var ocrGeneration: UInt64 = 0
  var ocrBlocks: [OCRBlock] = []
  var ocrPhase: OCRPhase = .idle
  var storageError: String?

  enum OCRPhase: Equatable, Sendable {
    case idle
    case recognizing
    case empty
    case failed(String)
    case ready
  }

  /// Updated from panel open/close. Preview construction reads this; do not infer it from opacity.
  var panelPresented = false {
    didSet {
      guard panelPresented != oldValue else { return }
      if !panelPresented {
        clearTagEditor()
        previewShortcutItemID = nil
        endPinRecordingSession()
        closeOCR()
      }
    }
  }
  var windowPinned = Defaults[.windowPinned] {
    didSet {
      guard windowPinned != oldValue else { return }
      Defaults[.windowPinned] = windowPinned
      if let panel = appDelegate?.panel {
        panel.level = PanelWindowLevel.popup(pinned: windowPinned)
      }
    }
  }
  var managementRailVisible: Bool = {
    let stored = Defaults[.managementRailVisible]
    let forced = LabRuntime.isSmoke && CommandLine.arguments.contains("--lab-rail-expanded")
    return stored || forced
  }() {
    didSet {
      guard managementRailVisible != oldValue else { return }
      Defaults[.managementRailVisible] = managementRailVisible
      // 主线程上同步调整，避免异步任务落到下一轮布局（或下一个测试）里改窗口。
      let extraBefore = oldValue ? Self.railExtra(for: railWidth) : 0
      if Thread.isMainThread {
        MainActor.assumeIsolated { resizePanelForRail(extraBefore: extraBefore) }
      } else {
        Task { @MainActor in resizePanelForRail(extraBefore: extraBefore) }
      }
    }
  }

  /// 展开档的宽度。拖窗口左边缘改的是它，条目列不动。
  var railWidth: CGFloat = Defaults[.managementRailWidth] {
    didSet {
      guard abs(railWidth - oldValue) > 0.5 else { return }
      Defaults[.managementRailWidth] = railWidth
    }
  }

  /// 左栏比窄档多出来的宽度。视图层要读这个（@Observable 会触发重算）；
  /// 直接读 Defaults 的话 UserDefaults 变化不会让 SwiftUI 重排，
  /// 顶部那排就会停在旧宽度上，看起来像按钮自己跑了。
  var railExtraWidth: CGFloat {
    guard managementRailVisible else { return 0 }
    return max(0, effectiveRailWidth - PanelSplit.navigationRailWidth)
  }

  /// 左栏实际占的宽度：窄档固定，展开档取用户拉出来的值。
  var effectiveRailWidth: CGFloat {
    guard managementRailVisible else { return PanelSplit.navigationRailWidth }
    return min(
      max(railWidth, PanelSplit.navigationRailMinWidth),
      PanelSplit.navigationRailMaxWidth
    )
  }

  /// 拖窗口左边缘时只让左栏变宽，条目列不动。
  @MainActor
  func adjustRailWidth(_ delta: CGFloat) {
    guard managementRailVisible, abs(delta) > 0.5 else { return }
    railWidth = min(
      max(railWidth + delta, PanelSplit.navigationRailMinWidth),
      PanelSplit.navigationRailMaxWidth
    )
  }

  static func railExtra(for width: CGFloat) -> CGFloat {
    max(0, min(max(width, PanelSplit.navigationRailMinWidth), PanelSplit.navigationRailMaxWidth)
      - PanelSplit.navigationRailWidth)
  }

  /// 左栏换档：窗口只向左长/收，右边缘和条目列完全不动。
  /// 这样开合按钮、搜索框、预览区都保持屏幕位置；只有交通灯随左边缘走。
  @MainActor
  private func resizePanelForRail(extraBefore: CGFloat) {
    guard let panel = appDelegate?.panel else { return }
    let delta = railExtraWidth - extraBefore
    guard abs(delta) > 0.5 else { return }
    var frame = panel.frame
    frame.origin.x -= delta
    frame.size.width += delta
    // 左边缘撞到屏幕时只能回推，这是唯一会让整排挪位的情况。
    if let screen = panel.screen?.visibleFrame, frame.minX < screen.minX {
      frame.origin.x = screen.minX
    }
    // 抖动根因：窗口原点左移是 AppKit 立即生效，SwiftUI 重排却晚一拍，
    // 旧布局会先跟着新原点平移一帧再被拉回来。
    // 用零时长 NSAnimationContext 把重排和改窗压进同一次绘制，中间态不上屏。
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      context.allowsImplicitAnimation = false
      CATransaction.flush()
      panel.contentView?.layoutSubtreeIfNeeded()
      panel.setFrame(frame, display: true)
      CATransaction.flush()
      panel.contentView?.layoutSubtreeIfNeeded()
    }
  }

  var workspaceSection: WorkspaceSection = .all {
    didSet {
      if workspaceSection != .all {
        workspaceSection = .all
        return
      }
      guard workspaceSection != oldValue else { return }
      history.refreshVisibleItems(highlightFirst: false)
    }
  }

  var focusContext: PanelFocusContext {
    PanelFocusContext(
      windowPinned: windowPinned,
      tagPopoverPresented: tagEditorItem != nil,
      confirmationPresented: deleteConfirmationPresented || footer.items.contains(where: \.showConfirmation),
      menuPresented: menuTracking
    )
  }

  /// Row-local shortcut recording. Not a resignKey exception: the control stays inside the panel.
  var pinRecordingItemID: UUID?
  var pinRecordingMessage: String?
  var pinShortcutErrorItemID: UUID?
  var pinShortcutError: String?
  private var textDrafts: [UUID: OriginalTextDraft] = [:]
  private var textEditErrors: [UUID: String] = [:]
  private var pendingDrafts: [ObjectIdentifier: (draft: OriginalTextDraft, error: String?)] = [:]

  func beginPinRecording(itemID: UUID) {
    // The recorder calls this before it becomes first responder. Clearing the
    // tag editor here releases the inline editor key while the tag field, not
    // the new recorder, still owns it. Doing that after makeFirstResponder
    // would resign the recorder and cancel the session just opened.
    if tagEditorItem != nil {
      clearTagEditor()
    }
    if let current = pinRecordingItemID, current != itemID {
      cancelPinRecording(itemID: current)
    }
    if let open = previewShortcutItemID, open != itemID {
      previewShortcutItemID = nil
    }
    pinRecordingItemID = itemID
    pinRecordingMessage = PinShortcutCapture.retryPrompt
    if pinShortcutErrorItemID == itemID {
      pinShortcutErrorItemID = nil
      pinShortcutError = nil
    }
  }

  func notePinRecordingPrompt(_ message: String, itemID: UUID) {
    guard pinRecordingItemID == itemID else { return }
    pinRecordingMessage = message
  }

  func cancelPinRecording(itemID: UUID) {
    guard pinRecordingItemID == itemID else { return }
    pinRecordingItemID = nil
    pinRecordingMessage = nil
    MainActor.assumeIsolated {
      PinRecordingKeyRoute.endMatching(itemID: itemID)
    }
  }

  func endPinRecordingSession() {
    pinRecordingItemID = nil
    pinRecordingMessage = nil
    MainActor.assumeIsolated {
      PinRecordingKeyRoute.endMatching(itemID: nil)
    }
  }

  /// First Esc while a tag editor, pin recording, or preview shortcut editor is up
  /// cancels that session only. Does not hide the panel, activate the app, or order a window.
  func cancelForegroundInputSession() {
    if pinRecordingItemID != nil {
      endPinRecordingSession()
    }
    if let id = previewShortcutItemID {
      dismissPreviewShortcutEditor(itemID: id)
    }
    if tagEditorItem != nil {
      clearTagEditor()
    }
  }

  /// Body, title, or search took the insertion point. Does not activate the app.
  /// A focus change in another window cannot end this host's session.
  func noteTextEntryFocused(in window: NSWindow?) {
    MainActor.assumeIsolated {
      guard let owner = PinRecordingKeyRoute.owner, owner.ownsSession || owner.recording else {
        if pinRecordingItemID != nil {
          endPinRecordingSession()
        }
        return
      }
      if let window, let ownerWindow = owner.window, ownerWindow !== window { return }
      let id = owner.itemID
      owner.stopForSessionEnd(resignResponder: false)
      if pinRecordingItemID == id {
        pinRecordingItemID = nil
        pinRecordingMessage = nil
      }
    }
  }

  func pinShortcutMessage(for itemID: UUID) -> String? {
    if pinRecordingItemID == itemID { return pinRecordingMessage }
    return nil
  }

  func pinShortcutError(for itemID: UUID) -> String? {
    guard pinShortcutErrorItemID == itemID else { return nil }
    return pinShortcutError
  }

  @MainActor
  func commitPinLetter(_ letter: String, itemID: UUID) -> PinShortcutCommit {
    guard pinRecordingItemID == itemID else { return .stale }
    guard let decorator = history.all.first(where: { $0.id == itemID }), !decorator.isRemoved, decorator.isPinned else {
      cancelPinRecording(itemID: itemID)
      return .stale
    }
    let normalized = letter.lowercased()
    guard normalized.count == 1, normalized.unicodeScalars.allSatisfy({ (97...122).contains($0.value) }) else {
      pinRecordingMessage = PinShortcutCapture.retryPrompt
      return .rejected(PinShortcutCapture.retryPrompt)
    }

    let taken = history.all.contains { other in
      other.id != itemID && !other.isRemoved && other.isPinned && other.item.pin?.lowercased() == normalized
    }
    if taken {
      pinRecordingMessage = PinShortcutCapture.conflictPrompt
      return .conflict
    }
    guard !decorator.isRemoved else {
      cancelPinRecording(itemID: itemID)
      return .stale
    }
    let previous = decorator.item.pin
    decorator.item.pin = normalized
    decorator.shortcuts = KeyShortcut.create(character: normalized)
    do {
      try Storage.shared.save()
      storageError = nil
      pinShortcutErrorItemID = nil
      pinShortcutError = nil
      pinRecordingItemID = nil
      pinRecordingMessage = nil
      return .saved
    } catch {
      decorator.item.pin = previous
      decorator.shortcuts = (previous?.isEmpty == false) ? KeyShortcut.create(character: previous ?? "") : []
      let message = error.localizedDescription
      storageError = message
      pinShortcutErrorItemID = itemID
      pinShortcutError = message
      pinRecordingItemID = nil
      pinRecordingMessage = nil
      return .failed(message)
    }
  }

  func retainTextDraft(_ draft: OriginalTextDraft, itemID: UUID) {
    guard history.all.contains(where: { $0.id == itemID && !$0.isRemoved }) else { return }
    textDrafts[itemID] = draft
  }

  func stashTextDraft(from decoratorID: UUID, onto item: HistoryItem) {
    guard let draft = textDrafts.removeValue(forKey: decoratorID) else { return }
    let error = textEditErrors.removeValue(forKey: decoratorID)
    pendingDrafts[ObjectIdentifier(item)] = (draft, error)
  }

  func claimStashedDraft(for item: HistoryItem, decoratorID: UUID) {
    guard let pending = pendingDrafts.removeValue(forKey: ObjectIdentifier(item)) else { return }
    textDrafts[decoratorID] = pending.draft
    if let error = pending.error {
      textEditErrors[decoratorID] = error
    }
  }

  func discardTextDraft(itemID: UUID) {
    textDrafts.removeValue(forKey: itemID)
  }

  func discardAllTextDrafts() {
    textDrafts.removeAll()
    textEditErrors.removeAll()
    pendingDrafts.removeAll()
  }

  func textDraft(for itemID: UUID) -> OriginalTextDraft? {
    textDrafts[itemID]
  }

  func textEditError(for itemID: UUID) -> String? {
    textEditErrors[itemID]
  }

  func clearTextEditError(itemID: UUID) {
    textEditErrors.removeValue(forKey: itemID)
  }

  @MainActor
  func saveOriginalText(
    itemID: UUID,
    draft: OriginalTextDraft,
    baseline: OriginalTextDraft? = nil
  ) -> OriginalTextSaveOutcome {
    guard let decorator = history.all.first(where: { $0.id == itemID }), !decorator.isRemoved else {
      let message = NSLocalizedString("edit_stale", value: "This item was deleted. Nothing was written.", comment: "")
      textEditErrors[itemID] = message
      return .stale
    }
    if let reason = OriginalTextEdit.refusal(for: decorator.item) {
      textEditErrors[itemID] = reason.explanation
      return .rejected(reason.explanation)
    }
    if draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let message = NSLocalizedString("edit_blank", value: "Text cannot be empty.", comment: "")
      textEditErrors[itemID] = message
      retainTextDraft(draft, itemID: itemID)
      return .rejected(message)
    }
    guard decorator.id == itemID, !decorator.isRemoved else {
      let message = NSLocalizedString("edit_stale", value: "This item was deleted. Nothing was written.", comment: "")
      textEditErrors[itemID] = message
      return .stale
    }
    let item = decorator.item
    if let baseline,
       (item.text ?? "") != baseline.body || item.title != baseline.title {
      let message = NSLocalizedString(
        "edit_conflict",
        value: "The original changed. Nothing was overwritten.",
        comment: ""
      )
      textEditErrors[itemID] = message
      retainTextDraft(draft, itemID: itemID)
      return .rejected(message)
    }
    let previousTitle = item.title
    let previousBytes = item.contents.map { ($0, $0.value) }
    let removedSync = OriginalTextPayload.sync(item, body: draft.body)
    let removedRich = draft.body != (baseline?.body ?? item.text ?? "")
      ? OriginalTextPayload.stripRich(item)
      : []
    let removed = removedSync + removedRich
    let stringType = NSPasteboard.PasteboardType.string.rawValue
    let wrote = item.contents.contains { $0.type == stringType && $0.value == Data(draft.body.utf8) }
    guard wrote else {
      OriginalTextPayload.restore(item, bytes: previousBytes, removed: removed)
      textEditErrors[itemID] = OriginalTextRefusal.notText.explanation
      return .rejected(OriginalTextRefusal.notText.explanation)
    }
    let trimmedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
    item.title = trimmedTitle.isEmpty ? item.generateTitle() : draft.title
    decorator.title = item.title
    decorator.attributedTitle = nil
    do {
      try Storage.shared.save()
      storageError = nil
      textEditErrors.removeValue(forKey: itemID)
      textDrafts.removeValue(forKey: itemID)
      decorator.noteContentChanged()
      history.refreshVisibleItems(highlightFirst: false)
      return .saved
    } catch {
      OriginalTextPayload.restore(item, bytes: previousBytes, removed: removed)
      item.title = previousTitle
      decorator.title = previousTitle
      let message = error.localizedDescription
      storageError = message
      textEditErrors[itemID] = message
      retainTextDraft(draft, itemID: itemID)
      return .failed(message)
    }
  }

  /// True while an AppKit menu is tracking a click. Must not close the panel.
  var menuTracking = false
  /// Set only after the quit dialog is confirmed, so terminate cannot skip the prompt.
  var quitAuthorized = false

  /// Sole gate for constructing the preview renderer. Header hide and panel close both fail this.
  var previewAllowed: Bool {
    WorkspacePresentation.allowsPreview(
      panelPresented: panelPresented,
      previewOpen: preview.state.isOpen,
      section: workspaceSection
    )
  }

  var menuIconText: String {
    var title = history.unpinnedItems.first?.text.shortened(to: 100)
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    title.unicodeScalars.removeAll(where: CharacterSet.newlines.contains)
    return title.shortened(to: 20)
  }

  private let about = About()
  private var settingsWindowController: LabSettingsWindowController?

  init(history: History, footer: Footer) {
    self.history = history
    self.footer = footer
    popup = Popup()
    navigator = NavigationManager(history: history, footer: footer)
    preview = SlideoutController()
    preview.applyLayout(screen: NSScreen.main)
    preview.notifiesPreviewClose = true
  }

  @MainActor
  func select(flags modifierFlags: NSEvent.ModifierFlags) {
    if !navigator.selection.isEmpty {
      if navigator.isMultiSelectInProgress {
        navigator.isManualMultiSelect = false
        history.startPasteStack(selection: &navigator.selection, flags: modifierFlags)
      } else {
        history.select(navigator.selection.first, flags: modifierFlags)
      }
    } else if let item = footer.selectedItem {
      presentFooterConfirmation(item)
    } else {
      Clipboard.shared.copyInWitsCopy(history.searchQuery)
      history.searchQuery = ""
    }
  }

  /// Reopening the panel keeps the item the user was looking at instead of jumping to row 1.
  /// Fall back to the first visible row only when that item is gone or filtered out.
  func selectOnPanelOpen() {
    if let previous = navigator.leadHistoryItem,
       !previous.isRemoved,
       history.items.contains(where: { $0.id == previous.id }) {
      navigator.select(item: previous)
    } else {
      navigator.select(item: history.unpinnedItems.first ?? history.pinnedItems.first)
    }
  }

  @MainActor
  func togglePin() {
    withTransaction(Transaction()) {
      navigator.selection.forEach { _, item in
        history.togglePin(item)
      }
    }
  }

  @MainActor
  func beginTagEdit() {
    if tagEditorItem != nil {
      clearTagEditor()
      return
    }
    guard let item = navigator.selection.first ?? history.items.first else { return }
    beginTagEdit(for: item, anchor: .row)
  }

  /// One editor. The same item and anchor toggles off; a different source replaces it.
  @MainActor
  func beginTagEdit(for item: HistoryItemDecorator, anchor: TagEditorAnchor = .row) {
    guard !item.isRemoved else { return }
    if tagEditorItem?.id == item.id, tagEditorAnchor == anchor {
      clearTagEditor()
      return
    }
    // Row-end recording does not set previewShortcutItemID, and a preview
    // shortcut for another item is not dismissed by an item-id match.
    endPinRecordingSession()
    previewShortcutItemID = nil
    if anchor == .preview, !preview.state.isOpen {
      preview.togglePreview()
    }
    storageError = nil
    tagEditorItem = item
    tagEditorAnchor = anchor
    if anchor == .preview {
      appDelegate?.panel?.noteInlineEditorNeedsKey()
    }
  }

  func presentsTagEditor(_ item: HistoryItemDecorator, at anchor: TagEditorAnchor) -> Bool {
    tagEditorItem?.id == item.id && tagEditorAnchor == anchor && !item.isRemoved
  }

  func dismissTagEditor(itemID: UUID, anchor: TagEditorAnchor) {
    guard tagEditorItem?.id == itemID, tagEditorAnchor == anchor else { return }
    clearTagEditor()
  }

  func clearTagEditor() {
    let wasPreview = tagEditorAnchor == .preview
    tagEditorItem = nil
    tagEditorAnchor = nil
    if wasPreview {
      appDelegate?.panel?.releaseInlineEditorKey()
    }
  }

  func dismissPreviewShortcutEditor(itemID: UUID) {
    guard previewShortcutItemID == itemID else { return }
    previewShortcutItemID = nil
    cancelPinRecording(itemID: itemID)
  }

  /// Preview closed. A row editor stays on its row. OCR is preview-scoped and always closes.
  func notePreviewClosed() {
    endPinRecordingSession()
    previewShortcutItemID = nil
    if tagEditorAnchor == .preview {
      clearTagEditor()
    }
    closeOCR()
  }

  /// Lead changed. A preview editor for another item is stale. A row editor stays.
  func notePreviewLeadChanged(_ leadID: UUID?) {
    if let recording = pinRecordingItemID, recording != leadID {
      cancelPinRecording(itemID: recording)
    }
    if tagEditorAnchor == .preview, tagEditorItem?.id != leadID {
      clearTagEditor()
    }
    if let open = ocrItemID, open != leadID {
      closeOCR()
    }
  }

  @MainActor
  func beginOCR(for item: HistoryItemDecorator) {
    guard !item.isRemoved else { return }
    ocrGeneration &+= 1
    ocrItemID = item.id
    ocrBlocks = []
    ocrPhase = .recognizing
    preview.presentTemporaryOCR()
  }

  func closeOCR() {
    guard ocrItemID != nil || ocrPhase != .idle || preview.temporaryOCRWidth > 0 else { return }
    cancelPreviewRecognition?()
    ocrGeneration &+= 1
    ocrItemID = nil
    ocrBlocks = []
    ocrPhase = .idle
    preview.setTemporaryOCRWidth(0)
  }

  func commitOCR(_ blocks: [OCRBlock], generation: UInt64, itemID: UUID) {
    guard generation == ocrGeneration, ocrItemID == itemID else { return }
    ocrBlocks = blocks
    ocrPhase = blocks.isEmpty ? .empty : .ready
  }

  @MainActor
  func copyOCRText() {
    let text = ocrBlocks.map { $0.lines.joined(separator: "\n") }.joined(separator: "\n\n")
    guard !text.isEmpty else { return }
    if let ocrCopyHook {
      ocrCopyHook(text)
      return
    }
    Clipboard.shared.copyInWitsCopy(text)
  }

  var ocrCopyHook: ((String) -> Void)?
  /// Cancels the in-flight Vision job without stopping GIF or image playback.
  var cancelPreviewRecognition: (() -> Void)?

  func failOCR(_ message: String, generation: UInt64, itemID: UUID) {
    guard generation == ocrGeneration, ocrItemID == itemID else { return }
    ocrBlocks = []
    ocrPhase = .failed(message)
  }

  @MainActor
  func handleRowClick(
    _ item: HistoryItemDecorator,
    clickCount: Int,
    flags: NSEvent.ModifierFlags = []
  ) {
    guard !item.isRemoved else { return }
    if clickCount == 1, multiSelectionEnabled {
      // ⌘ 切换单条；⇧ 从锚点扩展一段。
      if flags.contains(.command) {
        navigator.addToSelection(item: item)
        return
      }
      if flags.contains(.shift),
         let anchor = navigator.leadHistoryItem,
         anchor.id != item.id {
        navigator.extendSelection(from: anchor, to: item, isRange: true)
        return
      }
    }
    switch WorkspacePointer.bodyAction(clickCount: clickCount) {
    case .select:
      navigator.select(item: item)
    case .commit:
      submitExplicitPaste(item, flags: flags)
    case nil:
      break
    }
  }

  /// KitDefined current events throw if `eventNumber` is read. Real mouse events still pass through.
  @MainActor
  private func explicitPasteEventNumber() -> Int {
    guard let event = NSApp.currentEvent else { return 0 }
    switch event.type {
    case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
         .otherMouseDown, .otherMouseUp, .keyDown, .keyUp:
      return event.eventNumber
    default:
      return 0
    }
  }

  /// Unmodified double-click paste. Does not also call `history.select`.
  @MainActor
  func submitExplicitPaste(_ item: HistoryItemDecorator, flags: NSEvent.ModifierFlags) {
    guard !item.isRemoved else { return }
    let strip = flags.intersection([.option, .shift]).isEmpty
      ? Defaults[.removeFormattingByDefault]
      : !Defaults[.removeFormattingByDefault]
    let result = Clipboard.shared.submitExplicitPaste(
      item: item.item,
      itemID: item.id,
      eventNumber: explicitPasteEventNumber(),
      removeFormatting: strip
    )
    switch result {
    case .pasted:
      lastPasteFailure = nil
      history.searchQuery = ""
      // 粘贴出去之后再复制一次：这条重新成为最新的，旧位置不重复出现。
      history.bumpToFront(item)
    case .failed(let failure):
      // Every failed double-click explains itself in a dialog; nothing is left
      // as a stray line of text in the preview.
      lastPasteFailure = failure
      presentPasteFailure(failure, item: item, removeFormatting: strip)
    case .suppressed, .duplicate:
      break
    }
  }

  /// Test seam: unit tests answer the alert instead of running a modal.
  static var pasteFailureChoiceProbe: ((ExplicitPasteFailure) -> PasteFailureChoice)?

  enum PasteFailureChoice: Equatable {
    case openSystemSettings
    case copyOnly
    case cancel
  }

  /// Explains why the paste did not happen and offers the way forward:
  /// grant the permission, or copy now and paste with ⌘V.
  @MainActor
  func presentPasteFailure(_ failure: ExplicitPasteFailure, item: HistoryItemDecorator, removeFormatting: Bool) {
    guard !pasteFailureAlertPresented else { return }
    let resolve: (PasteFailureChoice) -> Void = { [weak self] choice in
      guard let self else { return }
      self.pasteFailureAlertPresented = false
      switch choice {
      case .openSystemSettings:
        Accessibility.openSystemSettings()
      case .copyOnly:
        guard !item.isRemoved else { return }
        Clipboard.shared.copy(item.item, removeFormatting: removeFormatting)
        self.history.bumpToFront(item)
      case .cancel:
        break
      }
    }
    if let probe = Self.pasteFailureChoiceProbe {
      resolve(probe(failure))
      return
    }
    guard !LabRuntime.isUnitTestProcess else { return }

    let copy = PasteFailureCopy(failure)
    let alert = NSAlert()
    alert.alertStyle = failure == .accessibilityDenied ? .warning : .informational
    alert.messageText = copy.title
    alert.informativeText = copy.message
    var choices: [PasteFailureChoice] = []
    if failure == .accessibilityDenied {
      let open = alert.addButton(withTitle: NSLocalizedString("paste_permission_open", comment: ""))
      open.toolTip = NSLocalizedString("paste_permission_open_help", comment: "")
      choices.append(.openSystemSettings)
    }
    let copyButton = alert.addButton(withTitle: NSLocalizedString("paste_copy_only", comment: ""))
    copyButton.toolTip = NSLocalizedString("paste_copy_only_help", comment: "")
    choices.append(.copyOnly)
    let cancelButton = alert.addButton(withTitle: NSLocalizedString("clear_alert_cancel", comment: ""))
    cancelButton.toolTip = NSLocalizedString("paste_cancel_help", comment: "")
    choices.append(.cancel)

    pasteFailureAlertPresented = true
    let finish: (NSApplication.ModalResponse) -> Void = { response in
      let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
      resolve(choices.indices.contains(index) ? choices[index] : .cancel)
    }
    // Defer past the click that triggered it, like the delete confirmation.
    DispatchQueue.main.async { [weak self] in
      if let window = self?.appDelegate?.panel, window.isVisible {
        alert.beginSheetModal(for: window, completionHandler: finish)
      } else {
        NSApp.activate(ignoringOtherApps: true)
        finish(alert.runModal())
      }
    }
  }

  /// Pointer clicks must not call this unless the row was already selected.
  @MainActor
  func commitRow(
    _ item: HistoryItemDecorator,
    flags: NSEvent.ModifierFlags = []
  ) {
    guard !item.isRemoved else { return }
    history.select(item, flags: flags)
  }

  @MainActor
  func performRowAction(
    _ action: WorkspaceRowAction,
    on item: HistoryItemDecorator,
    anchor: TagEditorAnchor = .row
  ) {
    guard !item.isRemoved else { return }
    switch action {
    case .tag:
      beginTagEdit(for: item, anchor: anchor)
    case .pin:
      let wasPinned = item.isPinned
      history.togglePin(item)
      // 置顶时 togglePin 已自动分配一个可用快捷键（HistoryItem.randomAvailablePin）。
      // 不再强制打开录制器：那会让人以为必须先手动设一个。
      // 想改的话，双击行尾的快捷键槽即可。
      if wasPinned, !item.isPinned {
        dismissPreviewShortcutEditor(itemID: item.id)
      }
    case .delete:
      requestDelete(actionTargets(for: item))
    }
  }

  /// 单标签模型：把条目移到某个分类；nil 表示不属于任何分类。
  /// 先清旧分类再设新分类，避免出现两个并存的状态。
  @MainActor
  func moveToCategory(_ item: HistoryItemDecorator, name: String?) {
    let existing = item.item.tags
    for tag in existing {
      _ = history.removeTag(item, named: tag)
    }
    if let name {
      _ = history.assignTag(item, named: name)
    }
  }

  /// 拖到窗口外，或丢到「全部」：把这条（多选时整组）从当前分类里拿出来。
  @MainActor
  func dropOutsideWindow(itemID: UUID) {
    _ = applyCategoryDrop(itemID: itemID, name: nil)
  }

  /// Category drop for one live item. Multi-select moves the whole selection
  /// when the dropped item is part of it; otherwise only that item moves.
  @MainActor
  @discardableResult
  func applyCategoryDrop(itemID: UUID, name: String?) -> Bool {
    guard let item = history.all.first(where: { $0.id == itemID && !$0.isRemoved }) else { return false }
    for target in actionTargets(for: item) {
      moveToCategory(target, name: name)
    }
    return true
  }

  /// 多选时动作作用于整组；否则只作用于这一行。
  func actionTargets(for item: HistoryItemDecorator) -> [HistoryItemDecorator] {
    if multiSelectionEnabled, item.isSelected, navigator.selection.count > 1 {
      return navigator.selection.items
    }
    return [item]
  }

  /// 多选时统一走 requestDelete，避免行菜单和 ⋯ 菜单两条路径行为不一致。
  @MainActor
  func deleteItem(_ item: HistoryItemDecorator) {
    if tagEditorItem?.id == item.id {
      clearTagEditor()
    }
    let wasLead = navigator.leadHistoryItem?.id == item.id
    let next = history.visibleItems.nearest(to: item) { $0.id != item.id }
    history.delete(item)
    if wasLead {
      navigator.select(item: next)
    }
  }

  func yieldPanelBelowSettings() {
    guard let panel = appDelegate?.panel, panel.isPresented else { return }
    panel.level = .normal
  }

  /// Settings and About both make the panel step down; it comes back only
  /// when neither is still open.
  func restorePanelLevelAfterSettings() {
    guard panelPresented, let panel = appDelegate?.panel else { return }
    guard !about.isVisible, settingsWindowController?.window?.isVisible != true else { return }
    panel.level = PanelWindowLevel.popup(pinned: windowPinned)
  }

  @MainActor
  func removePasteStack() {
    history.interruptPasteStack()
    navigator.highlightFirst()
  }

  @MainActor
  func deleteSelection() {
    let selected = navigator.selection.items
    if selected.isEmpty, let lead = navigator.leadHistoryItem {
      requestDelete([lead])
    } else {
      requestDelete(selected)
    }
  }

  /// User-facing delete. Confirms unless this item's own suppress key is set.
  /// `deleteItem` stays immediate so existing callers and tests are unchanged.
  @MainActor
  func requestDelete(_ items: [HistoryItemDecorator]) {
    let live = items.filter { !$0.isRemoved }
    guard !live.isEmpty else { return }
    if !DeleteItemConfirmation.shouldPrompt(suppressed: DeleteItemConfirmationStore.isSuppressed) {
      live.forEach { deleteItem($0) }
      return
    }
    let hasPin = live.contains(where: \.isPinned)
    let hasTags = live.contains { !$0.item.tags.isEmpty }
    let alert = NSAlert()
    alert.messageText = NSLocalizedString(
      "delete_item_alert_message",
      value: "Delete this item?",
      comment: ""
    )
    alert.informativeText = NSLocalizedString(
      hasPin || hasTags ? "delete_item_alert_kept" : "delete_item_alert_comment",
      value: hasPin || hasTags
        ? "Pins and tags on the selected items are deleted too. This cannot be undone."
        : "This cannot be undone.",
      comment: ""
    )
    alert.alertStyle = .warning
    let confirmButton = alert.addButton(withTitle: NSLocalizedString("delete_item_alert_confirm", value: "Delete", comment: ""))
    confirmButton.toolTip = NSLocalizedString("delete_item_alert_confirm_help", value: "Delete the selected items.", comment: "")
    let cancelButton = alert.addButton(withTitle: NSLocalizedString("clear_alert_cancel", value: "Cancel", comment: ""))
    cancelButton.toolTip = NSLocalizedString("delete_item_alert_cancel_help", value: "Keep the selected items.", comment: "")
    alert.showsSuppressionButton = true
    alert.suppressionButton?.toolTip = NSLocalizedString(
      "delete_item_alert_suppress_help",
      value: "Don't ask again before deleting an item.",
      comment: ""
    )
    deleteConfirmationPresented = true
    let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      guard let self else { return }
      self.deleteConfirmationPresented = false
      if alert.suppressionButton?.state == .on {
        DeleteItemConfirmationStore.isSuppressed = true
      }
      guard response == .alertFirstButtonReturn else { return }
      live.forEach { self.deleteItem($0) }
    }
    if let window = appDelegate?.panel, window.isVisible {
      alert.beginSheetModal(for: window, completionHandler: finish)
    } else {
      finish(alert.runModal())
    }
  }

  func openAbout() {
    about.openAbout(nil)
  }

  @MainActor
  func openPreferences() {
    if settingsWindowController == nil {
      settingsWindowController = LabSettingsWindowController()
    }
    settingsWindowController?.show()
  }

  /// Menu, return-to-select, and any shortcut share this gate. Each item reads its own suppress binding.
  func runFooterItem(_ item: FooterItem) {
    if item.confirmation != nil, item.suppressConfirmation?.wrappedValue != true {
      if !panelPresented {
        appDelegate?.panel?.open(height: preview.currentHeight)
      }
      presentFooterConfirmation(item)
    } else {
      item.action()
    }
  }

  /// Clear and quit use the same native alert assembly as item delete.
  /// SwiftUI confirmationDialog `.help` configured AXHelp but did not install
  /// `NSButton.toolTip`, so the help window never appeared.
  func presentFooterConfirmation(_ item: FooterItem) {
    guard let confirmation = item.confirmation else {
      item.action()
      return
    }
    if item.suppressConfirmation?.wrappedValue == true {
      item.action()
      return
    }
    guard !item.showConfirmation else { return }
    item.showConfirmation = true
    let alert = NSAlert()
    alert.messageText = NSLocalizedString(confirmation.messageKey, comment: "")
    alert.informativeText = NSLocalizedString(confirmation.commentKey, comment: "")
    alert.alertStyle = .warning
    let confirmButton = alert.addButton(withTitle: NSLocalizedString(confirmation.confirmKey, comment: ""))
    confirmButton.toolTip = NSLocalizedString(confirmation.confirmHelpKey, comment: "")
    let cancelButton = alert.addButton(withTitle: NSLocalizedString(confirmation.cancelKey, comment: ""))
    cancelButton.toolTip = NSLocalizedString(confirmation.cancelHelpKey, comment: "")
    alert.showsSuppressionButton = item.suppressConfirmation != nil
    if item.suppressConfirmation != nil {
      alert.suppressionButton?.toolTip = NSLocalizedString(confirmation.suppressHelpKey, comment: "")
    }
    let finish: (NSApplication.ModalResponse) -> Void = { [weak item] response in
      guard let item else { return }
      item.showConfirmation = false
      if alert.suppressionButton?.state == .on {
        item.suppressConfirmation?.wrappedValue = true
      }
      guard response == .alertFirstButtonReturn else { return }
      item.action()
    }
    if let window = appDelegate?.panel, window.isVisible {
      alert.beginSheetModal(for: window, completionHandler: finish)
    } else {
      finish(alert.runModal())
    }
  }

  func quit() {
    guard let item = footer.items.first(where: { $0.title == "quit" }) else { return }
    runFooterItem(item)
  }

  /// Title-only. Does not touch pasteboard representations.
  @MainActor
  func saveTitlePreservingRich(itemID: UUID, title: String) -> OriginalTextSaveOutcome {
    guard let decorator = history.all.first(where: { $0.id == itemID }), !decorator.isRemoved else {
      let message = NSLocalizedString("edit_stale", value: "This item was deleted. Nothing was written.", comment: "")
      textEditErrors[itemID] = message
      return .stale
    }
    let item = decorator.item
    let previousTitle = item.title
    let before = item.contents.map { ($0.type, $0.value) }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    item.title = trimmed.isEmpty ? item.generateTitle() : title
    decorator.title = item.title
    decorator.attributedTitle = nil
    let after = item.contents.map { ($0.type, $0.value) }
    guard before.elementsEqual(after, by: { $0.0 == $1.0 && $0.1 == $1.1 }) else {
      item.title = previousTitle
      decorator.title = previousTitle
      return .rejected(NSLocalizedString("edit_conflict", value: "The original changed. Nothing was overwritten.", comment: ""))
    }
    do {
      try Storage.shared.save()
      storageError = nil
      textEditErrors.removeValue(forKey: itemID)
      decorator.noteContentChanged()
      history.refreshVisibleItems(highlightFirst: false)
      return .saved
    } catch {
      item.title = previousTitle
      decorator.title = previousTitle
      let message = error.localizedDescription
      storageError = message
      textEditErrors[itemID] = message
      return .failed(message)
    }
  }

  /// Body save goes through `RichTextSaveTransaction`. Title-only does not rewrite columns.
  @MainActor
  func commitRichTransaction(_ transaction: RichTextSaveTransaction, decoratorID: UUID) {
    guard let decorator = history.all.first(where: { $0.id == decoratorID }), !decorator.isRemoved else {
      RichTextDraftStore.shared.noteSaveFailed(
        identity: transaction.identity,
        generation: transaction.generation,
        message: NSLocalizedString("edit_stale", value: "This item was deleted. Nothing was written.", comment: "")
      )
      return
    }
    let identity = RichTextIdentity.modelKey(decorator.item)
    guard identity == transaction.identity else {
      RichTextDraftStore.shared.noteSaveFailed(
        identity: transaction.identity,
        generation: transaction.generation,
        message: NSLocalizedString("edit_conflict", value: "The original changed. Nothing was overwritten.", comment: "")
      )
      return
    }
    if !transaction.applyColumnChanges, transaction.title == nil {
      if case .rejected = transaction.status {
        RichTextDraftStore.shared.noteSaveFailed(
          identity: identity,
          generation: transaction.generation,
          message: NSLocalizedString("edit_conflict", value: "The original changed. Nothing was overwritten.", comment: "")
        )
      }
      return
    }
    let item = decorator.item
    if transaction.applyColumnChanges {
      applyRichColumnChanges(transaction.columnChanges, to: item)
    }
    if let title = transaction.title {
      let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
      item.title = trimmed.isEmpty ? item.generateTitle() : title
      decorator.title = item.title
      decorator.attributedTitle = nil
    }
    do {
      try Storage.shared.save()
      storageError = nil
      RichTextDraftStore.shared.noteCommitted(identity: identity, generation: transaction.generation)
      decorator.noteContentChanged()
      history.refreshVisibleItems(highlightFirst: false)
    } catch {
      Storage.shared.context.rollback()
      decorator.title = item.title
      decorator.attributedTitle = nil
      let message = error.localizedDescription
      storageError = message
      RichTextDraftStore.shared.noteSaveFailed(identity: identity, generation: transaction.generation, message: message)
    }
  }

  @MainActor
  private func applyRichColumnChanges(_ changes: [RichTextColumnChange], to item: HistoryItem) {
    for change in changes {
      switch change.action {
      case .delete:
        let doomed = item.contents.filter { $0.type == change.type }
        item.contents.removeAll { $0.type == change.type }
        for content in doomed {
          Storage.shared.context.delete(content)
        }
      case .replace(let data):
        if let existing = item.contents.first(where: { $0.type == change.type }) {
          existing.value = data
        } else if change.insertIfMissing {
          item.contents.append(HistoryItemContent(type: change.type, value: data))
        }
      }
    }
  }

  /// Only the confirmed dialog action, or a suppressed prompt, may reach terminate.
  func commitQuit() {
    quitAuthorized = true
    NSApp.terminate(self)
  }
}

enum DeleteItemConfirmationStore {
  static var isSuppressed: Bool {
    get { LabDefaults.suite.bool(forKey: DeleteItemConfirmation.suppressKeyName) }
    set { LabDefaults.suite.set(newValue, forKey: DeleteItemConfirmation.suppressKeyName) }
  }
}
