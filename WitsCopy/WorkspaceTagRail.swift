import AppKit
import SwiftUI

/// List rows should start a drag with this source. `.copy` keeps the row; do not delete it when the drag ends.
///
/// Dragging out of the window only means something inside a tag: it takes the
/// item out of that tag. In "All" there is nothing to take it out of, so the
/// ghost slides back and nothing changes. A drag never deletes an item.
final class WorkspaceItemDragSource: NSObject, NSDraggingSource {
  private var pendingItemID: UUID?
  private var pendingImage: NSImage?
  private var removesOnDropOutside = false
  private weak var sourceWindow: NSWindow?

  /// 记住这次拖的是哪一条、从哪个窗口出发、拖出窗外是否会移出分类。
  func prepare(itemID: UUID, window: NSWindow?, image: NSImage, removesOnDropOutside: Bool) {
    pendingItemID = itemID
    pendingImage = image
    sourceWindow = window
    self.removesOnDropOutside = removesOnDropOutside
  }

  /// Only a removable drag skips the slide-back; its ending is the dissolve.
  var slidesBackOnCancel: Bool { !removesOnDropOutside }

  func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
    session.animatesToStartingPositionsOnCancelOrFail = slidesBackOnCancel
  }

  func draggingSession(
    _ session: NSDraggingSession,
    sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    WorkspaceItemDrag.sourceOperation(withinApplication: context == .withinApplication)
  }

  /// 拖到窗口外松手 = 把它从当前分类里拿出来。
  /// operation 为空表示这次拖拽没有被任何落点接受。
  func draggingSession(
    _ session: NSDraggingSession,
    endedAt screenPoint: NSPoint,
    operation: NSDragOperation
  ) {
    let id = pendingItemID
    let image = pendingImage
    pendingItemID = nil
    pendingImage = nil
    guard operation == [], removesOnDropOutside, let id else { return }
    guard let window = sourceWindow, !window.frame.contains(screenPoint) else {
      return
    }
    WorkspaceItemDragPuff.play(at: screenPoint, image: image)
    Task { @MainActor in
      AppState.shared.dropOutsideWindow(itemID: id)
    }
  }
}

/// 拖出分类时的消散：虚影留在松手处，放大、变淡、散开，配一声很轻的系统音。
/// 像把 Dock 里的图标拖走那样，表达「已经拿掉了」，而不是滑回原位。
@MainActor
enum WorkspaceItemDragPuff {
  static func play(at screenPoint: NSPoint, image: NSImage?) {
    let size = image?.size ?? WorkspaceItemDrag.suggestedGhostSize
    let frame = NSRect(
      x: screenPoint.x - size.width / 2,
      y: screenPoint.y - size.height / 2,
      width: size.width,
      height: size.height
    ).insetBy(dx: -size.width * 0.3, dy: -size.height * 0.6)
    let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.ignoresMouseEvents = true
    window.level = .popUpMenu

    let host = NSView(frame: NSRect(origin: .zero, size: frame.size))
    host.wantsLayer = true
    host.layerUsesCoreImageFilters = true
    let ghost = CALayer()
    ghost.bounds = CGRect(origin: .zero, size: size)
    ghost.position = CGPoint(x: frame.width / 2, y: frame.height / 2)
    ghost.contents = image
    ghost.contentsScale = window.backingScaleFactor
    host.layer?.addSublayer(ghost)
    window.contentView = host
    window.orderFrontRegardless()

    let duration = 0.28
    let scale = CABasicAnimation(keyPath: "transform.scale")
    scale.fromValue = 1
    scale.toValue = 1.35
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 1
    fade.toValue = 0
    let blur = CABasicAnimation(keyPath: "filters.blur.inputRadius")
    blur.fromValue = 0
    blur.toValue = 6
    if let filter = CIFilter(name: "CIGaussianBlur") {
      filter.name = "blur"
      ghost.filters = [filter]
    }
    let group = CAAnimationGroup()
    group.animations = [scale, fade, blur]
    group.duration = duration
    group.timingFunction = CAMediaTimingFunction(name: .easeOut)
    ghost.opacity = 0
    ghost.add(group, forKey: "dissolve")

    DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.04) {
      window.orderOut(nil)
    }

