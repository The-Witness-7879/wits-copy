import AppKit
import Defaults
import Sauce

/// Why an explicit paste cannot land in the field that was focused before the panel opened.
enum ExplicitPasteFailure: Equatable, Sendable {
  case noTarget
  case accessibilityDenied
  case targetInvalid
}

enum ExplicitPasteResult: Equatable, Sendable {
  case pasted(pid: pid_t)
  case suppressed
  case duplicate
  case failed(ExplicitPasteFailure)

  /// Localization key for a wireable failure. Nil when nothing should be shown.
  var failureMessageKey: String? {
    switch self {
    case .failed(.noTarget):
      return "paste_no_target"
    case .failed(.accessibilityDenied):
      return "paste_accessibility_denied"
    case .failed(.targetInvalid):
      return "paste_target_invalid"
    case .pasted, .suppressed, .duplicate:
      return nil
    }
  }
}

enum PasteFocusState: Equatable, Sendable {
  case missing
  case untrusted
  case invalid
  case ready(pid: pid_t)
}

/// Collapses a double-click that is delivered more than once. A failed attempt
/// does not consume the item, so a later gesture can retry. The same event cannot.
struct ExplicitPasteLedger: Equatable {
  var consumedEventNumbers: Set<Int> = []
  var inFlight = false
  var lastPasteItem: UUID?
  var lastPasteTime: TimeInterval = -.greatestFiniteMagnitude

  mutating func begin(
    itemID: UUID,
    eventNumber: Int,
    now: TimeInterval,
    interval: TimeInterval
  ) -> Bool {
    if inFlight { return false }
    if eventNumber != 0, consumedEventNumbers.contains(eventNumber) { return false }
    if lastPasteItem == itemID, now - lastPasteTime < interval { return false }
    inFlight = true
    if eventNumber != 0 { consumedEventNumbers.insert(eventNumber) }
    return true
  }

  mutating func notePasted(itemID: UUID, now: TimeInterval) {
    lastPasteItem = itemID
    lastPasteTime = now
    inFlight = false
  }

  mutating func cancelInFlight() {
    inFlight = false
  }

  mutating func reset() {
    consumedEventNumbers.removeAll()
    inFlight = false
    lastPasteItem = nil
    lastPasteTime = -.greatestFiniteMagnitude
  }
}

struct ExplicitPasteEffects {
  var hideWithoutUnpinning: () -> Void
  var restoreFocus: () -> Bool
  var focusedPID: () -> pid_t?
  var copy: () -> Void
  var sendPasteKey: (pid_t) -> Void
  /// Present so a test can prove the explicit path never uses them.
  var sessionTap: () -> Void
  var activate: (pid_t) -> Void
}

enum ExplicitPastePerformer {
  static func submit(
    itemID: UUID,
    eventNumber: Int,
    now: TimeInterval,
    interval: TimeInterval,
    ledger: inout ExplicitPasteLedger,
    state: PasteFocusState,
    selfPID: pid_t,
    effects: ExplicitPasteEffects
  ) -> ExplicitPasteResult {
    guard ledger.begin(
      itemID: itemID,
      eventNumber: eventNumber,
      now: now,
      interval: interval
    ) else {
      return .duplicate
    }
    let result = perform(state: state, selfPID: selfPID, effects: effects)
    if case .pasted = result {
      ledger.notePasted(itemID: itemID, now: now)
    } else {
      ledger.cancelInFlight()
    }
    return result
  }

