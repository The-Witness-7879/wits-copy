import AppKit
import SwiftUI

struct VisualEffectView: NSViewRepresentable {
  let visualEffectView = NSVisualEffectView()

  var material: NSVisualEffectView.Material = .popover
  var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

  func makeNSView(context: Context) -> NSVisualEffectView {
    return visualEffectView
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {
    visualEffectView.material = material
    visualEffectView.blendingMode = blendingMode
  }
}

@available(macOS 26.0, *)
struct GlassEffectView: NSViewRepresentable {
  let glassEffectView = NSGlassEffectView()

  var style: NSGlassEffectView.Style = .regular

  func makeNSView(context: Context) -> NSGlassEffectView {
    return glassEffectView
  }

  func updateNSView(_ view: NSGlassEffectView, context: Context) {
    glassEffectView.style = style
  }
}

/// The clipboard panel's shell, shared by every other window the app shows:
/// transparent title bar, no separator, and the same system glass behind
/// everything (ContentView uses GlassEffectView / VisualEffectView above).
@MainActor
enum GlassShell {
  static let backgroundIdentifier = "lab-window-glass"

  /// Same material as ContentView: NSGlassEffectView on macOS 26, otherwise
  /// the popover-material visual effect view the panel falls back to.
  static func makeBackground() -> NSView {
    let view: NSView
    if #available(macOS 26.0, *) {
      let glass = NSGlassEffectView()
      glass.style = .regular
      view = glass
    } else {
      let effect = NSVisualEffectView()
      effect.material = .popover
      effect.blendingMode = .behindWindow
      effect.state = .followsWindowActiveState
      view = effect
    }
    view.setAccessibilityIdentifier(backgroundIdentifier)
    return view
  }

  /// For windows whose layout we own: the content view spans the title bar
  /// and the caller places the glass at the bottom of it.
  static func applyChrome(to window: NSWindow) {
    window.styleMask.insert(.fullSizeContentView)
    adoptChrome(window)
  }

  /// For windows laid out by someone else (Sparkle, AppKit alerts, fixed
  /// nibs): keep their geometry, make the frame transparent and slide the
  /// glass under everything. Idempotent.
  @discardableResult
  static func adopt(_ window: NSWindow) -> Bool {
    guard let content = window.contentView else { return false }
    // A full-size content view already covers the title bar; otherwise the
    // glass goes into the frame view so the title bar is covered too.
    let host = window.styleMask.contains(.fullSizeContentView) ? content : (content.superview ?? content)
    guard !host.subviews.contains(where: { $0.accessibilityIdentifier() == backgroundIdentifier }) else {
      return false
    }
    adoptChrome(window)
    let glass = makeBackground()
    glass.frame = host.bounds
    glass.autoresizingMask = [.width, .height]
    host.addSubview(glass, positioned: .below, relativeTo: nil)
    return true
  }

  private static func adoptChrome(_ window: NSWindow) {
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.isOpaque = false
    window.backgroundColor = .clear
  }
}

/// Text-entry skin used everywhere a field sits on glass or in a popover:
/// the clipboard panel's search-field look (SearchFieldView), a plain field on
/// a faint translucent rounded fill. AppKit's default bezeled field paints an
/// opaque box that reads as a patch next to translucent pop-ups and buttons.
enum GlassField {
  static let height: CGFloat = 22
  static let horizontalPadding: CGFloat = 6
  static var fill: Color { Color.secondary.opacity(0.1) }
  static var nsFill: NSColor { NSColor.secondaryLabelColor.withAlphaComponent(0.1) }
  static var cornerRadius: CGFloat { Popup.cornerRadius }
}

extension View {
  func glassFieldChrome() -> some View {
    background(
      RoundedRectangle(cornerRadius: GlassField.cornerRadius, style: .continuous)
        .fill(GlassField.fill)
    )
  }

  /// A SwiftUI TextField in the shared skin.
  func glassTextField() -> some View {
    self.textFieldStyle(.plain)
      .padding(.horizontal, GlassField.horizontalPadding)
      .frame(height: GlassField.height)
      .glassFieldChrome()
  }
}

/// AppKit counterpart of `glassTextField()`: no bezel, no opaque background,
/// the same translucent rounded fill, text inset and vertically centered.
final class GlassFieldCell: NSTextFieldCell {
  private func inset(_ rect: NSRect) -> NSRect {
    var r = rect.insetBy(dx: GlassField.horizontalPadding, dy: 0)
    let textHeight = cellSize(forBounds: r).height
    if textHeight < r.height {
      r.origin.y += ((r.height - textHeight) / 2).rounded(.down)
      r.size.height = textHeight
    }
    return r
  }

  override func drawingRect(forBounds rect: NSRect) -> NSRect {
    inset(super.drawingRect(forBounds: rect))
  }

  override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
    let radius = GlassField.cornerRadius
    GlassField.nsFill.setFill()
    NSBezierPath(roundedRect: cellFrame, xRadius: radius, yRadius: radius).fill()
    drawInterior(withFrame: cellFrame, in: controlView)
  }

  override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
    super.edit(withFrame: inset(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
  }

  override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
    super.select(withFrame: inset(rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
  }
}

class GlassTextField: NSTextField {
  override class var cellClass: AnyClass? {
    get { GlassFieldCell.self }
    set {}
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    applyGlassSkin()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    applyGlassSkin()
  }

  private func applyGlassSkin() {
    isBezeled = false
    isBordered = false
    drawsBackground = false
    focusRingType = .none
    isEditable = true
    isSelectable = true
    usesSingleLineMode = true
    cell?.isScrollable = true
    cell?.wraps = false
  }

  // The whole rounded fill is visible chrome. NSTextField's default 2pt
  // alignment inset would let it bleed past adjacent controls under Auto Layout.
  override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }

  override var intrinsicContentSize: NSSize {
    NSSize(width: super.intrinsicContentSize.width, height: GlassField.height)
  }
}

#Preview {
  VisualEffectView(
    material: .popover,
    blendingMode: .behindWindow
  )
}
