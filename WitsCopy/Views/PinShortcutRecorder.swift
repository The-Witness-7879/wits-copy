import AppKit
import SwiftUI

/// Local Command+letter capture. Not a global monitor and not an AX string setter.
enum PinShortcutCapture {
  static let retryPrompt = NSLocalizedString(
    "pin_shortcut_retry",
    value: "Press\n⌘+letter",
    comment: "Pin shortcut recording prompt"
  )
  static let illegalPrompt = NSLocalizedString(
    "pin_shortcut_illegal",
    value: "Only\n⌘+letter",
    comment: "Pin shortcut recording rejected a key"
  )
  static let conflictPrompt = NSLocalizedString(
    "pin_shortcut_conflict",
    value: "In use\nSet again",
    comment: "Pin shortcut letter belongs to another pin"
  )
  static let reservedPrompt = NSLocalizedString(
    "pin_shortcut_reserved",
    value: "That letter is reserved",
    comment: "Pin shortcut letter is reserved by the app"
  )

  enum Decision: Equatable {
    case ignored
    case cancel
    case rejected(String)
    case commit(String)
  }

  static func interpret(_ event: NSEvent) -> Decision {
    guard event.type == .keyDown else { return .ignored }
    if event.keyCode == 53 { return .cancel }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let raw = event.charactersIgnoringModifiers ?? ""
    if raw.isEmpty || raw.unicodeScalars.contains(where: { (0xF700...0xF8FF).contains($0.value) }) {
      if flags.subtracting(.command).isEmpty && raw.isEmpty { return .ignored }
      return .rejected(illegalPrompt)
    }
    guard flags == .command else { return .rejected(illegalPrompt) }
    let letter = raw.lowercased()
    guard letter.count == 1, let scalar = letter.unicodeScalars.first, (97...122).contains(scalar.value) else {
      return .rejected(illegalPrompt)
    }
    return .commit(letter)
  }
}

enum PinShortcutCommit: Equatable {
  case saved
  case rejected(String)
  case conflict
  case reserved
  case failed(String)
  case stale
}

/// Session-scoped key route. Installed only while a recorder owns a session,
/// removed when that session ends. Does not activate the app or become a
/// standing control channel. Command letters reach the recorder even when the
/// panel cannot become key, so the root menu does not treat ⌘Q as Quit.
@MainActor
enum PinRecordingKeyRoute {
  private static var monitor: Any?
  private(set) static weak var owner: PinnedShortcutRecorder?

  static var isInstalled: Bool { monitor != nil }

  static func begin(_ recorder: PinnedShortcutRecorder) {
    guard recorder.holdsLocalRecordingKey else { return }
    owner = recorder
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      MainActor.assumeIsolated {
        guard let owner else { return event }
        guard owner.maySwallowRoutedKeys else {
          if owner.ownsSession || owner.recording {
            let id = owner.itemID
            owner.stopForSessionEnd()
            AppState.shared.cancelPinRecording(itemID: id)
          }
          return event
        }
        return owner.consumeRouted(event) ? nil : event
      }
    }
  }

  /// Ends the current owner when `itemID` is nil, or only that item's owner.
  /// A late call for a previous item does not remove a newer session.
  static func endMatching(itemID: UUID?) {
    guard let owner else {
      if monitor != nil { end(nil) }
      return
    }
    if let itemID, owner.itemID != itemID { return }
    owner.stopForSessionEnd()
  }

  static func end(_ recorder: PinnedShortcutRecorder?) {
    if let recorder, owner !== recorder { return }
    owner = nil
    if let monitor {
      NSEvent.removeMonitor(monitor)
    }
    monitor = nil
  }
}

/// Fixed 56pt slot child. Double-click starts recording; keys are accepted only while this view owns the session.
@MainActor
final class PinnedShortcutRecorder: NSView {
  var itemID = UUID()
  var pinned = false
  var onBegin: ((UUID) -> Void)?
  var onCancel: ((UUID) -> Void)?
  var onCommit: ((UUID, String) -> PinShortcutCommit)?
  var onPrompt: ((UUID, String) -> Void)?
  var onSelect: ((UUID) -> Void)?
  var sessionActive: ((UUID) -> Bool)?

