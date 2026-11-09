import ApplicationServices
import Defaults
import SwiftUI

/// Focus recorded before the panel is shown. The window title is diagnostic only;
/// paste never searches for another window or field by title.
struct PasteFocusSnapshot: Equatable, Sendable {
  var processIdentifier: pid_t
  var bundleIdentifier: String?
  var localizedName: String?
  var windowTitle: String?
  var role: String?
  var subrole: String?
  var identifier: String?
}

enum PasteFocusAvailability: Equatable, Sendable {
  case untrusted
  case noElement
  case recorded(PasteFocusSnapshot)
}

/// Left-edge live drag belongs to the rail. Syncing the split first writes that
/// delta into the list, and a later early return cannot undo it.
enum PanelLiveResize {
  static func absorbsSplit(inLiveResize: Bool, railVisible: Bool, minXDelta: CGFloat) -> Bool {
    if inLiveResize, railVisible, abs(minXDelta) > 0.5 { return false }
    return true
  }
}

final class PasteFocusRecord {
  let snapshot: PasteFocusSnapshot
  let application: AXUIElement?
  let window: AXUIElement?
  let element: AXUIElement?

  init(
    snapshot: PasteFocusSnapshot,
    application: AXUIElement?,
    window: AXUIElement?,
    element: AXUIElement?
  ) {
    self.snapshot = snapshot
    self.application = application
    self.window = window
    self.element = element
  }
}

enum PasteFocusCapture {
  /// A named field must be another live process and a real input element.
  static func accept(
    pid: pid_t?,
    terminated: Bool,
    hasElement: Bool,
    selfPID: pid_t
  ) -> Bool {
    guard let pid, pid > 0, pid != selfPID, !terminated, hasElement else { return false }
    return true
  }

  /// Paste does not require a named field. Another live app is enough:
  /// hide, activate it, and send ⌘V, the same way upstream Maccy does.
  static func acceptApplication(pid: pid_t?, terminated: Bool, selfPID: pid_t) -> Bool {
    guard let pid, pid > 0, pid != selfPID, !terminated else { return false }
    return true
  }

  static func pasteState(recordedPID: pid_t?, terminated: Bool, selfPID: pid_t) -> PasteFocusState {
    guard let recordedPID else { return .missing }
    guard acceptApplication(pid: recordedPID, terminated: terminated, selfPID: selfPID) else {
      return .invalid
    }
    return .ready(pid: recordedPID)
  }

  /// Reads the system focused application, window, and UI element. Does not prompt,
  /// activate, or post keys. Isolated sessions do not call AX.
  static func liveRecord() -> PasteFocusRecord? {
    guard !LabRuntime.isIsolated else { return nil }
    guard Accessibility.isTrusted else { return nil }
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 0.8)
    guard let app = copyElement(system, kAXFocusedApplicationAttribute) else { return nil }
    let pid = elementPID(app)
    let running = NSRunningApplication(processIdentifier: pid)
    let window = copyElement(app, kAXFocusedWindowAttribute)
    let element = copyElement(app, kAXFocusedUIElementAttribute)
      ?? copyElement(system, kAXFocusedUIElementAttribute)
    guard accept(
      pid: pid,
      terminated: running?.isTerminated ?? true,
      hasElement: element != nil,
      selfPID: ProcessInfo.processInfo.processIdentifier
    ), let element else { return nil }
    guard elementPID(element) == pid, PasteFocusProbe.isUsable(element) else { return nil }
    return PasteFocusRecord(
      snapshot: PasteFocusSnapshot(
        processIdentifier: pid,
        bundleIdentifier: running?.bundleIdentifier,
        localizedName: running?.localizedName,
        windowTitle: window.flatMap { copyString($0, kAXTitleAttribute) },
        role: copyString(element, kAXRoleAttribute),
        subrole: copyString(element, kAXSubroleAttribute),
        identifier: copyString(element, kAXIdentifierAttribute)
      ),
      application: app,
      window: window,
      element: element
    )
  }

  /// The other app that is in front, even when it does not expose a text field.
  static func frontApplicationRecord() -> PasteFocusRecord? {
    guard !LabRuntime.isIsolated else { return nil }
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let pid = app.processIdentifier
    guard acceptApplication(
      pid: pid,
      terminated: app.isTerminated,
      selfPID: ProcessInfo.processInfo.processIdentifier
    ) else { return nil }
    return PasteFocusRecord(
      snapshot: PasteFocusSnapshot(
        processIdentifier: pid,
        bundleIdentifier: app.bundleIdentifier,
        localizedName: app.localizedName,
        windowTitle: nil,
        role: nil,
        subrole: nil,
        identifier: nil
      ),
      application: nil,
      window: nil,
      element: nil
    )
  }

  static func elementPID(_ element: AXUIElement) -> pid_t {
    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success else { return 0 }
    return pid
  }

  static func focusedPID() -> pid_t? {
    guard !LabRuntime.isIsolated, Accessibility.isTrusted else { return nil }
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 0.8)
    guard let element = copyElement(system, kAXFocusedUIElementAttribute) else { return nil }
    let pid = elementPID(element)
    return pid > 0 ? pid : nil
  }

  static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(value, to: AXUIElement.self)
  }

  static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? String
  }
}