  /// Hides only when the recorded field is still the one we will paste into.
  /// Never activates an app and never posts a session-tap key.
  static func perform(
    state: PasteFocusState,
    selfPID: pid_t,
    effects: ExplicitPasteEffects
  ) -> ExplicitPasteResult {
    switch state {
    case .untrusted:
      NSLog(
        "[WitsCopy] paste blocked: AXIsProcessTrusted=%d bundle=%@ path=%@",
        AXIsProcessTrusted() ? 1 : 0,
        Bundle.main.bundleIdentifier ?? "?",
        Bundle.main.bundlePath
      )
      return .failed(.accessibilityDenied)
    case .missing:
      return .failed(.noTarget)
    case .invalid:
      return .failed(.targetInvalid)
    case .ready(let pid):
      guard pid > 0, pid != selfPID else { return .failed(.noTarget) }
      // Copy first so the payload is ready, then hide (pinned preference unchanged),
      // restore the recorded field, and send once. A failed restore must not send.
      effects.copy()
      effects.hideWithoutUnpinning()
      guard effects.restoreFocus() else { return .failed(.targetInvalid) }
      guard let focused = effects.focusedPID(), focused == pid, focused != selfPID else {
        return .failed(.targetInvalid)
      }
      effects.sendPasteKey(pid)
      return .pasted(pid: pid)
    }
  }
}

class Clipboard {
  static let shared = Clipboard()

  typealias OnNewCopyHook = (HistoryItem) -> Void

  private var onNewCopyHooks: [OnNewCopyHook] = []
  var changeCount: Int

  private let pasteboard: NSPasteboard
  private let sourceAppBundleProvider: () -> String?

  private var timer: Timer?
  private(set) var isMonitoring = false

  private var mayTouchPasteboard: Bool {
    !LabRuntime.isIsolated || (LabRuntime.isUnitTestProcess && pasteboard.name != .general)
  }

  /// Test seam. Receives an identifier only, never pasteboard text.
  var copyProbe: ((ObjectIdentifier, Bool) -> Void)?
  var explicitPasteLedger = ExplicitPasteLedger()
  var lastExplicitPasteResult: ExplicitPasteResult?
  var explicitPasteFeedbackKey: String?
  var explicitHideProbe: (() -> Void)?
  var explicitRestoreProbe: (() -> Void)?
  var explicitPasteKeyProbe: ((pid_t) -> Void)?
  var explicitSessionTapProbe: (() -> Void)?
  var explicitActivateProbe: ((pid_t) -> Void)?

  private let dynamicTypePrefix = "dyn."
  private let microsoftSourcePrefix = "com.microsoft.ole.source."
  private let supportedTypes: Set<NSPasteboard.PasteboardType> = [
    .fileURL,
    .heic,
    .html,
    .jpeg,
    .png,
    .rtf,
    .string,
    .tiff
  ]
  private let ignoredTypes: Set<NSPasteboard.PasteboardType> = [
    .autoGenerated,
    .concealed,
    .transient
  ]

  private var enabledTypes: Set<NSPasteboard.PasteboardType> { Defaults[.enabledPasteboardTypes] }
  private var disabledTypes: Set<NSPasteboard.PasteboardType> { supportedTypes.subtracting(enabledTypes) }

  private var sourceApp: NSRunningApplication? { NSWorkspace.shared.frontmostApplication }

  init(
    pasteboard: NSPasteboard = .general,
    sourceAppBundleProvider: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
  ) {
    self.pasteboard = pasteboard
    self.sourceAppBundleProvider = sourceAppBundleProvider
    // Unit tests may exercise a private named board, never the system board.
    changeCount = 0
    if mayTouchPasteboard { changeCount = pasteboard.changeCount }
  }

  func onNewCopy(_ hook: @escaping OnNewCopyHook) {
    onNewCopyHooks.append(hook)
  }

  func clearHooks() {
    onNewCopyHooks = []
  }

  func start() {
    guard LabRuntime.shouldMonitorPasteboard(settingEnabled: Defaults[.captureClipboard]) else {
      return
    }
    guard timer == nil else { return }
    isMonitoring = true
    timer = Timer.scheduledTimer(
      timeInterval: Defaults[.clipboardCheckInterval],
      target: self,
      selector: #selector(checkForChangesInPasteboard),
      userInfo: nil,
      repeats: true
    )
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    isMonitoring = false
  }

  func restart() {
    stop()
    start()
  }