  private(set) var recording = false
  private(set) var ownsSession = false
  private(set) var holdsLocalRecordingKey = false
  private var endingSession = false
  private let recordingMark = ShortcutStatusMark()
  private let errorMark = ShortcutStatusMark()
  private let promptField = ShortcutPromptField(labelWithString: "")

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { recording }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard pinned, bounds.contains(point) else { return nil }
    return self
  }

  func applySlotHelp(_ text: String) {
    let next = text.isEmpty ? nil : text
    if toolTip != next { toolTip = next }
    setAccessibilityHelp(next)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if recordingMark.superview == nil {
      addSubview(recordingMark)
      addSubview(errorMark)
      addSubview(promptField)
    }
    if window == nil, recording {
      finishRecording(notify: true)
    } else if recording, ownsSession {
      attachKeyRoute()
    }
  }

  override func resignFirstResponder() -> Bool {
    let owned = ownsSession
    let id = itemID
    let accepted = super.resignFirstResponder()
    guard accepted, owned else { return accepted }
    ownsSession = false
    recording = false
    PinRecordingKeyRoute.end(self)
    onCancel?(id)
    showPrompt(nil)
    applyMarks(message: nil, error: nil)
    needsDisplay = true
    (window as? LocalRecordingKeyWindow)?.releaseLocalRecordingKey()
    return accepted
  }

  func configure(itemID: UUID, pinned: Bool, recording: Bool, message: String?, error: String?) {
    if self.itemID != itemID || self.pinned != pinned {
      if self.recording { finishRecording(notify: true) }
    }
    self.itemID = itemID
    self.pinned = pinned
    setAccessibilityEnabled(pinned)
    if !pinned, self.recording { finishRecording(notify: true) }
    if recording, pinned, !self.recording {
      self.recording = true
    }
    if !recording, self.recording, sessionActive?(itemID) != true {
      self.recording = false
      if ownsSession {
        ownsSession = false
        PinRecordingKeyRoute.end(self)
      }
    }
    applyMarks(message: message, error: error)
    applySlotHelp(message ?? error ?? HistoryShortcutSlotCopy.text(pinned: pinned))
    let visible = message ?? error
    if visible == nil, recording, promptField.stringValue.isEmpty == false {
      promptField.isHidden = false
    } else {
      showPrompt(visible)
    }
    needsDisplay = true
  }

  override func mouseDown(with event: NSEvent) {
    let decision = ShortcutSlotPointer.result(pinned: pinned, clickCount: event.clickCount)
    onSelect?(itemID)
    if case .selectAndRecord = decision {
      beginRecording()
    }
  }

  override func accessibilityPerformPress() -> Bool {
    guard pinned else { return false }
    beginRecording()
    return true
  }

  override func keyDown(with event: NSEvent) {
    guard consume(event) else {
      super.keyDown(with: event)
      return
    }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    consume(event)
  }

  override func draw(_ dirtyRect: NSRect) {
    guard recording else { return }
    NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
    path.lineWidth = 1
    path.stroke()
  }

  override func layout() {
    super.layout()
    recordingMark.frame = bounds
    errorMark.frame = bounds
    promptField.frame = bounds.insetBy(dx: 2, dy: 4)
  }

  func stopForSessionEnd(resignResponder: Bool = true) {
    finishRecording(notify: false, resignResponder: resignResponder)
  }

  var maySwallowRoutedKeys: Bool {
    guard ownsSession, recording, holdsLocalRecordingKey, window != nil else { return false }
    if sessionActive?(itemID) == false { return false }
    if let responder = window?.firstResponder, PinRecordingFocus.isCompetingTextEntry(responder) {
      return false
    }
    return true
  }

  private func beginRecording() {
    guard pinned else { return }
    recording = true
    ownsSession = true
    onBegin?(itemID)
    holdsLocalRecordingKey = window is LocalRecordingKeyWindow
    attachKeyRoute()
    onPrompt?(itemID, PinShortcutCapture.retryPrompt)
    showPrompt(PinShortcutCapture.retryPrompt)
    applyMarks(message: PinShortcutCapture.retryPrompt, error: nil)
    needsDisplay = true
  }

  private func attachKeyRoute() {
    guard recording, ownsSession, let window else { return }
    if window is LocalRecordingKeyWindow {
      holdsLocalRecordingKey = true
      (window as? LocalRecordingKeyWindow)?.requestLocalRecordingKey()
      PinRecordingKeyRoute.begin(self)
    }
    if window.firstResponder !== self {
      _ = window.makeFirstResponder(self)
    }
  }

  private func finishRecording(notify: Bool, keepPrompt: String? = nil, resignResponder: Bool = true) {
    guard !endingSession else { return }
    endingSession = true
    defer { endingSession = false }
    let id = itemID
    let wasRecording = recording
    let owned = ownsSession
    recording = false
    ownsSession = false
    holdsLocalRecordingKey = false
    if owned { PinRecordingKeyRoute.end(self) }
    if notify, wasRecording { onCancel?(id) }
    if let keepPrompt {
      showPrompt(keepPrompt)
      applyMarks(message: keepPrompt, error: keepPrompt)
    } else {
      showPrompt(nil)
      applyMarks(message: nil, error: nil)
    }
    needsDisplay = true
    if resignResponder, window?.firstResponder === self {
      window?.makeFirstResponder(nil)
    }
    (window as? LocalRecordingKeyWindow)?.releaseLocalRecordingKey()
  }

  @discardableResult
  func consumeRouted(_ event: NSEvent) -> Bool {
    guard ownsSession, recording else { return false }
    return consumeBody(event)
  }

  @discardableResult
  private func consume(_ event: NSEvent) -> Bool {
    guard recording, ownsSession || window?.firstResponder === self else { return false }
    return consumeBody(event)
  }

  @discardableResult
  private func consumeBody(_ event: NSEvent) -> Bool {
    guard sessionActive?(itemID) != false else {
      finishRecording(notify: true)
      return false
    }
    switch PinShortcutCapture.interpret(event) {
    case .ignored:
      return true
    case .cancel:
      finishRecording(notify: true)
      return true
    case .rejected(let message):
      onPrompt?(itemID, message)
      showPrompt(message)
      applyMarks(message: message, error: message)
      return true
    case .commit(let letter):
      switch onCommit?(itemID, letter) {
      case .saved, .none:
        finishRecording(notify: false)
      case .rejected(let message):
        onPrompt?(itemID, message)
        showPrompt(message)
        applyMarks(message: message, error: message)
      case .conflict:
        onPrompt?(itemID, PinShortcutCapture.conflictPrompt)
        showPrompt(PinShortcutCapture.conflictPrompt)
        applyMarks(message: PinShortcutCapture.conflictPrompt, error: PinShortcutCapture.conflictPrompt)
      case .reserved:
        onPrompt?(itemID, PinShortcutCapture.reservedPrompt)
        showPrompt(PinShortcutCapture.reservedPrompt)
        applyMarks(message: PinShortcutCapture.reservedPrompt, error: PinShortcutCapture.reservedPrompt)
      case .failed(let message):
        onPrompt?(itemID, message)
        finishRecording(notify: false, keepPrompt: message)
      case .stale:
        finishRecording(notify: false)
      }
      needsDisplay = true
      return true
    }
  }

  private func showPrompt(_ value: String?) {
    let text = value ?? ""
    promptField.stringValue = text
    promptField.setAccessibilityValue(text)
    promptField.isHidden = text.isEmpty
    promptField.needsDisplay = true
  }

  private func applyMarks(message: String?, error: String?) {
    recordingMark.apply(
      identifier: recording ? "lab-shortcut-recording" : nil,
      value: message
    )
    errorMark.apply(identifier: error == nil ? nil : "lab-shortcut-error", value: error)
  }
}