enum PasteFocusProbe {
  static func isUsable(_ element: AXUIElement) -> Bool {
    guard !LabRuntime.isIsolated else { return false }
    var value: CFTypeRef?
    AXUIElementSetMessagingTimeout(element, 0.8)
    return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success
  }
}

// An NSPanel subclass that implements floating panel traits.
// https://stackoverflow.com/questions/46023769/how-to-show-a-window-without-stealing-focus-on-macos

enum PanelWindowLevel {
  /// Pinned stays at floating. Unpinned uses popUpMenu so it remains above
  /// ordinary windows but below help tooltips. screenSaver composites above them.
  static func popup(pinned: Bool) -> NSWindow.Level {
    pinned ? .floating : .popUpMenu
  }
}
protocol LocalRecordingKeyWindow: AnyObject {
  func requestLocalRecordingKey()
  func releaseLocalRecordingKey()
}

protocol BrowsingEscapeTapClient: AnyObject {
  func consumeBrowsingEscapeFromTap(keyCode: Int64) -> Bool
}

/// Session tap that can swallow only Esc, and only while its owner is a visible
/// non-key browsing panel. Other key codes are returned immediately and are not
/// stored. Creating the port still requires an already-trusted process; this
/// type never prompts.
final class BrowsingEscapeTap {
  weak var owner: BrowsingEscapeTapClient?
  private var port: CFMachPort?
  private var source: CFRunLoopSource?
  private(set) var installed = false

  func install() -> Bool {
    guard port == nil else { return installed }
    let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
    guard let created = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: mask,
      callback: Self.callback,
      userInfo: Unmanaged.passUnretained(self).toOpaque()
    ) else {
      return false
    }
    port = created
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
    self.source = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: created, enable: true)
    installed = true
    return true
  }

  func remove() {
    if let port {
      CGEvent.tapEnable(tap: port, enable: false)
      if let source {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
      }
      CFMachPortInvalidate(port)
    }
    port = nil
    source = nil
    installed = false
    owner = nil
  }

  deinit { remove() }

  private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
    guard type == .keyDown, let userInfo else {
      return Unmanaged.passUnretained(event)
    }
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    guard keyCode == PanelEscapeTap.escapeKeyCode else {
      return Unmanaged.passUnretained(event)
    }
    let tap = Unmanaged<BrowsingEscapeTap>.fromOpaque(userInfo).takeUnretainedValue()
    guard let owner = tap.owner, owner.consumeBrowsingEscapeFromTap(keyCode: keyCode) else {
      return Unmanaged.passUnretained(event)
    }
    return nil
  }
}

class FloatingPanel<Content: View>: NSPanel, NSWindowDelegate, LocalRecordingKeyWindow, BrowsingEscapeTapClient {
  var isPresented: Bool = false
  var statusBarButton: NSStatusBarButton?
  let onClose: () -> Void
  /// Set while applying the frame back into the split, so a hosting-view
  /// layout pass cannot re-enter and write a stale width.
  private var isSyncingSplit = false
  /// A close requested mid-resize; performed when the resize ends.
  private var closesAfterLiveResize = false
  /// 上一次拖动中的 frame，用来判断用户拖的是哪条边。
  private var lastLiveFrame: CGRect?
  /// True only after the user clicks search, the original-text editor, or the
  /// shortcut recorder. Show and row clicks leave this false, so the panel
  /// does not take the insertion point.
  var acceptsKeyForEditing = false
  private var outsideMonitor: Any?
  private var localInputMonitor: Any?
  private var escapeTap: BrowsingEscapeTap?
  private var lastBrowsingInput: String?
  private var lastBrowsingConsumed = false
  private var escapeCancelArmed = false
  private(set) var escapeTapBlockedUntrusted = false
  private(set) var escapeTapCreateFailed = false
  var localBrowsingMonitorInstalled: Bool { localInputMonitor != nil }
  var escapeTapInstalled: Bool { escapeTap?.installed == true }
  private(set) var didStartPresentation = false
  var pasteFocus: PasteFocusRecord?
  var pasteFocusAvailability: PasteFocusAvailability = .noElement
  /// Replaced in tests. The default does not call AX while isolated.
  var pasteFocusSource: () -> PasteFocusRecord? = {
    guard !LabRuntime.isIsolated else { return nil }
    return PasteFocusCapture.liveRecord()
  }