  @MainActor
  func copyInWitsCopy(_ string: String) {
    guard mayTouchPasteboard else { return }
    pasteboard.clearContents()
    pasteboard.setString(string, forType: .string)
    pasteboard.setString("", forType: .fromWitsCopy)
    pasteboard.setString(NSPasteboard.PasteboardType.fromWitsCopy.rawValue, forType: .source)
    sync()
    checkForChangesInPasteboard()
  }

  @MainActor
  func copy(_ item: HistoryItem?, removeFormatting: Bool = false) {
    guard let item else { return }
    copyProbe?(ObjectIdentifier(item), removeFormatting)
    guard mayTouchPasteboard else { return }

    pasteboard.clearContents()
    var contents = item.contents

    if removeFormatting {
      contents = clearFormatting(contents)
    }

    for content in contents {
      guard content.type != NSPasteboard.PasteboardType.fileURL.rawValue else { continue }
      pasteboard.setData(content.value, forType: NSPasteboard.PasteboardType(content.type))
    }

    // Use writeObjects for file URLs so that multiple files that are copied actually work.
    // Only do this for file URLs because it causes an issue with some other data types (like formatted text)
    // where the item is pasted more than once.
    let fileURLItems: [NSPasteboardItem] = contents.compactMap { item in
      guard item.type == NSPasteboard.PasteboardType.fileURL.rawValue else { return nil }
      guard let value = item.value else { return nil }
      let pasteItem = NSPasteboardItem()
      pasteItem.setData(value, forType: NSPasteboard.PasteboardType(item.type))
      return pasteItem
    }
    pasteboard.writeObjects(fileURLItems)

    pasteboard.setString("", forType: .fromWitsCopy)
    pasteboard.setString(item.application ?? "", forType: .source)
    // Isolated runs (tests, previews, smoke) never sync the board back into history.
    if mayTouchPasteboard {
      sync()
    }

    Task {
      Notifier.notify(body: item.title, sound: .knock)
      if mayTouchPasteboard {
        checkForChangesInPasteboard()
      }
    }
  }

  func resetExplicitPasteClaim() {
    explicitPasteLedger.reset()
  }

  /// One explicit paste into the field recorded before the panel was shown.
  /// Isolated sessions (tests, previews, smoke) return `.suppressed`.
  /// Do not also call `paste()`: that uses a session tap and can hit this app.
  @MainActor
  @discardableResult
  func submitExplicitPaste(
    item: HistoryItem?,
    itemID: UUID,
    eventNumber: Int,
    removeFormatting: Bool,
    now: TimeInterval = Date().timeIntervalSinceReferenceDate
  ) -> ExplicitPasteResult {
    if LabRuntime.isIsolated {
      lastExplicitPasteResult = .suppressed
      explicitPasteFeedbackKey = nil
      return .suppressed
    }
    let result = ExplicitPastePerformer.submit(
      itemID: itemID,
      eventNumber: eventNumber,
      now: now,
      interval: NSEvent.doubleClickInterval,
      ledger: &explicitPasteLedger,
      state: currentFocusState(),
      selfPID: ProcessInfo.processInfo.processIdentifier,
      effects: liveExplicitEffects(item: item, removeFormatting: removeFormatting)
    )
    lastExplicitPasteResult = result
    explicitPasteFeedbackKey = result.failureMessageKey
    return result
  }

  @MainActor
  private func currentFocusState() -> PasteFocusState {
    guard let panel = AppState.shared.appDelegate?.panel else { return .missing }
    switch panel.pasteFocusAvailability {
    case .untrusted:
      return .untrusted
    case .noElement:
      return .missing
    case .recorded(let snapshot):
      let running = NSRunningApplication(processIdentifier: snapshot.processIdentifier)
      return PasteFocusCapture.pasteState(
        recordedPID: snapshot.processIdentifier,
        terminated: running?.isTerminated ?? true,
        selfPID: ProcessInfo.processInfo.processIdentifier
      )
    }
  }