enum HistoryShortcutSlotCopy {
  static let pinnedKey = "row_shortcut_help"
  static let unpinnedKey = "row_shortcut_help_disabled"

  static func text(pinned: Bool) -> String {
    NSLocalizedString(
      pinned ? pinnedKey : unpinnedKey,
      value: pinned
        ? "Double-click to record a pin shortcut"
        : "Pin this item before recording a shortcut",
      comment: "History row shortcut slot hover"
    )
  }
}

final class HistoryShortcutSlotView: NSView {
  var recorder: PinnedShortcutRecorder?

  override var isFlipped: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  func applySlotHelp(_ text: String) {
    let next = text.isEmpty ? nil : text
    if toolTip != next { toolTip = next }
    setAccessibilityHelp(next)
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    guard bounds.contains(local) else { return nil }
    guard let recorder else { return self }
    let hit = recorder.hitTest(recorder.convert(local, from: self))
    return hit ?? self
  }

  override func mouseDown(with event: NSEvent) {
    recorder?.mouseDown(with: event)
  }

  override func layout() {
    super.layout()
    recorder?.frame = bounds
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: HistoryRowMetrics.shortcutWidth, height: NSView.noIntrinsicMetric)
  }
}

private final class ShortcutPromptField: NSTextField {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configure()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configure()
  }

  private func configure() {
    isEditable = false
    isSelectable = false
    isBezeled = false
    drawsBackground = false
    alignment = .center
    font = .systemFont(ofSize: 9, weight: .semibold)
    textColor = .labelColor
    maximumNumberOfLines = 2
    lineBreakMode = .byWordWrapping
    cell?.wraps = true
    cell?.isScrollable = false
    setAccessibilityElement(true)
    setAccessibilityIdentifier("lab-shortcut-prompt")
  }
}

