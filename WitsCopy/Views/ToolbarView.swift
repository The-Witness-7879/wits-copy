import Defaults
import KeyboardShortcuts
import SwiftUI

enum PanelHoverTracking {
  static let marker = "witscopy.panelHoverTracking"

  static func isOwned(_ area: NSTrackingArea) -> Bool {
    area.userInfo?[marker] as? Bool == true
  }

  static func refresh(on view: NSView) {
    for area in view.trackingAreas where isOwned(area) {
      view.removeTrackingArea(area)
    }
    view.addTrackingArea(NSTrackingArea(
      rect: view.bounds,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: view,
      userInfo: [marker: true]
    ))
  }
}

extension View {
  /// 只留系统 tooltip。自绘的那层不参与 AppKit 的显示/收敛生命周期，
  /// 鼠标移开或点别处都不会消失，还会盖在菜单和窗口上面。
  func iconHelp(_ text: String) -> some View {
    help(Text(verbatim: text))
  }

  func iconHelp(key: String) -> some View {
    iconHelp(NSLocalizedString(key, comment: ""))
  }
}

@MainActor
enum ShortcutHelp {
  static func appended(_ name: KeyboardShortcuts.Name, to fallback: String) -> String {
    guard let shortcut = KeyboardShortcuts.Shortcut(name: name), !shortcut.description.isEmpty else {
      return fallback
    }
    return "\(fallback) (\(shortcut.description))"
  }
}

private struct KeyboardShortcutHelpModifier: ViewModifier {
  let name: KeyboardShortcuts.Name
  let fallbackKey: String

  func body(content: Content) -> some View {
    let fallback = NSLocalizedString(fallbackKey, comment: "")
    return content.iconHelp(ShortcutHelp.appended(name, to: fallback))
  }
}

/// One icon size, hit target, and hover treatment for buttons and native menus.
struct LabToolbarChrome: ViewModifier {
  var flexibleWidth = false
  var compact = false
  var tint: Color? = nil
  /// Native NSView buttons must not sit under a SwiftUI hover/contentShape
  /// overlay. That overlay is an unnamed AXGroup and eats the click.
  var nativePassthrough = false
  @Environment(AppState.self) private var appState
  @State private var hovered = false

  func body(content: Content) -> some View {
    let framed = content
      .controlSize(.small)
      .font(.system(size: 12))
      .foregroundStyle(tint ?? Color.secondary)
      .frame(minWidth: compact ? 24 : 28, minHeight: 24)
      .frame(width: flexibleWidth ? nil : (compact ? 24 : 28), height: 24)
    if nativePassthrough {
      // 这块底只负责画 hover，必须让它不参与命中测试，否则会吃掉 NSView 按钮的点击。
      framed
        .background(
          RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color.primary.opacity(hovered ? 0.08 : 0))
            .allowsHitTesting(false)
        )
        .onHover { hovered = $0 }
    } else {
      framed
        .background(
          Color.primary.opacity(hovered ? 0.08 : 0),
          in: RoundedRectangle(cornerRadius: 5, style: .continuous)
        )
        .contentShape(Rectangle())
        .onHover { inside in
          hovered = inside
          // Leaving a button must not re-enable background window drags.
          PanelWindowDrag.lock(appState.appDelegate?.panel)
        }
    }
  }
}

struct ToolbarButton<Label: View>: View {
  var compact = false
  let action: @MainActor () -> Void
  let label: () -> Label

  var body: some View {
    Button(action: action) {
      label()
    }
    .buttonStyle(.plain)
    .modifier(LabToolbarChrome(compact: compact))
  }

  func shortcutKeyHelp(
    name: KeyboardShortcuts.Name,
    fallbackKey: String
  ) -> some View {
    self.modifier(KeyboardShortcutHelpModifier(name: name, fallbackKey: fallbackKey))
  }

}

struct ToolbarView: View {
  @State private var appState = AppState.shared

  @Namespace var unionNamespace

  private var shouldUnpin: Bool {
    return appState.navigator.selection.items.allSatisfy { $0.isPinned }
  }

  private var pinActionDisabled: Bool {
    return appState.navigator.selection.items.contains { $0.isPinned }
      && appState.navigator.selection.items.contains { !$0.isPinned }
  }

  private var selectedImageItem: HistoryItemDecorator? {
    guard appState.navigator.selection.count == 1,
          let item = appState.navigator.selection.first,
          item.hasImage else {
      return nil
    }

    return item
  }

  private var selectedImageText: String? {
    guard let item = selectedImageItem else {
      return nil
    }

    let text = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : item.title
  }

