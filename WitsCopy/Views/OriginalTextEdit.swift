import AppKit
import SwiftUI

enum PreviewEditCommand: Equatable {
  case submit
  case newline
  case cancel
  case ignore
}

enum PreviewEditKeys {
  /// Bare Return submits and exits. Shift+Return inserts a newline. Esc cancels
  /// this edit only; the same event is not forwarded, so the next Esc can hide.
  /// Marked text is an IME candidate: Return/Esc must not save or cancel the edit.
  static func command(keyCode: UInt16, flags: NSEvent.ModifierFlags, markedText: Bool) -> PreviewEditCommand {
    if markedText { return .ignore }
    let mods = flags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
    if keyCode == 53 {
      return mods.isEmpty ? .cancel : .ignore
    }
    if keyCode == 36 || keyCode == 76 {
      if mods == .shift { return .newline }
      if mods.isEmpty { return .submit }
      return .ignore
    }
    return .ignore
  }
}

final class PreviewEditExit {
  var value = true
}

enum OriginalTextRefusal: Equatable {
  case fileBacked
  case image
  case richText
  case media
  case undecodable
  case oversized
  case notText
  case removed

  var explanation: String {
    switch self {
    case .fileBacked:
      return NSLocalizedString("edit_refused_file", value: "File items stay read-only and are not written back.", comment: "")
    case .image:
      return NSLocalizedString("edit_refused_image", value: "Images stay read-only.", comment: "")
    case .richText:
      return NSLocalizedString("edit_refused_rich", value: "Rich text stays read-only.", comment: "")
    case .media:
      return NSLocalizedString("edit_refused_media", value: "This item stays read-only.", comment: "")
    case .undecodable:
      return NSLocalizedString("edit_refused_decode", value: "The original could not be decoded without loss.", comment: "")
    case .oversized:
      return NSLocalizedString("edit_refused_large", value: "This item is too large to edit without replacing it with a fragment.", comment: "")
    case .notText:
      return NSLocalizedString("edit_refused_not_text", value: "Only plain text, Markdown, and code can be edited.", comment: "")
    case .removed:
      return NSLocalizedString("edit_refused_removed", value: "This item is no longer available.", comment: "")
    }
  }
}

struct OriginalTextDraft: Equatable {
  var title: String
  var body: String
}

enum OriginalTextSaveOutcome: Equatable {
  case saved
  case rejected(String)
  case failed(String)
  case stale
}

enum OriginalTextEdit {
  static var maxEditableCharacters: Int { PreviewLimits.maxDisplayCharacters }

  static func refusal(for item: HistoryItem) -> OriginalTextRefusal? {
    if item.hasImagePayload { return .image }
    if !item.fileURLs.isEmpty { return .fileBacked }
    if item.rtfData != nil || item.htmlData != nil { return .richText }
    if item.contents.contains(where: { blocked($0.type) }) { return .media }
    if item.contentKind != .text { return .notText }
    for content in item.contents where OriginalTextPayload.kind(content.type) != .leave {
      if (content.value?.count ?? 0) > maxEditableCharacters { return .oversized }
    }
    guard let data = stringBytes(in: item) else { return .notText }
    guard data.count <= maxEditableCharacters else { return .oversized }
    guard let text = String(data: data, encoding: .utf8), Data(text.utf8) == data else { return .undecodable }
    if text.count > maxEditableCharacters || data.count > maxEditableCharacters { return .oversized }
    return nil
  }

  static func draft(from item: HistoryItem) -> OriginalTextDraft? {
    guard refusal(for: item) == nil, let text = item.text else { return nil }
    return OriginalTextDraft(title: item.title, body: text)
  }

  static func stringBytes(in item: HistoryItem) -> Data? {
    item.contents.first(where: { $0.type == NSPasteboard.PasteboardType.string.rawValue })?.value
  }

  private static func blocked(_ type: String) -> Bool {
    if OriginalTextPayload.kind(type) != .leave { return false }
    let lower = type.lowercased()
    return lower.contains("gif")
      || lower.contains("pdf")
      || lower.contains("movie")
      || lower.contains("video")
      || lower.contains("png")
      || lower.contains("jpeg")
      || lower.contains("tiff")
      || lower.contains("heic")
      || lower.contains("rtf")
      || lower.contains("html")
      || lower.contains("file-url")
      || lower.contains("fileurl")
  }
}

enum OriginalTextPayload {
  enum Kind {
    case leave
    case utf8
    case utf16
  }