  /// Capture runs before this. Taking key does not retarget paste.
  static func shouldMakeKeyOnShow() -> Bool { true }

  override var isMovable: Bool {
    get { Defaults[.popupPosition] != .statusItem }
    set {}
  }

  init(
    contentRect: NSRect,
    identifier: String = "",
    statusBarButton: NSStatusBarButton? = nil,
    onClose: @escaping () -> Void,
    view: () -> Content
  ) {
    self.onClose = onClose

    super.init(
        contentRect: contentRect,
        styleMask: [.nonactivatingPanel, .titled, .resizable, .closable, .miniaturizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )

    self.statusBarButton = statusBarButton
    self.identifier = NSUserInterfaceItemIdentifier(identifier)

    delegate = self

    animationBehavior = .none
    isFloatingPanel = true
    // popUpMenu (101) is above normal windows and below help (200).
    // screenSaver (1000) is composited in front of tooltip windows, so hover
    // help never appears. Pinned windows use floating, also below help.
    // Lock-screen shield stays above popUpMenu; collection behavior is unchanged.
    level = PanelWindowLevel.popup(pinned: false)
    collectionBehavior = [.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary]
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    // Title-bar drags stay on `isMovable`. Background drags must not move the popup,
    // and later hover/exit paths are not allowed to turn this back on.
    PanelWindowDrag.lock(self)
    hidesOnDeactivate = false
    backgroundColor = .clear
    titlebarSeparatorStyle = .none

    // Real traffic lights. Closing hides the panel even while it is pinned;
    // minimizing and zooming do not apply to a deliberately sized popup.
    isReleasedWhenClosed = false
    if let close = standardWindowButton(.closeButton) {
      close.isHidden = false
      close.isEnabled = true
    }
    // Minimizing and zooming never apply here. Hiding the disabled buttons lets
    // the header's leading band match the rail width instead of reserving 70pt.
    if let minimize = standardWindowButton(.miniaturizeButton) {
      minimize.isHidden = true
      minimize.isEnabled = false
    }
    if let zoom = standardWindowButton(.zoomButton) {
      zoom.isHidden = true
      zoom.isEnabled = false
    }

    let hosting = NSHostingView(
      rootView: view()
        // The safe area is ignored because the title bar still interferes with the geometry
        .ignoresSafeArea()
    )
    // The root is ModifiedContent after these modifiers, not Content. Configure
    // the inferred hosting type before erasing it to NSView.
    hosting.sizingOptions = []
    contentView = hosting
    contentView?.layer?.cornerRadius = Popup.cornerRadius + Popup.horizontalPadding
  }

  deinit {
    removeBrowsingInputMonitors()
  }

  func toggle(height: CGFloat, at popupPosition: PopupPosition = Defaults[.popupPosition]) {
    if isPresented {
      close()
    } else {
      open(height: height, at: popupPosition)
    }
  }

  func open(height: CGFloat, at popupPosition: PopupPosition = Defaults[.popupPosition]) {
    didStartPresentation = false
    capturePasteTarget()
    Clipboard.shared.resetExplicitPasteClaim()
    // 呼出即可交互：搜索、快捷键、ESC 都要能直接收到键盘。
    // 粘贴目标已在 capturePasteTarget() 里记录，成为 key 不会改写到别的窗口。
    acceptsKeyForEditing = true
    AppState.shared.workspaceSection = WorkspaceSection.resolvedForOpen(AppState.shared.workspaceSection)
    level = PanelWindowLevel.popup(pinned: AppState.shared.windowPinned)
    _ = height
    let preview = AppState.shared.preview
    let context = PopupPlacementContext.live(statusBarButton: statusBarButton)
    let placed = popupPosition.layout(saved: preview.savedSplit(), in: context)
    preview.applyLayout(split: placed.split)
    setFrame(placed.frame, display: true)
    presentOpenedPanel()
    isPresented = true
    AppState.shared.panelPresented = true
    installBrowsingInputMonitors()

    if popupPosition == .statusItem {
      DispatchQueue.main.async {
        self.statusBarButton?.isHighlighted = true
      }
    }
  }

  /// Remember the other app before any ordering. A named field is used when
  /// Accessibility can see one. If it cannot, the frontmost other app is still
  /// the paste target: hide, activate it, and send ⌘V.
  func capturePasteTarget() {
    let mayRead = !LabRuntime.isIsolated
    if mayRead, !Accessibility.isTrusted {
      pasteFocus = nil
      pasteFocusAvailability = .untrusted
      // Diagnostics: `log show --predicate 'process == "WitsCopy"'`.
      NSLog(
        "[WitsCopy] accessibility untrusted bundle=%@",
        Bundle.main.bundleIdentifier ?? "?"
      )
      return
    }
    let record = pasteFocusSource() ?? (mayRead ? PasteFocusCapture.frontApplicationRecord() : nil)
    pasteFocus = record
    if let record {
      pasteFocusAvailability = .recorded(record.snapshot)
    } else {
      pasteFocusAvailability = .noElement
    }
  }

  /// Pinned panel stays up when the user clicks another app. Rewrite the target
  /// only after that app is actually in front, and do not wipe a good target
  /// if the click has not landed yet.
  func noteExternalFocus() {
    guard isPresented, !isKeyWindow else { return }
    let kept = pasteFocus
    capturePasteTarget()
    if pasteFocus == nil, let kept,
       kept.snapshot.processIdentifier != ProcessInfo.processInfo.processIdentifier {
      pasteFocus = kept
      pasteFocusAvailability = .recorded(kept.snapshot)
    }
  }

  /// Show and take the keyboard. Paste still goes to the target recorded in
  /// `capturePasteTarget()` before activation, so taking focus here cannot
  /// redirect a later double-click paste.
  private func presentOpenedPanel() {
    didStartPresentation = true
    if LabRuntime.isSmoke {
      title = "WitsCopy synthetic"
      collectionBehavior.remove(.moveToActiveSpace)
      orderFront(nil)
    } else if !LabRuntime.isIsolated {
      orderFrontRegardless()
      NSApp.activate(ignoringOtherApps: true)
      if Self.shouldMakeKeyOnShow() {
        makeKey()
      }
    }
  }

  /// Hide even when the window-pin preference is on. Does not clear that
  /// preference, and does not drop the recorded input element.
  func hideForExplicitPaste() {
    let pinned = AppState.shared.windowPinned
    acceptsKeyForEditing = false
    if isPresented || isVisible {
      close()
    }
    if AppState.shared.windowPinned != pinned {
      AppState.shared.windowPinned = pinned
    }
  }

  /// Put the cursor back in the field recorded before the panel took the keyboard.
  /// Setting AX focus without activating the app leaves that window visible and
  /// cursorless, and the paste key is then refused.
  func restoreRecordedFocus() -> Bool {
    guard !LabRuntime.isIsolated else { return false }
    guard Accessibility.isTrusted else { return false }
    guard let record = pasteFocus else { return false }
    let pid = record.snapshot.processIdentifier
    guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { return false }
    if let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated {
      running.activate(options: [.activateIgnoringOtherApps])
    }
    if let app = record.application, let window = record.window {
      _ = AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, window)
    }
    if let element = record.element, PasteFocusProbe.isUsable(element) {
      _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }
    let end = Date().addingTimeInterval(0.4)
    while Date() < end, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
  }