    // 很轻、很短。只为让「移出」这件事有落点感，不抢注意力。
    if let sound = NSSound(named: "Tink") {
      sound.volume = 0.2
      sound.play()
    }
  }
}

enum WorkspaceItemDragSession {
  /// Native ghost: `NSDraggingItem` plus `WorkspaceItemDrag.draggingImage`. Prefer this over SwiftUI's drag preview in the panel.
  /// Write only `WorkspaceItemDrag.pasteboardType`. Do not also publish `public.utf8-plain-text`.
  @MainActor
  static func begin(
    from view: NSView,
    event: NSEvent,
    itemID: UUID,
    title: String,
    source: NSDraggingSource
  ) {
    let writer = NSPasteboardItem()
    writer.setData(WorkspaceItemDrag.encode(itemID), forType: WorkspaceItemDrag.pasteboardType)
    let item = NSDraggingItem(pasteboardWriter: writer)
    var image = NSImage()
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
      image = WorkspaceItemDrag.draggingImage(title: title)
    }
    let origin = view.convert(event.locationInWindow, from: nil)
    let ghostSize = WorkspaceItemDrag.suggestedGhostSize
    item.setDraggingFrame(
      NSRect(x: origin.x - 18, y: origin.y - ghostSize.height / 2, width: ghostSize.width, height: ghostSize.height),
      contents: image
    )
    if let source = source as? WorkspaceItemDragSource {
      source.prepare(
        itemID: itemID,
        window: view.window,
        image: image,
        removesOnDropOutside: AppState.shared.history.tagFilter != nil
      )
    }
    view.beginDraggingSession(with: [item], event: event, source: source)
  }
}

/// Field editor ownership for `PanelKeyPolicy.defersToLocalEditor`. Integration must add that check.
final class WorkspaceTagNameField: GlassTextField {
  static func owns(_ responder: NSResponder?) -> Bool {
    if responder is WorkspaceTagNameField { return true }
    if let editor = responder as? NSTextView, editor.delegate is WorkspaceTagNameField { return true }
    return false
  }
}