  static func kind(_ type: String) -> Kind {
    if type == NSPasteboard.PasteboardType.string.rawValue { return .utf8 }
    let lower = type.lowercased()
    if lower.contains("utf-16") || lower.contains("utf16") { return .utf16 }
    if lower == "public.plain-text" || lower == "nsstringpboardtype" { return .utf8 }
    if lower.contains("utf-8") || lower.contains("utf8") || lower.contains("plain-text") { return .utf8 }
    return .leave
  }

  @discardableResult
  static func sync(_ item: HistoryItem, body: String) -> [HistoryItemContent] {
    let utf8 = Data(body.utf8)
    let utf16 = body.data(using: .utf16) ?? utf8
    for content in item.contents {
      switch kind(content.type) {
      case .utf8:
        content.value = utf8
      case .utf16:
        content.value = utf16
      case .leave:
        break
      }
    }
    return []
  }

  @MainActor
  @discardableResult
  static func stripRich(_ item: HistoryItem) -> [HistoryItemContent] {
    let removed = item.contents.filter { RichRepresentation.isRich($0.type) }
    guard !removed.isEmpty else { return [] }
    item.contents.removeAll { RichRepresentation.isRich($0.type) }
    for content in removed {
      content.item = nil
      Storage.shared.context.delete(content)
    }
    return removed
  }

  static func restore(
    _ item: HistoryItem,
    bytes: [(HistoryItemContent, Data?)],
    removed: [HistoryItemContent]
  ) {
    for (content, value) in bytes {
      content.value = value
    }
    for content in removed where !item.contents.contains(where: { $0 === content }) {
      item.contents.append(content)
    }
  }
}

@MainActor
final class OriginalTextBodyView: NSTextView {
  override func didChangeText() {
    super.didChangeText()
    guard isEditable else { return }
    onText?(string)
  }

  override func insertText(_ insertString: Any, replacementRange: NSRange) {
    super.insertText(insertString, replacementRange: replacementRange)
    guard isEditable else { return }
    onText?(string)
  }

  var onText: ((String) -> Void)?
  var onBegin: (() -> Void)?
  var onSave: (() -> Bool)?
  var onCancel: (() -> Void)?
  var acceptsKeys: (() -> Bool)?
  var allowsEdit = true

  override var acceptsFirstResponder: Bool { isEditable }

  override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
    super.init(frame: frameRect, textContainer: container)
    usesAdaptiveColorMappingForDarkAppearance = true
    textColor = .labelColor
  }

  /// `NSTextView.init(usingTextLayoutManager:)` is an uninherited convenience.
  /// `false` must be TextKit 1: the frame initializer on this SDK is TextKit 2.
  convenience init(usingTextLayoutManager useTextKit2: Bool) {
    precondition(!useTextKit2, "call sites request TextKit 1")
    let storage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    storage.addLayoutManager(layoutManager)
    let container = NSTextContainer(size: NSSize(width: 0, height: 10_000_000))
    container.widthTracksTextView = true
    container.heightTracksTextView = false
    layoutManager.addTextContainer(container)
    self.init(frame: .zero, textContainer: container)
    minSize = .zero
    maxSize = NSSize(width: 0, height: 10_000_000)
    isVerticallyResizable = true
    isHorizontallyResizable = false
  }

  override convenience init(frame frameRect: NSRect) {
    self.init(usingTextLayoutManager: false)
    frame = frameRect
    if let container = textContainer {
      container.containerSize = NSSize(width: frameRect.width, height: container.containerSize.height)
    }
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    usesAdaptiveColorMappingForDarkAppearance = true
    textColor = .labelColor
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func becomeFirstResponder() -> Bool {
    AppState.shared.noteTextEntryFocused(in: window)
    return super.becomeFirstResponder()
  }

  override func mouseDown(with event: NSEvent) {
    if !isEditable, allowsEdit {
      isEditable = true
      onBegin?()
      window?.makeFirstResponder(self)
      // NSTextView.mouseDown tracks until mouseUp. The click that enters edit
      // must return; otherwise a lost mouseUp blocks Esc and every later click.
      return
    }
    guard window?.isVisible == true else { return }
    super.mouseDown(with: event)
  }

  override func keyDown(with event: NSEvent) {
    guard acceptsKeys?() != false, isEditable, window?.firstResponder === self else {
      super.keyDown(with: event)
      return
    }
    let marked = hasMarkedText()
    if marked, event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 53 {
      // Same contract as the rich body: give the input method the key, and do
      // not fall through to super.keyDown. insertNewline refuses a still-marked
      // range so a true handleEvent cannot replace the candidate with a newline.
      _ = inputContext?.handleEvent(event)
      return
    }
    switch PreviewEditKeys.command(keyCode: event.keyCode, flags: event.modifierFlags, markedText: marked) {
    case .submit:
      if onSave?() != false {
        endEditSession()
      }
    case .newline:
      super.insertNewline(nil)
    case .cancel:
      onCancel?()
      endEditSession()
    case .ignore:
      super.keyDown(with: event)
    }
  }

  override func insertNewline(_ sender: Any?) {
    if hasMarkedText() {
      return
    }
    if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
      super.insertNewline(sender)
      return
    }
    if onSave?() != false {
      endEditSession()
    }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard acceptsKeys?() != false, isEditable, window?.firstResponder === self else { return false }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags == .command, event.keyCode == 36 || event.keyCode == 76 {
      if onSave?() != false {
        endEditSession()
      }
      return true
    }
    return false
  }

  private func endEditSession() {
    isEditable = false
    window?.makeFirstResponder(nil)
  }
}