private final class ShortcutStatusMark: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func apply(identifier: String?, value: String?) {
    let active = identifier != nil
    setAccessibilityElement(active)
    setAccessibilityIdentifier(identifier)
    setAccessibilityValue(value)
    setAccessibilityLabel(value)
    toolTip = value
  }
}

struct HistoryShortcutSlot: NSViewRepresentable {
  var containerID: String
  var controlID: String
  var itemID: UUID
  var pinned: Bool
  var recording: Bool
  var message: String?
  var error: String?

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> HistoryShortcutSlotView {
    let slot = HistoryShortcutSlotView()
    slot.setAccessibilityElement(true)
    slot.setAccessibilityIdentifier(containerID)
    let recorder = PinnedShortcutRecorder()
    recorder.setAccessibilityElement(true)
    recorder.setAccessibilityIdentifier(controlID)
    recorder.setAccessibilityLabel(NSLocalizedString("pin_shortcut", value: "Pin shortcut", comment: ""))
    recorder.onBegin = { context.coordinator.begin($0) }
    recorder.onCancel = { context.coordinator.cancel($0) }
    recorder.onCommit = { context.coordinator.commit($0, $1) }
    recorder.onPrompt = { context.coordinator.prompt($0, $1) }
    recorder.onSelect = { context.coordinator.select($0) }
    recorder.sessionActive = { context.coordinator.isActive($0) }
    slot.recorder = recorder
    slot.addSubview(recorder)
    return slot
  }

  func updateNSView(_ slot: HistoryShortcutSlotView, context: Context) {
    let help = message ?? error ?? HistoryShortcutSlotCopy.text(pinned: pinned)
    slot.applySlotHelp(help)
    slot.setAccessibilityIdentifier(containerID)
    slot.recorder?.applySlotHelp(help)
    slot.recorder?.setAccessibilityIdentifier(controlID)
    slot.recorder?.configure(
      itemID: itemID,
      pinned: pinned,
      recording: recording,
      message: message,
      error: error
    )
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: HistoryShortcutSlotView, context: Context) -> CGSize? {
    CGSize(width: HistoryRowMetrics.shortcutWidth, height: proposal.height ?? HistoryRowMetrics.contentHeight)
  }

  @MainActor
  final class Coordinator {
    func begin(_ itemID: UUID) {
      AppState.shared.beginPinRecording(itemID: itemID)
    }

    func cancel(_ itemID: UUID) {
      AppState.shared.cancelPinRecording(itemID: itemID)
    }

    func commit(_ itemID: UUID, _ letter: String) -> PinShortcutCommit {
      AppState.shared.commitPinLetter(letter, itemID: itemID)
    }

    func select(_ itemID: UUID) {
      guard let item = AppState.shared.history.all.first(where: { $0.id == itemID }) else { return }
      // clickCount 1 never commits, even when the row is already selected.
      AppState.shared.handleRowClick(item, clickCount: 1, flags: .currentModifierFlags)
    }

    func prompt(_ itemID: UUID, _ message: String) {
      AppState.shared.notePinRecordingPrompt(message, itemID: itemID)
    }

    func isActive(_ itemID: UUID) -> Bool {
      AppState.shared.pinRecordingItemID == itemID
    }
  }
}

enum PinRecordingFocus {
  @MainActor
  static func isCompetingTextEntry(_ responder: NSResponder?) -> Bool {
    guard let responder, !(responder is PinnedShortcutRecorder) else { return false }
    if responder is OriginalTextBodyView || responder is RichTextBodyView { return true }
    if PanelKeyPolicy.isSearchFieldEditor(responder) { return true }
    var view = responder as? NSView
    while let current = view {
      if current.accessibilityIdentifier() == "lab-search-field" { return true }
      if let field = current as? NSTextField, field.isEditable,
         field.accessibilityIdentifier() == "lab-search-field" {
        return true
      }
      view = current.superview
    }
    return false
  }
}