  var body: some View {
    HStack {
      if !appState.navigator.selection.isEmpty {
        Spacer()

        if selectedImageItem != nil {
          ToolbarButton {
            guard let selectedImageText else { return }
            Clipboard.shared.copyInWitsCopy(selectedImageText)
          } label: {
            Image(systemName: "text.viewfinder")
          }
          .iconHelp(NSLocalizedString("CopyExtractedText", tableName: "PreviewItemView", comment: ""))
          .disabled(selectedImageText == nil)
        }

        ToolbarButton {
          withAnimation {
            appState.togglePin()
          }
        } label: {
          if (appState.navigator.selection.items.allSatisfy { $0.isPinned }) {
            Image(systemName: "pin.slash")
          } else {
            Image(systemName: "pin")
          }
        }
        .shortcutKeyHelp(
          name: .pin,
          fallbackKey: shouldUnpin ? "selection_unpin_help" : "selection_pin_help"
        )
        .accessibilityLabel(Text(shouldUnpin ? "selection_unpin" : "item_pin"))
        .disabled(pinActionDisabled)

        ToolbarButton {
          appState.deleteSelection()
        } label: {
          Image(systemName: "trash")
        }
        .shortcutKeyHelp(
          name: .delete,
          fallbackKey: "selection_delete_help"
        )
        .accessibilityLabel(Text("row_delete"))
      }

      if appState.navigator.pasteStackSelected {
        ToolbarButton {
          appState.removePasteStack()
        } label: {
          Image(systemName: "stop")
        }
        .iconHelp(key: "paste_stack_stop")
        .accessibilityLabel(Text("paste_stack_stop"))
      }
    }
  }
}

/// Fires on mouseDown and accepts the click even when a text field is first responder.
final class ImmediateActionButton: NSButton {
  var onMouseDown: (() -> Void)?
  var menuProvider: (() -> (NSMenu, [MenuActionTarget]))?
  /// Right-click only. Left click stays the button action.
  var contextMenuProvider: (() -> (NSMenu, [MenuActionTarget]))?
  /// Nil in production: a presentable anchor calls `NSMenu.popUp` /
  /// `popUpContextMenu` on this button. Tests replace it only to observe that
  /// decision. Real `popUp` enters tracking and, on a detached view, aborts.
  static var menuPopupForTests: ((NSMenu, NSEvent?, NSView) -> Void)?
  private var menuRequestScheduled = false
  private var menuSessionDepth = 0
  private var isHovered = false {
    didSet { if isHovered != oldValue { needsDisplay = true } }
  }

  /// 悬停是「可点」的中间态，比按下态浅一档，按下去仍然由 NSButton 自己画。
  override func draw(_ dirtyRect: NSRect) {
    if isHovered, isEnabled {
      NSColor.labelColor.withAlphaComponent(0.08).setFill()
      NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }
    super.draw(dirtyRect)
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    guard isEnabled else { return }
    if event.modifierFlags.contains(.control), contextMenuProvider != nil {
      present(contextMenuProvider, event: event, anchor: menuAnchorStamp())
      return
    }
    if menuProvider != nil {
      openMenu()
      return
    }
    isHighlighted = true
    onMouseDown?()
    isHighlighted = false
  }

  override func accessibilityPerformPress() -> Bool {
    guard isEnabled else { return false }
    if menuProvider != nil {
      // popUp tracks until the menu closes. Return first so AXPress does not block.
      // A second press while this one is queued or tracking must not open another.
      if menuRequestScheduled || AppState.shared.menuTracking {
        return true
      }
      menuRequestScheduled = true
      let stamp = menuAnchorStamp()
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        defer { self.menuRequestScheduled = false }
        self.present(self.menuProvider, event: nil, anchor: stamp)
      }
      return true
    }
    onMouseDown?()
    return onMouseDown != nil
  }

  override func rightMouseDown(with event: NSEvent) {
    guard isEnabled, contextMenuProvider != nil else {
      super.rightMouseDown(with: event)
      return
    }
    present(contextMenuProvider, event: event, anchor: menuAnchorStamp())
  }

  private func openMenu() {
    present(menuProvider, event: nil, anchor: menuAnchorStamp())
  }

  private func present(
    _ provider: (() -> (NSMenu, [MenuActionTarget]))?,
    event: NSEvent?,
    anchor: MenuAnchorStamp?
  ) {
    guard let provider else { return }
    guard menuAnchorReady(anchor) else { return }
    // Another session already owns tracking. Do not pop and do not clear it.
    guard !AppState.shared.menuTracking else { return }
    let (menu, targets) = provider()
    // Provider may detach, move, or hand tracking to another session.
    // A nil stamp stays nil; do not adopt a window that appears later.
    guard menuAnchorReady(anchor), !AppState.shared.menuTracking else { return }
    retainedTargets = targets
    AppState.shared.menuTracking = true
    menuSessionDepth += 1
    defer {
      menuSessionDepth -= 1
      if menuSessionDepth == 0 {
        AppState.shared.menuTracking = false
        retainedTargets = []
      }
    }
    if let probe = Self.menuPopupForTests {
      probe(menu, event, self)
    } else if let event {
      NSMenu.popUpContextMenu(menu, with: event, for: self)
    } else {
      menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height), in: self)
    }
  }

  /// Window captured with the request. Nil was not a legal window then and
  /// must not be replaced by a window attached before the request runs.
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

  private var retainedTargets: [MenuActionTarget] = []
  var retainedMenuTargetCount: Int { retainedTargets.count }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    PanelHoverTracking.refresh(on: self)
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    if isEnabled { isHovered = true }
    PanelWindowDrag.lock(AppState.shared.appDelegate?.panel)
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    isHovered = false
    PanelWindowDrag.lock(AppState.shared.appDelegate?.panel)
  }
}