struct PreviewInlineField: NSViewRepresentable {
  var text: String
  var font: NSFont
  var identifier: String
  var editing: Bool
  var token: Int
  var scrolling: Bool
  var wraps = true
  var allowsEdit: Bool = true
  var onBegin: () -> Void
  var onText: (String) -> Void
  var onSave: () -> Bool
  var onCancel: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSView {
    let textView = makeTextView()
    apply(textView, context: context, forceText: true)
    guard scrolling else {
      textView.setAccessibilityIdentifier(identifier)
      return textView
    }
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.documentView = textView
    scroll.hasHorizontalScroller = !wraps
    scroll.setAccessibilityIdentifier(identifier)
    return scroll
  }

  func updateNSView(_ view: NSView, context: Context) {
    let textView = (view as? NSScrollView)?.documentView as? OriginalTextBodyView ?? view as? OriginalTextBodyView
    guard let textView else { return }
    apply(textView, context: context, forceText: false)
    applyWrap(textView, scroll: view as? NSScrollView)
    if let scroll = view as? NSScrollView {
      // The visible body is the viewport. The document frame is the full text
      // and would otherwise be reported through the footer.
      scroll.setAccessibilityIdentifier(identifier)
    }
  }

  final class Coordinator {
    var token = -1
  }

  private func makeTextView() -> OriginalTextBodyView {
    let view = OriginalTextBodyView(usingTextLayoutManager: false)
    view.drawsBackground = false
    view.isRichText = false
    view.importsGraphics = false
    view.allowsUndo = true
    view.isHorizontallyResizable = !wraps
    view.isVerticallyResizable = true
    view.textContainer?.widthTracksTextView = wraps
    view.textContainer?.containerSize = NSSize(
      width: wraps ? 1 : CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    view.textContainerInset = .zero
    view.isAutomaticQuoteSubstitutionEnabled = false
    view.isAutomaticDashSubstitutionEnabled = false
    view.isAutomaticDataDetectionEnabled = false
    view.isAutomaticLinkDetectionEnabled = false
    view.isAutomaticSpellingCorrectionEnabled = false
    view.isAutomaticTextReplacementEnabled = false
    view.minSize = .zero
    view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    view.textColor = .labelColor
    view.usesAdaptiveColorMappingForDarkAppearance = true
    view.acceptsKeys = { true }
    view.isEditable = false
    return view
  }

  private func apply(_ view: OriginalTextBodyView, context: Context, forceText: Bool) {
    view.allowsEdit = allowsEdit
    view.onBegin = onBegin
    view.onText = onText
    view.onSave = onSave
    view.onCancel = onCancel
    view.font = font
    view.isSelectable = true
    view.setAccessibilityIdentifier(scrolling ? "lab-preview-edit-body" : identifier)
    if !editing || !allowsEdit {
      view.isEditable = false
    }
    let external = forceText || context.coordinator.token != token
    context.coordinator.token = token
    guard external, view.window?.firstResponder !== view else { return }
    if view.string != text {
      view.string = text
    }
  }

  private func applyWrap(_ view: OriginalTextBodyView, scroll: NSScrollView?) {
    view.textContainer?.widthTracksTextView = wraps
    view.isHorizontallyResizable = !wraps
    let viewport = scroll?.contentSize.width ?? 0
    let tracked = viewport > 1 ? viewport : max(view.bounds.width, 1)
    // Turning wrap on after an unwrapped layout: the view has already grown to
    // the longest line, and a width-tracking container would follow that
    // width and never fold. Shrink the view back to the viewport first.
    if wraps, view.frame.width > tracked + 0.5 {
      view.setFrameSize(NSSize(width: tracked, height: view.frame.height))
    }
    view.textContainer?.containerSize = NSSize(
      width: wraps ? tracked : CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    scroll?.hasHorizontalScroller = !wraps
  }
}

@Observable
final class TextEditBuffer {
  var title = ""
  var body = ""
  weak var saveButton: NSButton?
  weak var cancelButton: NSButton?
  weak var errorField: NSTextField?
  var baselineBody = ""
  var baselineTitle = ""
  var errorMessage = ""

  func noteBody(_ value: String) {
    body = value
    let dirty = value != baselineBody || title != baselineTitle
    saveButton?.isEnabled = dirty
    cancelButton?.isEnabled = dirty
  }

  func adoptBaseline() {
    baselineBody = body
    baselineTitle = title
    saveButton?.isEnabled = false
    cancelButton?.isEnabled = false
    errorField?.stringValue = ""
  }
}

struct OriginalTextEditSection: View {
  var item: HistoryItemDecorator
  var wraps = true
  @Environment(AppState.self) private var appState
  @State private var buffer = TextEditBuffer()
  @State private var title = ""
  @State private var bodyText = ""
  @State private var baseline = OriginalTextDraft(title: "", body: "")
  @State private var editToken = 0
  @State private var loadedID: UUID?
  @State private var editingBody = false
  @State private var errorText = ""

  private var dirty: Bool {
    buffer.title != baseline.title || buffer.body != baseline.body
  }

  var body: some View {
    if item.isRemoved {
      EmptyView()
    } else if OriginalTextEdit.refusal(for: item.item) == .richText {
      EmptyView()
    } else if let reason = OriginalTextEdit.refusal(for: item.item) {
      refusal(reason)
    } else {
      editor
    }
  }

  private var shownError: String {
    let model = appState.textEditError(for: item.id) ?? ""
    if !errorText.isEmpty { return errorText }
    if !buffer.errorMessage.isEmpty { return buffer.errorMessage }
    return model
  }

  private var editor: some View {
    VStack(alignment: .leading, spacing: 0) {
      PreviewInlineField(
        text: bodyText,
        font: .systemFont(ofSize: NSFont.systemFontSize),
        identifier: "lab-preview-body",
        editing: editingBody,
        token: editToken,
        scrolling: true,
        wraps: wraps,
        onBegin: { editingBody = true },
        onText: { value in
          bodyText = value
          buffer.noteBody(value)
          retainLive()
        },
        onSave: commit,
        onCancel: cancel
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      RefusalNote(text: shownError, identifier: "lab-preview-edit-error", buffer: buffer)
        .frame(height: shownError.isEmpty ? 0 : nil)
        .opacity(shownError.isEmpty ? 0 : 1)
        .accessibilityHidden(shownError.isEmpty)
    }
    .onAppear(perform: load)
    .onChange(of: item.id) { _, _ in load() }
    .onChange(of: item.contentRevision) { _, _ in
      guard !dirty, !editingBody else { return }
      load()
    }
    .onDisappear {
      retainIfNeeded(item.id)
    }
  }

  private func refusal(_ reason: OriginalTextRefusal) -> some View {
    RefusalNote(text: reason.explanation)
  }

  private func load() {
    let id = item.id
    if loadedID != id {
      retainIfNeeded(loadedID)
      loadedID = id
      editToken += 1
      editingBody = false
    }
    guard !item.isRemoved, let stored = OriginalTextEdit.draft(from: item.item) else { return }
    let draft = appState.textDraft(for: id) ?? stored
    title = draft.title
    bodyText = draft.body
    buffer.title = draft.title
    buffer.body = draft.body
    buffer.baselineTitle = stored.title
    buffer.baselineBody = stored.body
    baseline = stored
    errorText = appState.textEditError(for: id) ?? ""
    if draft == stored { buffer.adoptBaseline() }
  }

  private func retainIfNeeded(_ id: UUID?) {
    guard let id else { return }
    guard appState.history.all.contains(where: { $0.id == id && !$0.isRemoved }) else { return }
    let draft = OriginalTextDraft(title: buffer.title, body: buffer.body)
    if draft != baseline {
      appState.retainTextDraft(draft, itemID: id)
    }
  }

  private func retainLive() {
    guard !item.isRemoved else { return }
    retainIfNeeded(item.id)
  }

  /// True exits the edit. Title-only does not rewrite pasteboard bytes.
  private func commit() -> Bool {
    let id = item.id
    let draft = OriginalTextDraft(title: buffer.title, body: buffer.body)
    if draft.body == baseline.body && draft.title == baseline.title {
      editingBody = false
      publishError("")
      return true
    }
    if draft.body == baseline.body {
      switch appState.saveTitlePreservingRich(itemID: id, title: draft.title) {
      case .saved:
        adoptSaved(id: id, draft: OriginalTextDraft(title: item.item.title, body: baseline.body))
        return true
      case .rejected, .failed, .stale:
        appState.retainTextDraft(draft, itemID: id)
        publishError(appState.textEditError(for: id) ?? "")
        return false
      }
    }
    switch appState.saveOriginalText(itemID: id, draft: draft, baseline: baseline) {
    case .saved:
      adoptSaved(id: id, draft: OriginalTextDraft(title: item.item.title, body: item.item.text ?? draft.body))
      return true
    case .rejected, .failed, .stale:
      appState.retainTextDraft(draft, itemID: id)
      publishError(appState.textEditError(for: id) ?? "")
      return false
    }
  }

  private func publishError(_ message: String) {
    errorText = message
    buffer.errorMessage = message
    buffer.errorField?.stringValue = message
    buffer.errorField?.isHidden = message.isEmpty
  }

  private func adoptSaved(id: UUID, draft: OriginalTextDraft) {
    baseline = draft
    title = draft.title
    bodyText = draft.body
    buffer.title = draft.title
    buffer.body = draft.body
    buffer.adoptBaseline()
    editingBody = false
    publishError("")
    editToken += 1
    appState.discardTextDraft(itemID: id)
  }

  private func cancel() {
    let id = item.id
    appState.discardTextDraft(itemID: id)
    appState.clearTextEditError(itemID: id)
    editingBody = false
    publishError("")
    if let stored = OriginalTextEdit.draft(from: item.item) {
      title = stored.title
      bodyText = stored.body
      buffer.title = stored.title
      buffer.body = stored.body
      baseline = stored
      buffer.adoptBaseline()
      editToken += 1
    }
  }
}

struct RefusalNote: NSViewRepresentable {
  var text: String
  var identifier: String = "lab-preview-edit-refused"
  var buffer: TextEditBuffer? = nil

  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.setAccessibilityIdentifier(identifier)
    field.setAccessibilityLabel(text)
    field.textColor = .secondaryLabelColor
    field.lineBreakMode = .byWordWrapping
    field.maximumNumberOfLines = 3
    buffer?.errorField = field
    return field
  }

  func updateNSView(_ field: NSTextField, context: Context) {
    field.stringValue = text
    field.setAccessibilityIdentifier(identifier)
    field.setAccessibilityLabel(field.stringValue)
    buffer?.errorField = field
  }
}

struct RowHighlightPlate: NSViewRepresentable {
  var selected: Bool
  var hovered: Bool
  var identifier: String

  func makeNSView(context: Context) -> RowHighlightPlateView {
    let view = RowHighlightPlateView()
    view.setAccessibilityElement(true)
    view.setAccessibilityIdentifier(identifier)
    return view
  }

  func updateNSView(_ view: RowHighlightPlateView, context: Context) {
    view.selected = selected
    view.hovered = hovered
    view.setAccessibilityIdentifier(identifier)
    view.needsDisplay = true
  }
}

final class RowHighlightPlateView: NSView {
  var selected = false
  var hovered = false
  override var isOpaque: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    let color: NSColor? = if selected {
      NSColor.controlAccentColor.withAlphaComponent(0.8)
    } else if hovered {
      NSColor.labelColor.withAlphaComponent(0.08)
    } else {
      NSColor.white.withAlphaComponent(0.001)
    }
    color?.setFill()
    bounds.fill()
  }
}

struct ImageStateMark: NSViewRepresentable {
  var identifier: String

  func makeNSView(context: Context) -> ImageStateMarkView {
    let view = ImageStateMarkView()
    view.setAccessibilityElement(true)
    view.setAccessibilityIdentifier(identifier)
    return view
  }

  func updateNSView(_ view: ImageStateMarkView, context: Context) {
    view.setAccessibilityIdentifier(identifier)
    view.needsDisplay = true
  }
}

final class ImageStateMarkView: NSView {
  override var isFlipped: Bool { true }
  override var isOpaque: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    let accent = NSColor.controlAccentColor
    accent.withAlphaComponent(0.14).setFill()
    bounds.fill()
    accent.setStroke()
    let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
    path.lineWidth = 2
    path.stroke()
  }
}