final class WorkspaceTagDropButton: NSButton {
  var onMouseDown: (() -> Void)?
  var menuProvider: (() -> (NSMenu, [MenuActionTarget]))?
  var contextMenuProvider: (() -> (NSMenu, [MenuActionTarget]))?
  var liveItems: () -> [WorkspaceItemDropLiveItem] = { [] }
  var onDropHighlight: (Bool) -> Void = { _ in }
  var onPerformDrop: (UUID) -> Bool = { _ in false }
  private var dropHighlighted = false
  private var retainedTargets: [MenuActionTarget] = []
  var retainedMenuTargetCount: Int { retainedTargets.count }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    registerForDraggedTypes([WorkspaceItemDrag.pasteboardType])
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    registerForDraggedTypes([WorkspaceItemDrag.pasteboardType])
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    guard isEnabled else { return }
    if event.modifierFlags.contains(.control), contextMenuProvider != nil {
      present(contextMenuProvider, event: event)
      return
    }
    if menuProvider != nil {
      present(menuProvider, event: nil)
      return
    }
    isHighlighted = true
    onMouseDown?()
    isHighlighted = false
  }

  override func accessibilityPerformPress() -> Bool {
    guard isEnabled else { return false }
    onMouseDown?()
    return onMouseDown != nil
  }

  override func rightMouseDown(with event: NSEvent) {
    guard isEnabled, contextMenuProvider != nil else {
      super.rightMouseDown(with: event)
      return
    }
    present(contextMenuProvider, event: event)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    PanelHoverTracking.refresh(on: self)
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    PanelWindowDrag.lock(AppState.shared.appDelegate?.panel)
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    PanelWindowDrag.lock(AppState.shared.appDelegate?.panel)
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    updateHighlight(for: sender)
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    updateHighlight(for: sender)
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    setHighlighted(WorkspaceDropHighlight.highlighted(after: .exited))
  }

  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    acceptedToken(from: sender) != nil
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    defer { setHighlighted(WorkspaceDropHighlight.highlighted(after: .performed)) }
    guard let token = acceptedToken(from: sender) else { return false }
    return onPerformDrop(token)
  }

  override func concludeDragOperation(_ sender: NSDraggingInfo?) {
    setHighlighted(WorkspaceDropHighlight.highlighted(after: .concluded))
  }

  override func draggingEnded(_ sender: NSDraggingInfo?) {
    setHighlighted(WorkspaceDropHighlight.highlighted(after: .ended))
  }

  private func present(
    _ provider: (() -> (NSMenu, [MenuActionTarget]))?,
    event: NSEvent?
  ) {
    guard let provider else { return }
    let anchor = menuAnchorStamp()
    guard menuAnchorReady(anchor) else { return }
    guard !AppState.shared.menuTracking else { return }
    let (menu, targets) = provider()
    guard menuAnchorReady(anchor), !AppState.shared.menuTracking else { return }
    retainedTargets = targets
    AppState.shared.menuTracking = true
    defer {
      AppState.shared.menuTracking = false
      retainedTargets = []
    }
    if let event {
      NSMenu.popUpContextMenu(menu, with: event, for: self)
    } else {
      menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height), in: self)
    }
  }

  private struct MenuAnchorStamp {
    weak var window: NSWindow?
    let windowID: ObjectIdentifier
  }

  private func menuAnchorStamp() -> MenuAnchorStamp? {
    guard let window else { return nil }
    return MenuAnchorStamp(window: window, windowID: ObjectIdentifier(window))
  }

  private func menuAnchorReady(_ stamp: MenuAnchorStamp?) -> Bool {
    guard isEnabled, let stamp, let stamped = stamp.window, stamped === window else {
      return false
    }
    guard stamp.windowID == ObjectIdentifier(stamped) else { return false }
    guard let content = stamped.contentView else { return false }
    guard self === content || isDescendant(of: content) else { return false }
    guard !isHiddenOrHasHiddenAncestor, stamped.isVisible else { return false }
    return true
  }

  private func updateHighlight(for sender: NSDraggingInfo) -> NSDragOperation {
    let allowed = acceptedToken(from: sender) != nil
    setHighlighted(WorkspaceDropHighlight.highlighted(after: .updated(allowed)))
    return WorkspaceDropHighlight.operation(allowed: allowed)
  }

  private func acceptedToken(from sender: NSDraggingInfo) -> UUID? {
    WorkspaceItemDrag.acceptedItemID(
      pasteboard: sender.draggingPasteboard,
      sourceInProcess: sender.draggingSource != nil,
      live: liveItems()
    )
  }

  private func setHighlighted(_ on: Bool) {
    guard dropHighlighted != on else { return }
    dropHighlighted = on
    wantsLayer = true
    layer?.cornerRadius = WorkspaceRailMetrics.cornerRadius
    layer?.borderWidth = on ? 2 : 0
    layer?.borderColor = on ? NSColor.controlAccentColor.cgColor : nil
    onDropHighlight(on)
  }
}

@MainActor
final class WorkspaceTagCreateController {
  private var popover: NSPopover?
  private var form: WorkspaceTagCreateFormView?
  private var onCommit: ((String) -> String?)?
  private var onCancel: (() -> Void)?
  private weak var anchor: NSView?

  var isPresented: Bool { popover?.isShown ?? false }

  func present(
    from anchor: NSView,
    onCommit: @escaping (String) -> String?,
    onCancel: @escaping () -> Void
  ) {
    dismiss(cancelled: true)
    guard anchor.window != nil else { return }
    self.anchor = anchor
    self.onCommit = onCommit
    self.onCancel = onCancel

    let form = WorkspaceTagCreateFormView(
      frame: NSRect(origin: .zero, size: WorkspaceTagCreatePlacement.formSize(showsError: false))
    )
    form.onCommit = { [weak self, weak form] draft in
      guard let self, let form else { return }
      if let message = self.onCommit?(draft) {
        form.show(message)
      } else {
        self.dismiss(cancelled: false)
      }
    }
    form.onCancel = { [weak self] in
      self?.dismiss(cancelled: true)
    }
    form.onSizeChange = { [weak self] size in
      self?.popover?.contentSize = size
    }
    self.form = form

    // 真正的 NSPopover：深灰渐变、圆角、顶部箭头、点外关闭全部由系统提供。
    // 之前用手绘 NSView 模拟，材质怎么调都对不上系统弹层。
    let controller = NSViewController()
    controller.view = form
    let popover = NSPopover()
    popover.contentViewController = controller
    popover.behavior = .transient
    popover.animates = true
    popover.contentSize = form.preferredSize
    popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
    self.popover = popover
  }