final class MenuActionTarget: NSObject {
  let run: () -> Void
  init(_ run: @escaping () -> Void) { self.run = run }
  @objc func fire(_ sender: Any?) { run() }
}

struct ImmediateMenuEntry {
  var title: String = ""
  var systemName: String?
  var identifier: String = ""
  var enabled: Bool = true
  var separator: Bool = false
  var action: () -> Void = {}
}

struct ImmediateIconButton: NSViewRepresentable {
  var systemName: String
  var help: String
  var identifier: String
  var label: String
  var value: String = ""
  var tint: NSColor = .secondaryLabelColor
  var enabled: Bool = true
  var action: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(action) }

  final class Coordinator: NSObject {
    var action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire(_ sender: Any?) { action() }
  }

  func makeNSView(context: Context) -> ImmediateActionButton {
    let button = ImmediateActionButton()
    button.isBordered = false
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleProportionallyDown
    button.setButtonType(.momentaryChange)
    configure(button, context: context)
    return button
  }

  func updateNSView(_ button: ImmediateActionButton, context: Context) {
    context.coordinator.action = action
    configure(button, context: context)
  }

  private func configure(_ button: ImmediateActionButton, context: Context) {
    let image = NSImage(systemSymbolName: systemName, accessibilityDescription: label)
    image?.isTemplate = true
    button.image = image
    button.contentTintColor = tint
    button.toolTip = help.isEmpty ? nil : help
    button.setAccessibilityHelp(help.isEmpty ? nil : help)
    button.isEnabled = enabled
    button.menuProvider = nil
    button.contextMenuProvider = nil
    button.setAccessibilityElement(true)
    button.setAccessibilityRole(.button)
    button.setAccessibilityIdentifier(identifier)
    button.setAccessibilityLabel(label)
    if value.isEmpty {
      button.setAccessibilityValue(nil)
    } else {
      button.setAccessibilityValue(value)
    }
    button.target = context.coordinator
    button.action = #selector(Coordinator.fire(_:))
    button.onMouseDown = { [weak coordinator = context.coordinator] in
      coordinator?.action()
    }
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    nsView: ImmediateActionButton,
    context: Context
  ) -> CGSize? {
    CGSize(width: proposal.width ?? 28, height: proposal.height ?? 24)
  }
}

struct ImmediateMenuButton: NSViewRepresentable {
  var systemName: String
  var help: String
  var identifier: String
  var label: String
  var entries: [ImmediateMenuEntry]

  func makeCoordinator() -> Coordinator { Coordinator() }

  final class Coordinator {
    var entries: [ImmediateMenuEntry] = []
  }

  func makeNSView(context: Context) -> ImmediateActionButton {
    let button = ImmediateActionButton()
    button.isBordered = false
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleProportionallyDown
    button.setButtonType(.momentaryChange)
    configure(button, context: context)
    return button
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    nsView: ImmediateActionButton,
    context: Context
  ) -> CGSize? {
    CGSize(width: proposal.width ?? 24, height: proposal.height ?? 24)
  }

  func updateNSView(_ button: ImmediateActionButton, context: Context) {
    configure(button, context: context)
  }

  private func configure(_ button: ImmediateActionButton, context: Context) {
    context.coordinator.entries = entries
    let image = NSImage(systemSymbolName: systemName, accessibilityDescription: label)
    image?.isTemplate = true
    button.image = image
    button.contentTintColor = .secondaryLabelColor
    button.toolTip = help.isEmpty ? nil : help
    button.setAccessibilityHelp(help.isEmpty ? nil : help)
    button.onMouseDown = nil
    button.contextMenuProvider = nil
    button.setAccessibilityElement(true)
    button.setAccessibilityIdentifier(identifier)
    button.setAccessibilityLabel(label)
    button.setAccessibilityRole(.popUpButton)
    button.menuProvider = { [weak coordinator = context.coordinator] in
      Self.menu(from: coordinator?.entries ?? [])
    }
  }

  static func menu(from entries: [ImmediateMenuEntry]) -> (NSMenu, [MenuActionTarget]) {
    let menu = NSMenu()
    var targets: [MenuActionTarget] = []
    for entry in entries {
      if entry.separator {
        menu.addItem(.separator())
        continue
      }
      let item = NSMenuItem(title: entry.title, action: #selector(MenuActionTarget.fire(_:)), keyEquivalent: "")
      if let symbol = entry.systemName {
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: entry.title)
      }
      item.isEnabled = entry.enabled
      item.setAccessibilityIdentifier(entry.identifier)
      let target = MenuActionTarget(entry.action)
      item.target = target
      targets.append(target)
      menu.addItem(item)
    }
    return (menu, targets)
  }
}