  @MainActor
  private func liveExplicitEffects(
    item: HistoryItem?,
    removeFormatting: Bool
  ) -> ExplicitPasteEffects {
    ExplicitPasteEffects(
      hideWithoutUnpinning: { [weak self] in
        self?.explicitHideProbe?()
        AppState.shared.appDelegate?.panel?.hideForExplicitPaste()
      },
      restoreFocus: { [weak self] in
        self?.explicitRestoreProbe?()
        guard !LabRuntime.isIsolated else { return false }
        return AppState.shared.appDelegate?.panel?.restoreRecordedFocus() ?? false
      },
      focusedPID: {
        guard !LabRuntime.isIsolated else { return nil }
        let selfPID = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, front != selfPID {
          return front
        }
        if let pid = PasteFocusCapture.focusedPID(), pid != selfPID {
          return pid
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
      },
      copy: { [weak self] in
        self?.copy(item, removeFormatting: removeFormatting)
      },
      sendPasteKey: { [weak self] pid in
        self?.deliverExplicitPasteKey(to: pid)
      },
      sessionTap: { [weak self] in
        self?.explicitSessionTapProbe?()
      },
      activate: { [weak self] pid in
        self?.explicitActivateProbe?(pid)
      }
    )
  }

  /// Preference and modifier paste. Unchanged: session tap, no recorded-field check.
  // Based on https://github.com/Clipy/Clipy/blob/develop/Clipy/Sources/Services/PasteService.swift.
  func paste() {
    guard mayTouchPasteboard else { return }
    // 权限提示不在这里做：粘贴失败会回报 .accessibilityDenied，
    // 由面板弹出询问并提供系统设置入口。
    let events = makePasteKeyEvents()
    events.down?.post(tap: .cgSessionEventTap)
    events.up?.post(tap: .cgSessionEventTap)
  }

  /// Cmd-V into the recorded process. Refuses this process. `postToPid` does not
  /// insert into an NSTextField on this Mac. A session tap does, but only while
  /// that pid is already frontmost, so the key cannot land in the app. The source
  /// must permit keyboard events during the click-suppression interval, or the
  /// double-click that started the paste eats Cmd-V.
  func deliverExplicitPasteKey(to pid: pid_t) {
    guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { return }
    explicitPasteKeyProbe?(pid)
    guard mayTouchPasteboard else { return }
    if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
      explicitActivateProbe?(pid)
      NSRunningApplication(processIdentifier: pid)?.activate(options: [])
      let end = Date().addingTimeInterval(0.6)
      while Date() < end, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
      }
    }
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
    explicitSessionTapProbe?()
    let source = CGEventSource(stateID: .combinedSessionState)
    source?.setLocalEventsFilterDuringSuppressionState(
      [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
      state: .eventSuppressionStateSuppressionInterval
    )
    let cmdFlag = CGEventFlags(rawValue: UInt64(KeyChord.pasteKeyModifiers.rawValue) | 0x000008)
    var vCode = Sauce.shared.keyCode(for: KeyChord.pasteKey)
    if KeyboardLayout.current.commandSwitchesToQWERTY && cmdFlag.contains(.maskCommand) {
      vCode = KeyChord.pasteKey.QWERTYKeyCode
    }
    let down = CGEvent(keyboardEventSource: source, virtualKey: vCode, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: vCode, keyDown: false)
    down?.flags = cmdFlag
    up?.flags = cmdFlag
    down?.post(tap: .cgSessionEventTap)
    up?.post(tap: .cgSessionEventTap)
  }