  func dismiss(cancelled: Bool) {
    if cancelled {
      onCancel?()
    }
    onCommit = nil
    onCancel = nil
    popover?.close()
    popover = nil
    form = nil
    anchor = nil
  }

  @objc private func cancelFromBlocker() {
    dismiss(cancelled: true)
  }
}

final class WorkspaceTagCreateFormView: NSView, NSTextFieldDelegate {
  var onCommit: ((String) -> Void)?
  var onCancel: (() -> Void)?
  var onSizeChange: ((CGSize) -> Void)?
  let field = WorkspaceTagNameField(frame: .zero)
  private let titleLabel = NSTextField(labelWithString: "")
  private let errorLabel = NSTextField(labelWithString: "")
  private var createButton: NSButton?
  private var cancelButton: NSButton?
  private var retainedTargets: [NSButton] = []

  /// The row is either there or not: a hidden error must not reserve blank space.
  private var errorTop: NSLayoutConstraint?
  private var errorHeight: NSLayoutConstraint?
  private var bottomWithError: NSLayoutConstraint?
  private var bottomWithoutError: NSLayoutConstraint?

  /// 高度跟着内容走；controller 定位时读这个值。
  var preferredSize: CGSize {
    WorkspaceTagCreatePlacement.formSize(
      showsError: !errorLabel.isHidden && !errorLabel.stringValue.isEmpty
    )
  }

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    // 背景交给 NSPopover：它自带深灰渐变、圆角和阴影。
    // 自绘一层只会和外层打架，就是之前一会黑一会透明的原因。
    setAccessibilityElement(true)
    setAccessibilityIdentifier("lab-rail-new-tag-form")
    build()
  }

  required init?(coder: NSCoder) { nil }

  func show(_ message: String) {
    let shows = !message.isEmpty
    errorLabel.stringValue = message
    errorLabel.isHidden = !shows
    applyErrorLayout(shows)
    notifyHeightChanged()
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
      onCancel?()
      return true
    }
    if commandSelector == #selector(NSResponder.insertNewline(_:)) {
      commit()
      return true
    }
    return false
  }

  /// Only a name can be created; keep the primary button honest while the field is empty.
  func controlTextDidChange(_ notification: Notification) {
    updateCreateEnabled()
  }

  private func updateCreateEnabled() {
    createButton?.isEnabled = HistoryItem.normalizedTag(field.stringValue) != nil
  }

  private func build() {
    let inset = WorkspaceTagCreatePlacement.contentInset

    titleLabel.stringValue = WorkspaceTagCopy.text("tag_directory_add")
    titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.setAccessibilityIdentifier("lab-rail-new-tag-title")
    addSubview(titleLabel)

    field.translatesAutoresizingMaskIntoConstraints = false
    field.placeholderString = WorkspaceTagCopy.text("tag_directory_name")
    field.delegate = self
    field.setAccessibilityIdentifier("lab-rail-new-tag-field")
    addSubview(field)

    let create = button(
      title: WorkspaceTagCopy.text("tag_directory_create"),
      help: WorkspaceTagCopy.text("tag_directory_create_help"),
      identifier: "lab-rail-new-tag-create",
      action: #selector(commit)
    )
    let cancel = button(
      title: WorkspaceTagCopy.text("tag_directory_cancel"),
      help: WorkspaceTagCopy.text("tag_directory_cancel_help"),
      identifier: "lab-rail-new-tag-cancel",
      action: #selector(cancel)
    )
    addSubview(create)
    addSubview(cancel)
    // 平台习惯：取消在左、创建在右；回车=创建，Esc=取消。
    create.keyEquivalent = "\r"
    cancel.keyEquivalent = "\u{1b}"
    createButton = create
    cancelButton = cancel
    retainedTargets = [create, cancel]

    errorLabel.font = .systemFont(ofSize: 11)
    errorLabel.translatesAutoresizingMaskIntoConstraints = false
    errorLabel.textColor = .systemRed
    errorLabel.maximumNumberOfLines = 1
    errorLabel.isHidden = true
    errorLabel.setAccessibilityIdentifier("lab-rail-new-tag-error")
    addSubview(errorLabel)

    let bottomWithoutError = create.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)
    let errorTop = errorLabel.topAnchor.constraint(equalTo: create.bottomAnchor)
    let errorHeight = errorLabel.heightAnchor.constraint(equalToConstant: 0)
    let bottomWithError = errorLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)
    self.bottomWithoutError = bottomWithoutError
    self.errorTop = errorTop
    self.errorHeight = errorHeight
    self.bottomWithError = bottomWithError

    NSLayoutConstraint.activate([
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: inset),
      titleLabel.heightAnchor.constraint(equalToConstant: WorkspaceTagCreatePlacement.titleHeight),

      field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
      field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
      field.topAnchor.constraint(
        equalTo: titleLabel.bottomAnchor,
        constant: WorkspaceTagCreatePlacement.titleToField
      ),
      field.heightAnchor.constraint(equalToConstant: WorkspaceTagCreatePlacement.fieldHeight),

      create.topAnchor.constraint(
        equalTo: field.bottomAnchor,
        constant: WorkspaceTagCreatePlacement.fieldToButtons
      ),
      create.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
      create.heightAnchor.constraint(equalToConstant: WorkspaceTagCreatePlacement.buttonHeight),

      cancel.topAnchor.constraint(equalTo: create.topAnchor),
      cancel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
      cancel.trailingAnchor.constraint(
        equalTo: create.leadingAnchor,
        constant: -WorkspaceTagCreatePlacement.buttonGap
      ),
      cancel.heightAnchor.constraint(equalTo: create.heightAnchor),
      // 等宽两半，合计正好等于输入框宽度：取消在左、创建（默认按钮）在右。
      // 之前 92/96 且左侧起排，右边和底部都留出空档，看起来像没排过。
      cancel.widthAnchor.constraint(equalTo: create.widthAnchor),

      errorTop,
      errorHeight,
      bottomWithoutError,
      errorLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
      errorLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset)
    ])

    updateCreateEnabled()
  }

  /// The error row is either present or absent. A hidden label that keeps its
  /// height is what left a blank strip under the buttons.
  private func applyErrorLayout(_ shows: Bool) {
    guard let errorTop, let errorHeight, let bottomWithError, let bottomWithoutError else { return }
    if shows {
      bottomWithoutError.isActive = false
      errorTop.constant = WorkspaceTagCreatePlacement.errorGap
      errorHeight.constant = WorkspaceTagCreatePlacement.errorHeight
      bottomWithError.isActive = true
    } else {
      bottomWithError.isActive = false
      errorTop.constant = 0
      errorHeight.constant = 0
      bottomWithoutError.isActive = true
    }
    layoutSubtreeIfNeeded()
  }

  /// 高度变了要让 popover 跟上，否则错误行还按旧尺寸被裁掉。
  private func notifyHeightChanged() {
    let size = preferredSize
    if frame.size != size {
      setFrameSize(size)
    }
    onSizeChange?(size)
  }

  private func button(
    title: String,
    help: String,
    identifier: String,
    action: Selector
  ) -> NSButton {
    let button = NSButton(title: title, target: self, action: action)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.bezelStyle = .rounded
    button.toolTip = help
    button.setAccessibilityLabel(title)
    button.setAccessibilityIdentifier(identifier)
    return button
  }

  @objc private func commit() {
    onCommit?(field.stringValue)
  }

  @objc private func cancel() {
    onCancel?()
  }
}