  func verticallyResize(to newHeight: CGFloat) {
    _ = newHeight
  }

  func saveWindowPosition() {
    let preview = AppState.shared.preview
    guard !preview.suppressesFramePersistence else { return }
    guard let screenFrame = screen?.visibleFrame else { return }
    let anchor = PanelSplit.relativeAnchor(
      of: preview.persistedFrame(fallback: frame),
      listWidth: preview.layoutListWidth,
      in: screenFrame
    )
    Defaults[.windowPosition] = anchor
  }

  func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
    let preview = AppState.shared.preview
    var finalFrameSize = frameSize
    let visible = sender.screen?.visibleFrame
    finalFrameSize.height = max(finalFrameSize.height, AppState.shared.popup.minimumHeight)

    if preview.state.isOpen {
      let available = visible?.width ?? .greatestFiniteMagnitude
      let floor = PanelSplit.previewFloor(availableWidth: available, listWidth: preview.layoutListWidth)
      let minPreview = min(floor, max(0, available - preview.layoutListWidth))
      finalFrameSize.width = max(
        finalFrameSize.width,
        preview.totalListWidth + minPreview + preview.temporaryOCRWidth
      )
    } else {
      finalFrameSize.width = max(finalFrameSize.width, PanelSplit.minimumList)
    }

    if let visible {
      finalFrameSize.width = min(finalFrameSize.width, visible.width)
      finalFrameSize.height = min(finalFrameSize.height, visible.height)
    }