  private func makePasteKeyEvents() -> (down: CGEvent?, up: CGEvent?) {
    // Add flag that left/right modifier key has been pressed.
    // See https://github.com/TermiT/Flycut/pull/18 for details.
    let cmdFlag = CGEventFlags(rawValue: UInt64(KeyChord.pasteKeyModifiers.rawValue) | 0x000008)
    var vCode = Sauce.shared.keyCode(for: KeyChord.pasteKey)

    // Force QWERTY keycode when keyboard layout switches to
    // QWERTY upon pressing ⌘ key (e.g. "Dvorak - QWERTY ⌘").
    // See https://github.com/p0deje/Maccy/issues/482 for details.
    if KeyboardLayout.current.commandSwitchesToQWERTY && cmdFlag.contains(.maskCommand) {
      vCode = KeyChord.pasteKey.QWERTYKeyCode
    }

    let source = CGEventSource(stateID: .combinedSessionState)
    source?.setLocalEventsFilterDuringSuppressionState(
      [.permitLocalMouseEvents, .permitSystemDefinedEvents],
      state: .eventSuppressionStateSuppressionInterval
    )
    let keyVDown = CGEvent(keyboardEventSource: source, virtualKey: vCode, keyDown: true)
    let keyVUp = CGEvent(keyboardEventSource: source, virtualKey: vCode, keyDown: false)
    keyVDown?.flags = cmdFlag
    keyVUp?.flags = cmdFlag
    return (keyVDown, keyVUp)
  }

  func clear() {
    guard mayTouchPasteboard else { return }
    guard Defaults[.clearSystemClipboard] else {
      return
    }

    pasteboard.clearContents()
  }

  @objc
  @MainActor
  func checkForChangesInPasteboard() { // swiftlint:disable:this cyclomatic_complexity
    guard mayTouchPasteboard else { return }
    guard pasteboard.changeCount != changeCount else {
      return
    }

    changeCount = pasteboard.changeCount

    let items = pasteboard.pasteboardItems ?? []
    let isFromWitsCopy = items.contains { $0.types.contains(.fromWitsCopy) }
    let sourceBundle = sourceAppBundleProvider()
    let protectSensitiveContent = Defaults[.protectSensitiveContent]
    if !isFromWitsCopy {
      // External copy occurred. Stop the current paste stack.
      AppState.shared.history.interruptPasteStack()
    }

    // The board can advertise types missing from individual items (and vice versa).
    // Concealed, transient, and auto-generated content is always ignored.
    let types = Set(pasteboard.types ?? []).union(items.flatMap(\.types))
    let filesEnabled = enabledTypes.contains(.fileURL)
    let videosEnabled = Defaults[.saveVideos]
    if shouldIgnore(types, videosEnabled: videosEnabled) {
      return
    }
    if !isFromWitsCopy && ClipboardIgnoreRules.shouldIgnore(
      sourceAppBundle: sourceBundle,
      ignoredApps: Defaults[.ignoredApps],
      ignoreAllAppsExceptListed: Defaults[.ignoreAllAppsExceptListed]
    ) {
      return
    }
    // Reject marked secrets before isEmptyString/richText or any body data read.
    if protectSensitiveContent && (
      SensitiveContentDetector.isSensitiveSource(sourceBundle) ||
        SensitiveContentDetector.hasSensitivePasteboardType(Set(types.map(\.rawValue)))
    ) {
      return
    }

    // Files and videos share `.fileURL`; decide each item by its URL. A copy whose
    // only files are all switched off is dropped whole, so Finder's companion
    // filename text and icon do not slip in as a text or image record.
    let fileDecisions = items.map {
      CaptureFilePolicy.decision(for: $0, filesEnabled: filesEnabled, videosEnabled: videosEnabled)
    }
    if fileDecisions.contains(.rejected) && !fileDecisions.contains(.allowed) {
      return
    }

    // Some applications (BBEdit, Edge) add 2 items to pasteboard when copying
    // so it's better to merge all data into a single record.
    // - https://github.com/p0deje/Maccy/issues/78
    // - https://github.com/p0deje/Maccy/issues/472
    var contents = [HistoryItemContent]()
    var privacyRepresentations = [[SensitiveContentDetector.Representation]]()
    zip(items, fileDecisions).forEach({ item, fileDecision in
      if fileDecision == .rejected { return }
      var types = Set(item.types)
      if types.contains(.string) && isEmptyString(item) && !richText(item) {
        return
      }

      var removed = disabledTypes
      if fileDecision == .allowed { removed.remove(.fileURL) }
      types = types
        .subtracting(removed)
        .filter { !$0.rawValue.starts(with: dynamicTypePrefix) }
        .filter { !$0.rawValue.starts(with: microsoftSourcePrefix) }

      // Avoid reading Microsoft Word links from bookmarks and cross-references.
      // https://github.com/p0deje/Maccy/issues/613
      // https://github.com/p0deje/Maccy/issues/770
      if types.isSuperset(of: [.microsoftLinkSource, .microsoftObjectLink]) {
        types = types.subtracting([.microsoftLinkSource, .microsoftObjectLink, .pdf])
      }

      let itemContents = types.map { type in
        HistoryItemContent(type: type.rawValue, value: item.data(forType: type))
      }
      contents.append(contentsOf: itemContents)
      if protectSensitiveContent {
        privacyRepresentations.append(itemContents.map { (type: $0.type, data: $0.value) })
      }
    })

    guard !contents.isEmpty else {
      return
    }

    // A sensitive capture never becomes a HistoryItem, including on macOS 14
    // where creating and immediately inserting the item precedes the add hooks.
    if protectSensitiveContent && SensitiveContentDetector.containsSensitiveContent(inItems: privacyRepresentations) {
      return
    }

    let historyItem = HistoryItem(contents: contents)

    if #unavailable(macOS 15.0) {
      // On macOS 14 the history item needs to be inserted into storage directly after creating it.
      try? History.shared.insertIntoStorage(historyItem)
    }

    historyItem.application = sourceBundle
    historyItem.title = historyItem.generateTitle()

    onNewCopyHooks.forEach({ $0(historyItem) })
  }

  private func shouldIgnore(_ types: Set<NSPasteboard.PasteboardType>, videosEnabled: Bool) -> Bool {
    // Videos ride on `.fileURL`; keep that type in play while the video switch is on.
    let accepted = videosEnabled ? enabledTypes.union([.fileURL]) : enabledTypes
    return types.isDisjoint(with: accepted) || !types.isDisjoint(with: ignoredTypes)
  }

  private func isEmptyString(_ item: NSPasteboardItem) -> Bool {
    guard let string = item.string(forType: .string) else {
      return true
    }

    return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func richText(_ item: NSPasteboardItem) -> Bool {
    if let rtf = item.data(forType: .rtf) {
      if let attributedString = NSAttributedString(rtf: rtf, documentAttributes: nil) {
        return !attributedString.string.isEmpty
      }
    }

    if let html = item.data(forType: .html) {
      if let attributedString = NSAttributedString(html: html, documentAttributes: nil) {
        return !attributedString.string.isEmpty
      }
    }

    return false
  }

  // Some applications requires window be unfocused and focused back to sync the clipboard.
  // - Chrome Remote Desktop (https://github.com/p0deje/Maccy/issues/948)
  // - Netbeans (https://github.com/p0deje/Maccy/issues/879)
  private func sync() {
    guard !LabRuntime.isUnitTestProcess else { return }
    guard let app = sourceApp,
          app.bundleURL?.lastPathComponent == "Chrome Remote Desktop.app" ||
            app.localizedName?.contains("NetBeans") == true else {
      return
    }

    NSApp.activate(ignoringOtherApps: true)
    NSApp.hide(self)
  }

  private func clearFormatting(_ contents: [HistoryItemContent]) -> [HistoryItemContent] {
    var newContents: [HistoryItemContent] = contents
    let stringContents = contents.filter { NSPasteboard.PasteboardType($0.type) == .string }

    // If there is no string representation of data,
    // behave like we didn't have to remove formatting.
    if !stringContents.isEmpty {
      newContents = stringContents

      // Preserve file URLs.
      // https://github.com/p0deje/Maccy/issues/962
      let fileURLContents = contents.filter { NSPasteboard.PasteboardType($0.type) == .fileURL }
      if !fileURLContents.isEmpty {
        newContents += fileURLContents
      }
    }

    return newContents
  }
}