    // Left-edge classification needs the new origin, which this callback does
    // not have. Syncing here would write that delta into the list before
    // windowDidResize can give it to the rail and return.
    return finalFrameSize
  }

  /// Live resize and AX/setFrame both land here. `setFrame` does not call
  /// `windowWillResize`, and `inLiveResize` stays false, so the list kept its
  /// old fixed width and NSHostingView snapped the window back to it.
  func windowDidResize(_ notification: Notification) {
    alignTrafficLight()
    guard !isSyncingSplit else { return }
    guard AppState.shared.appDelegate?.panel === self else { return }
    let previous = lastLiveFrame
    lastLiveFrame = frame
    let leftEdge = PanelLiveResize.absorbsSplit(
      inLiveResize: inLiveResize,
      railVisible: AppState.shared.managementRailVisible,
      minXDelta: previous.map { frame.minX - $0.minX } ?? 0
    ) == false
    if leftEdge, let previous {
      AppState.shared.adjustRailWidth(frame.width - previous.width)
      return
    }
    syncSplit(to: frame.size)
  }

  /// In-memory split only. Persisting stays on live-resize end and explicit
  /// divider commits; OCR's temporary frame must not be written to Defaults.
  private func syncSplit(to size: NSSize) {
    guard AppState.shared.appDelegate?.panel === self else { return }
    guard size.width.isFinite, size.height.isFinite, size.width > 1, size.height > 1 else { return }
    let preview = AppState.shared.preview
    isSyncingSplit = true
    defer { isSyncingSplit = false }
    if preview.state.isOpen {
      preview.absorbWidth(size.width)
    } else {
      let list = (size.width - preview.temporaryOCRWidth - preview.railExtraWidth).rounded()
      if list.isFinite, list > 0, abs(preview.layoutListWidth - list) > 0.5 {
        preview.layoutListWidth = list
      }
    }
    let height = size.height.rounded()
    if abs(preview.currentHeight - height) > 0.5 {
      preview.currentHeight = height
    }
  }

  func windowDidMove(_ notification: Notification) {
    saveWindowPosition()
  }

  func windowWillStartLiveResize(_ notification: Notification) {
    AppState.shared.preview.cancelAutoOpen()
  }

  func windowDidEndLiveResize(_ notification: Notification) {
    AppState.shared.preview.currentHeight = frame.height
    AppState.shared.preview.endResize()
    saveWindowPosition()
    if closesAfterLiveResize {
      closesAfterLiveResize = false
      close()
    }
  }

  func windowDidBecomeKey(_ notification: Notification) {
    AppState.shared.preview.enableAutoOpen()

    if AppState.shared.navigator.leadHistoryItem != nil {
      AppState.shared.preview.startAutoOpen()
    }
  }

  func windowDidResignKey(_ notification: Notification) {
    AppState.shared.preview.disableAutoOpen()
  }

  // Close automatically when out of focus, e.g. outside click.
  override func resignKey() {
    super.resignKey()
    var context = AppState.shared.focusContext
    if NSApp.alertWindow != nil {
      context.confirmationPresented = true
    }
    // Resizing is using the panel, not leaving it.
    if !inLiveResize, PanelClosePolicy.decide(.resignKey, context: context) == .close {
      close()
    } else if isPresented {
      DispatchQueue.main.async { [weak self] in
        self?.noteExternalFocus()
      }
    }
  }

  // Title-bar clicks often miss the icon button. Deliver them only to a visible
  // action button whose frame contains the point. Do not walk every control:
  // a scroller overlapping a row button must not steal the click.
  // Row and button clicks must not become key. Search and editors may.
  override func sendEvent(_ event: NSEvent) {
    if event.type == .leftMouseDown,
       let content = contentView,
       let button = Self.actionButton(in: content, at: event.locationInWindow) {
      button.mouseDown(with: event)
      return
    }
    let editorClick = event.type == .leftMouseDown
      && Self.hitRequestsKey(contentView?.hitTest(event.locationInWindow))
    if editorClick {
      acceptsKeyForEditing = true
    }
    super.sendEvent(event)
    if editorClick {
      makeKey()
    }
  }

  static func hitRequestsKey(_ view: NSView?) -> Bool {
    var current = view
    while let view = current {
      // Sliders (media scrubber and volume) track the mouse only in the key
      // window; a non-key panel left them inert.
      if view is OriginalTextBodyView
        || view is PinnedShortcutRecorder
        || view is NSSlider {
        return true
      }
      if let rich = view as? RichTextBodyView, rich.allowsEdit {
        return true
      }
      if view.accessibilityIdentifier() == "lab-search-field" {
        return true
      }
      if let field = view as? NSTextField, field.isEditable { return true }
      if let text = view as? NSTextView, text.isEditable { return true }
      current = view.superview
    }
    return false
  }

  static func actionButton(in root: NSView, at windowPoint: NSPoint) -> ImmediateActionButton? {
    var found: ImmediateActionButton?
    func walk(_ view: NSView) {
      if view.isHidden || view.alphaValue < 0.01 { return }
      let inView = view.convert(windowPoint, from: nil)
      if let button = view as? ImmediateActionButton, button.isEnabled {
        if view.bounds.contains(inView) {
          found = button
        }
        return
      }
      if !view.bounds.contains(inView) { return }
      if view is NSScroller { return }
      for subview in view.subviews { walk(subview) }
    }
    walk(root)
    return found
  }

  override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
    if PinRecordingFocus.isCompetingTextEntry(responder) {
      AppState.shared.noteTextEntryFocused(in: self)
    }
    return super.makeFirstResponder(responder)
  }

  /// Esc follows PanelBrowsingKeys. Recording, a menu, a confirmation, and an
  /// editor each keep their own cancel. This path must not hide first.
  override func cancelOperation(_ sender: Any?) {
    let delivery = browsingEscapeDelivery(keyCode: 53)
    if PanelBrowsingKeys.consumes(delivery) {
      applyBrowsingDelivery(delivery)
    }
    // pass / passToEditor stay with the menu, confirmation, or editor.
    // super.cancelOperation closes the panel.
  }

  override func keyDown(with event: NSEvent) {
    guard event.keyCode == 53 else {
      super.keyDown(with: event)
      return
    }
    let delivery = browsingEscapeDelivery(keyCode: 53)
    if PanelBrowsingKeys.consumes(delivery) {
      applyBrowsingDelivery(delivery)
    } else {
      super.keyDown(with: event)
    }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard AppState.shared.panelPresented, AppState.shared.appDelegate?.panel === self else {
      return super.performKeyEquivalent(with: event)
    }
    if let recorder = firstResponder as? PinnedShortcutRecorder, recorder.recording {
      return recorder.performKeyEquivalent(with: event)
    }
    if let body = firstResponder as? OriginalTextBodyView {
      if body.performKeyEquivalent(with: event) { return true }
      return false
    }
    if PanelKeyPolicy.isSearchFieldEditor(firstResponder), PanelKeyPolicy.isNativeTextEdit(event) {
      return super.performKeyEquivalent(with: event)
    }
    if PanelPinRoute.consume(event) { return true }
    return super.performKeyEquivalent(with: event)
  }

  override func close() {
    // AppKit keeps a window on screen while it is being resized, so closing
    // now would only drop the content and leave an empty glass frame that
    // takes no input. Finish the close once the resize ends.
    if inLiveResize {
      closesAfterLiveResize = true
      return
    }
    removeBrowsingInputMonitors()
    acceptsKeyForEditing = false
    AppState.shared.panelPresented = false
    contentView?.layoutSubtreeIfNeeded()
    super.close()
    isPresented = false
    statusBarButton?.isHighlighted = false
    onClose()
  }

  override func orderOut(_ sender: Any?) {
    removeBrowsingInputMonitors()
    super.orderOut(sender)
  }

  // The window is sized by the split layout; titlebar double-clicks and the
  // green button must not zoom or minimize it.
  override func zoom(_ sender: Any?) {}
  override func miniaturize(_ sender: Any?) {}

  /// The title bar re-lays out its buttons on resize, key changes and
  /// appearance changes, so re-apply the position after every window layout.
  override func layoutIfNeeded() {
    super.layoutIfNeeded()
    alignTrafficLight()
  }

  /// Centre the close button on the search/tool row instead of the system's
  /// 28pt title bar, and on the rail's icon column (row inset + icon inset +
  /// half the 16pt slot), so it sits on the same vertical line as the icons
  /// below it in both rail widths.
  private func alignTrafficLight() {
    guard let close = standardWindowButton(.closeButton), let bar = close.superview else { return }
    let size = close.frame.size
    let centerFromTop = WorkspaceInsets.headerTop + WorkspaceInsets.toolBand / 2
    let fromTop = centerFromTop - size.height / 2
    let y = bar.isFlipped ? fromTop : bar.bounds.height - fromTop - size.height
    let iconCenter = WorkspaceRailMetrics.railLeading + WorkspaceRailMetrics.leadingInset + 8
    let currentMinX = close.convert(close.bounds, to: nil).minX
    let x = close.frame.origin.x + (iconCenter - size.width / 2 - currentMinX)
    let origin = NSPoint(x: x, y: y)
    if close.frame.origin != origin {
      close.setFrameOrigin(origin)
    }
  }

  // Allow text inputs inside the panel to receive focus only after an explicit
  // editor click. Show, browsing, and row selection must not take the insertion point.
  override var canBecomeKey: Bool { acceptsKeyForEditing }

  /// Recording asked for a local responder. Does not activate the app or order the panel.
  func requestLocalRecordingKey() {
    acceptsKeyForEditing = true
  }

  /// The opening click returns before the field exists, so a later focus
  /// request would still see canBecomeKey false. Allow key without activating
  /// or ordering the panel.
  func noteInlineEditorNeedsKey() {
    acceptsKeyForEditing = true
  }

  func releaseInlineEditorKey() {
    if let view = firstResponder as? NSView, view.accessibilityIdentifier() == "lab-tag-field" {
      _ = makeFirstResponder(nil)
    }
    if let view = firstResponder as? NSView,
       Self.hitRequestsKey(view),
       view.accessibilityIdentifier() != "lab-tag-field" {
      return
    }
    acceptsKeyForEditing = false
  }

  func releaseLocalRecordingKey() {
    acceptsKeyForEditing = false
  }

  override func makeKey() {
    guard acceptsKeyForEditing else { return }
    super.makeKey()
  }

  private func installBrowsingInputMonitors() {
    guard outsideMonitor == nil, !LabRuntime.isUnitTestProcess else { return }
    let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .keyDown]
    // Global monitors cannot swallow keys. A session tap may swallow Esc only
    // while this panel is visible, and only if trust is already present.
    outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
      self?.handleBrowsingInput(event)
    }
    attachLocalBrowsingMonitor()
    installEscapeTapIfEligible()
  }

  /// The production local-monitor closure. A missing panel returns the event.
  /// A live panel returns nil when the route consumes; that nil must not be
  /// turned back into the event.
  static func routeLocalBrowsingEvent(_ event: NSEvent, panel: FloatingPanel?) -> NSEvent? {
    guard let panel else { return event }
    return panel.localBrowsingEvent(event)
  }

  func attachLocalBrowsingMonitor() {
    guard localInputMonitor == nil else { return }
    let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .keyDown]
    localInputMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      FloatingPanel.routeLocalBrowsingEvent(event, panel: self)
    }
  }

  private func installEscapeTapIfEligible() {
    guard escapeTap == nil else { return }
    switch PanelEscapeTap.gate(
      visible: isPresented && isVisible,
      trusted: Accessibility.isTrusted,
      unitTest: LabRuntime.isUnitTestProcess,
      alreadyInstalled: false
    ) {
    case .skipped:
      return
    case .blockedUntrusted:
      escapeTapBlockedUntrusted = true
      return
    case .install:
      let tap = BrowsingEscapeTap()
      tap.owner = self
      if tap.install() {
        escapeTap = tap
        escapeTapBlockedUntrusted = false
        escapeTapCreateFailed = false
      } else {
        escapeTapCreateFailed = true
        escapeTapBlockedUntrusted = true
      }
    }
  }

  func consumeBrowsingEscapeFromTap(keyCode: Int64) -> Bool {
    guard isPresented, isVisible, !isKeyWindow else { return false }
    let delivery = browsingEscapeDelivery(keyCode: UInt16(clamping: keyCode))
    guard PanelEscapeTap.shouldSwallow(keyCode: keyCode, panelIsKey: isKeyWindow, delivery: delivery) else {
      return false
    }
    // Invalidate the port only after this callback returns.
    if delivery == .consumeHide {
      DispatchQueue.main.async { [weak self] in
        guard let self, self.isPresented else { return }
        self.applyBrowsingDelivery(delivery)
      }
    } else {
      applyBrowsingDelivery(delivery)
    }
    return true
  }

  private func removeBrowsingInputMonitors() {
    if let outsideMonitor {
      NSEvent.removeMonitor(outsideMonitor)
    }
    if let localInputMonitor {
      NSEvent.removeMonitor(localInputMonitor)
    }
    outsideMonitor = nil
    localInputMonitor = nil
    escapeTap?.remove()
    escapeTap = nil
    lastBrowsingInput = nil
    lastBrowsingConsumed = false
    escapeCancelArmed = false
    escapeTapBlockedUntrusted = false
    escapeTapCreateFailed = false
  }

  func localBrowsingEvent(_ event: NSEvent) -> NSEvent? {
    guard isPresented else { return event }
    let token = browsingInputToken(event)
    if lastBrowsingInput == token {
      return lastBrowsingConsumed ? nil : event
    }
    lastBrowsingInput = token
    if event.type == .keyDown {
      let delivery = applyBrowsingKey(event)
      lastBrowsingConsumed = PanelBrowsingKeys.consumes(delivery)
      return lastBrowsingConsumed ? nil : event
    }
    lastBrowsingConsumed = false
    handleBrowsingClick(event)
    return event
  }

  private func handleBrowsingInput(_ event: NSEvent) {
    guard isPresented else { return }
    let token = browsingInputToken(event)
    if lastBrowsingInput == token { return }
    lastBrowsingInput = token
    if event.type == .keyDown {
      _ = applyBrowsingKey(event)
    } else {
      handleBrowsingClick(event)
    }
  }

  @discardableResult
  private func applyBrowsingKey(_ event: NSEvent) -> PanelBrowsingKeys.Delivery {
    let delivery = browsingEscapeDelivery(keyCode: event.keyCode)
    applyBrowsingDelivery(delivery)
    return delivery
  }

  private func browsingEscapeDelivery(keyCode: UInt16) -> PanelBrowsingKeys.Delivery {
    let responder = firstResponder
    let marked = (responder as? NSTextInputClient)?.hasMarkedText() == true
    let editorOwns = PanelKeyPolicy.defersToLocalEditor(responder)
    let context = AppState.shared.focusContext
    let session = editorOwns
      || AppState.shared.tagEditorItem != nil
      || AppState.shared.pinRecordingItemID != nil
      || AppState.shared.previewShortcutItemID != nil
    if keyCode != 53 {
      escapeCancelArmed = false
    }
    return PanelBrowsingKeys.delivery(
      isEscape: keyCode == 53,
      confirmationPresented: context.confirmationPresented || NSApp.alertWindow != nil,
      menuPresented: context.menuPresented,
      editorOwnsEscape: editorOwns,
      markedText: marked,
      sessionActive: session && !editorOwns && !marked,
      cancelArmed: escapeCancelArmed
    )
  }

  private func applyBrowsingDelivery(_ delivery: PanelBrowsingKeys.Delivery) {
    switch delivery {
    case .pass:
      break
    case .passToEditor:
      PanelEscapeHandoff.beginEditorEscape()
      DispatchQueue.main.async { PanelEscapeHandoff.endEditorEscape() }
    case .consumeCancel:
      escapeCancelArmed = true
      AppState.shared.cancelForegroundInputSession()
    case .consumeHide:
      escapeCancelArmed = false
      close()
    }
  }

  private func browsingInputToken(_ event: NSEvent) -> String {
    switch event.type {
    case .keyDown, .keyUp:
      return "\(event.type.rawValue)-\(event.keyCode)-\(event.timestamp)"
    default:
      return "\(event.type.rawValue)-\(event.timestamp)"
    }
  }

  private func handleBrowsingClick(_ event: NSEvent) {
    let context = AppState.shared.focusContext
    let dismiss = PanelOutsideClick.shouldDismiss(
      presented: isPresented,
      // A press delivered to one of our own windows is ours even when it lands
      // outside the frame: the resize band reaches a few points past the edge,
      // and treating that as an outside click closed the panel mid-resize.
      insideOwnedWindow: event.window != nil || ownsScreenPoint(screenPoint(of: event)),
      windowPinned: context.windowPinned,
      tagPopover: context.tagPopoverPresented,
      confirmation: context.confirmationPresented || NSApp.alertWindow != nil,
      menu: context.menuPresented
    )
    if dismiss {
      close()
    }
  }

  private func screenPoint(of event: NSEvent) -> NSPoint {
    if let window = event.window {
      return window.convertPoint(toScreen: event.locationInWindow)
    }
    return NSEvent.mouseLocation
  }

  private func ownsScreenPoint(_ point: NSPoint) -> Bool {
    if frame.contains(point) { return true }
    if let button = statusBarButton, let rect = screenFrame(of: button),
       rect.insetBy(dx: -4, dy: -4).contains(point) {
      return true
    }
    for window in NSApp.windows where window.isVisible && window !== self {
      if window.frame.contains(point) { return true }
    }
    return false
  }

  private func screenFrame(of view: NSView) -> NSRect? {
    guard let window = view.window else { return nil }
    return window.convertToScreen(view.convert(view.bounds, to: nil))
  }
}

/// Popup movement is the title bar only. `isMovable` stays on the position
/// policy; background drags are locked off and hover/drag-end cannot reopen them.
enum PanelWindowDrag {
  static let backgroundMovesWindow = false

  static func lock(_ window: NSWindow?) {
    window?.isMovableByWindowBackground = backgroundMovesWindow
  }

  /// Title-bar movement remains available when the window itself is movable.
  static func titleBarCanMove(_ window: NSWindow) -> Bool {
    window.isMovable && window.isMovableByWindowBackground == backgroundMovesWindow
  }
}

/// Empty title-bar space. Controls in front keep their own clicks.
struct TitleBarDragStrip: NSViewRepresentable {
  func makeNSView(context: Context) -> TitleBarDragStripView {
    let view = TitleBarDragStripView()
    view.setAccessibilityIdentifier("lab-titlebar-drag")
    return view
  }

  func updateNSView(_ nsView: TitleBarDragStripView, context: Context) {}
}

final class TitleBarDragStripView: NSView {
  override var mouseDownCanMoveWindow: Bool { true }

  override func mouseDown(with event: NSEvent) {
    guard let window, PanelWindowDrag.titleBarCanMove(window) else { return }
    window.performDrag(with: event)
  }
}
