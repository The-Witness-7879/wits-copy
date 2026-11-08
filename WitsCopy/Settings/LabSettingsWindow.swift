import AppKit
import SwiftData
import SwiftUI

enum SettingsMetrics {
  /// Shared width; each page supplies a measured height so short forms do not
  /// inherit the appearance page's unused vertical space.
  static let windowContent = NSSize(width: 400, height: 502)
  static let minimumContentHeight: CGFloat = 64
  static let maximumContentHeight: CGFloat = 502
  /// Tab strip hung under the title bar as a titlebar accessory.
  static let tabStripHeight: CGFloat = 56
  /// Form width inside the window: window width minus 30pt padding on each side.
  static let formWidth: Double = 340
  /// Minimum label column so controls start on the same x across form pages.
  /// Fits the longest Chinese label; longer translations widen the column.
  static let labelWidth: Double = 90
  /// Minimum control column, also the width of lists and wrapping descriptions.
  /// Label + gap + controls (90 + 8 + 220) is centered inside the 340pt form.
  static let controlWidth: CGFloat = 220
}

struct SettingsFormChrome<Content: View>: View {
  var identifier: String
  var height: CGFloat? = nil
  @ViewBuilder var content: () -> Content

  var body: some View {
    ScrollView {
      content()
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, SettingsLayout.pageHorizontalPadding)
        .padding(.vertical, SettingsLayout.pageVerticalPadding)
    }
    .frame(width: SettingsMetrics.windowContent.width, alignment: .topLeading)
    .frame(height: height, alignment: .top)
    .frame(maxHeight: .infinity, alignment: .top)
    // Transparent: the window's glass shell (GlassShell) shows through,
    // exactly as the clipboard panel's list sits on its glass.
    .accessibilityIdentifier(identifier)
  }
}

/// One native control owns the icon, title, and the entire visible tab face.
/// Use AppKit cell tracking over bounds, rather than NSToolbar's separate
/// image-button/label viewer. Keyboard and accessibility remain NSButton's.
///
/// Drawn with the clipboard panel's rail states: selected is an accent-tinted
/// fill with an accent icon, hover a faint primary fill, same corner radius.
/// The button stays bordered so AppKit keeps the same frame and hit
/// geometry; only the bezel drawing is replaced by SettingsTabCell.
final class SettingsTabCell: NSButtonCell {
  /// NSButtonCell stacks image-above-title from the top edge, so in a 56pt
  /// face a tall symbol pokes out above the selected fill while the bottom
  /// stays empty. Center icon + title as one block inside the face.
  private func contentShift(in frame: NSRect) -> CGFloat {
    let content = imageRect(forBounds: frame).union(titleRect(forBounds: frame))
    guard !content.isEmpty else { return 0 }
    return (frame.midY - content.midY).rounded()
  }

  override func drawInterior(withFrame frame: NSRect, in controlView: NSView) {
    super.drawInterior(withFrame: frame.offsetBy(dx: 0, dy: contentShift(in: frame)), in: controlView)
  }

  override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
    let hovered = (controlView as? SettingsTabButton)?.isHovered == true
    let fill: NSColor
    if state == .on {
      fill = NSColor.controlAccentColor.withAlphaComponent(0.16)
    } else if hovered {
      fill = NSColor.labelColor.withAlphaComponent(0.07)
    } else {
      return
    }
    let face = frame.insetBy(dx: 1.5, dy: 1)
    let radius = WorkspaceRailMetrics.cornerRadius
    fill.setFill()
    NSBezierPath(roundedRect: face, xRadius: radius, yRadius: radius).fill()
  }
}

final class SettingsTabButton: NSButton {
  override class var cellClass: AnyClass? {
    get { SettingsTabCell.self }
    set {}
  }

  override var state: NSControl.StateValue {
    didSet { refreshChrome() }
  }

  private(set) var isHovered = false {
    didSet { if isHovered != oldValue { needsDisplay = true } }
  }
  private var hoverArea: NSTrackingArea?

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverArea { removeTrackingArea(hoverArea) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    hoverArea = area
  }

  override func mouseEntered(with event: NSEvent) { isHovered = true }
  override func mouseExited(with event: NSEvent) { isHovered = false }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  /// Call after changing title or font; state changes refresh on their own.
  func refreshChrome() {
    let selected = state == .on
    contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    attributedTitle = NSAttributedString(string: title, attributes: [
      .font: font ?? NSFont.systemFont(ofSize: 12),
      .foregroundColor: selected ? NSColor.labelColor : NSColor.secondaryLabelColor,
      .paragraphStyle: paragraph
    ])
    needsDisplay = true
  }

  override func mouseDown(with event: NSEvent) {
    guard isEnabled, !isHiddenOrHasHiddenAncestor,
          bounds.contains(convert(event.locationInWindow, from: nil)), let cell else { return }
    _ = cell.trackMouse(with: event, in: bounds, of: self, untilMouseUp: true)
  }
}

/// Per-page, top-anchored settings window. Does not use SettingsWindowController:
/// its frame autosave belongs to UserDefaults.standard, not the isolated suite.
@MainActor
final class LabSettingsWindowController: NSWindowController {
  private struct Page {
    let identifier: NSToolbarItem.Identifier
    let title: String
    let icon: NSImage
    let hosting: NSHostingController<AnyView>
    let height: CGFloat
  }

  private var pages: [Page] = []
  private var tabButtons: [SettingsTabButton] = []
  private var selectedIndex = 0
  private let contentBox = NSView()
  private var settingsCloseObserver: NSObjectProtocol?

  func show() {
    let decision = PanelClosePolicy.decide(.settings, context: AppState.shared.focusContext)
    switch decision {
    case .close:
      if let panel = AppState.shared.appDelegate?.panel, panel.isPresented {
        AppState.shared.clearTagEditor()
        panel.close()
      }
    case .stayAndYieldToSettings:
      AppState.shared.clearTagEditor()
      AppState.shared.yieldPanelBelowSettings()
    case .stay:
      break
    }
    let isNewWindow = window == nil
    prepareWindow()
    if isNewWindow {
      window?.center()
    }
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    watchSettingsClose()
  }

  private func watchSettingsClose() {
    guard settingsCloseObserver == nil, let window else { return }
    settingsCloseObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification,
      object: window,
      queue: .main
    ) { _ in
      // willClose fires while the window is still on screen; decide after it is gone.
      DispatchQueue.main.async {
        MainActor.assumeIsolated { AppState.shared.restorePanelLevelAfterSettings() }
      }
    }
  }

  /// Construct and lay out the window without ordering it or changing app focus.
  /// Keeping presentation in show() also permits non-presenting AppKit hosts.
  @discardableResult
  func prepareWindow(makeWindow: () -> NSWindow = {
    NSWindow(
      contentRect: NSRect(origin: .zero, size: SettingsMetrics.windowContent),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
  }) -> NSWindow {
    if window == nil {
      build(window: makeWindow())
    }
    install(selectedIndex)
    return window!
  }

  private func build(window: NSWindow) {
    pages = makePages()
    window.title = pages[0].title
    window.titleVisibility = .visible
    window.toolbarStyle = .preference
    window.animationBehavior = .none
    window.isReleasedWhenClosed = false
    window.identifier = NSUserInterfaceItemIdentifier("lab-settings-window")

    // 壳与主面板同源：全尺寸透明标题栏、无分隔线、系统玻璃材质铺满整窗。
    // 不是把窗口直接设透明——那样壁纸会裸透进来；这里有玻璃层兜底。
    GlassShell.applyChrome(to: window)
    let root = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
    root.autoresizingMask = [.width, .height]
    let glass = GlassShell.makeBackground()
    glass.frame = root.bounds
    glass.autoresizingMask = [.width, .height]
    root.addSubview(glass)
    contentBox.translatesAutoresizingMaskIntoConstraints = false
    contentBox.setAccessibilityIdentifier("lab-settings-content")
    root.addSubview(contentBox)
    window.contentView = root

    // A titlebar accessory avoids preference-toolbar image/label hit splitting
    // and its custom-view compression. Keep the original 32 + 56pt top chrome.
    let accessory = NSTitlebarAccessoryViewController()
    accessory.layoutAttribute = .bottom
    accessory.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 56))
    tabButtons = pages.map { page in
      let button = SettingsTabButton(frame: NSRect(x: 0, y: 0, width: 55, height: 56))
      button.title = page.title
      button.image = page.icon.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 20, weight: .regular))
      button.imagePosition = .imageAbove
      button.imageScaling = .scaleProportionallyDown
      let labelFont = NSFont.systemFont(ofSize: 12)
      button.font = labelFont
      button.bezelStyle = .regularSquare
      button.setButtonType(.pushOnPushOff)
      // SettingsTabCell draws the selected face; the cell must not add its
      // own "on" background or pressed bezel on top.
      if let cell = button.cell as? NSButtonCell {
        cell.showsStateBy = []
        cell.highlightsBy = .contentsCellMask
      }
      button.setAccessibilityRole(.button)
      button.setAccessibilityLabel(page.title)
      button.identifier = NSUserInterfaceItemIdentifier(page.identifier.rawValue)
      button.target = self
      button.action = #selector(selectPane(_:))
      button.translatesAutoresizingMaskIntoConstraints = false
      // Keep short labels at 55pt without widening them for a wide symbol.
      // Longer translations retain the native button's 12pt text insets.
      let titleWidth = (page.title as NSString).size(withAttributes: [.font: labelFont]).width
      NSLayoutConstraint.activate([
        button.widthAnchor.constraint(equalToConstant: max(55, ceil(titleWidth) + 24)),
        button.heightAnchor.constraint(equalToConstant: 56)
      ])
      button.refreshChrome()
      return button
    }
    let tabs = NSStackView(views: tabButtons)
    tabs.orientation = .horizontal
    tabs.spacing = 1
    tabs.alignment = .centerY
    tabs.translatesAutoresizingMaskIntoConstraints = false
    accessory.view.addSubview(tabs)
    NSLayoutConstraint.activate([
      tabs.centerXAnchor.constraint(equalTo: accessory.view.centerXAnchor),
      tabs.bottomAnchor.constraint(equalTo: accessory.view.bottomAnchor),
      tabs.heightAnchor.constraint(equalToConstant: 56)
    ])
    window.addTitlebarAccessoryViewController(accessory)
    // AppKit initially assigns the default accessory height on insertion.
    accessory.view.setFrameSize(NSSize(width: 400, height: 56))
    // The content view now spans the whole window; panes live below the
    // title bar and tab strip, inside the window's content layout guide.
    if let guide = window.contentLayoutGuide as? NSLayoutGuide {
      NSLayoutConstraint.activate([
        contentBox.topAnchor.constraint(equalTo: guide.topAnchor),
        contentBox.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
        contentBox.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
        contentBox.bottomAnchor.constraint(equalTo: guide.bottomAnchor)
      ])
    }
    self.window = window
  }

  private func makePages() -> [Page] {
    [
      page("settings-general", "GeneralSettings", NSImage.gearshape!) {
        GeneralSettingsPane()
      },
      page("settings-storage", "StorageSettings", NSImage.externaldrive!) {
        StorageSettingsPane()
      },
      page("settings-privacy", "PrivacySettings", NSImage.handRaised!) {
        PrivacySettingsPane()
      },
      page("settings-appearance", "AppearanceSettings", NSImage.paintpalette!) {
        AppearanceSettingsPane()
      },
      page("settings-advanced", "AdvancedSettings", NSImage.gearshape2!) {
        AdvancedSettingsPane()
      }
    ]
  }

  private func page<V: View>(
    _ raw: String,
    _ table: String,
    _ icon: NSImage,
    @ViewBuilder content: @escaping () -> V
  ) -> Page {
    let title = NSLocalizedString("Title", tableName: table, comment: "")
    let measureHosting = NSHostingController(rootView: AnyView(
      content()
        .frame(width: SettingsMetrics.formWidth, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, SettingsLayout.pageHorizontalPadding)
        .padding(.vertical, SettingsLayout.pageVerticalPadding)
    ))
    if #available(macOS 13, *) {
      measureHosting.sizingOptions = []
    }
    let height = measuredHeight(of: measureHosting)
    measureHosting.view.removeFromSuperview()
    let hosting = NSHostingController(rootView: AnyView(
      SettingsFormChrome(identifier: raw.replacingOccurrences(of: "settings-", with: "settings-pane-"),
                         height: height, content: content)
    ))
    if #available(macOS 13, *) {
      hosting.sizingOptions = []
    }
    hosting.view.translatesAutoresizingMaskIntoConstraints = true
    return Page(
      identifier: NSToolbarItem.Identifier(raw),
      title: title,
      icon: icon,
      hosting: hosting,
      height: height
    )
  }

  private func measuredHeight(of hosting: NSHostingController<AnyView>) -> CGFloat {
    let width = SettingsMetrics.windowContent.width
    let measureWindow = NSPanel(
      contentRect: NSRect(x: -26000, y: -26000, width: width, height: 1600),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    measureWindow.isReleasedWhenClosed = false
    measureWindow.setFrame(NSRect(x: -26000, y: -26000, width: width, height: 1600), display: false)
    hosting.view.frame = NSRect(x: 0, y: 0, width: width, height: 1600)
    measureWindow.contentView = hosting.view
    hosting.view.layoutSubtreeIfNeeded()

    var last = hosting.sizeThatFits(in: CGSize(width: width, height: 8000))
    var stable = 0
    let deadline = Date().addingTimeInterval(2.5)
    while Date() < deadline && stable < 3 {
      RunLoop.current.run(mode: .common, before: Date().addingTimeInterval(0.05))
      hosting.view.layoutSubtreeIfNeeded()
      let next = hosting.sizeThatFits(in: CGSize(width: width, height: 8000))
      if abs(next.height - last.height) < 0.5 {
        stable += 1
      } else {
        stable = 0
        last = next
      }
    }
    measureWindow.close()
    return min(SettingsMetrics.maximumContentHeight, max(SettingsMetrics.minimumContentHeight, ceil(last.height)))
  }

  private func install(_ index: Int) {
    guard pages.indices.contains(index), let window else { return }
    selectedIndex = index
    let page = pages[index]
    // Every page shares the tallest page's height so switching never resizes
    // the window; shorter forms stay pinned to the top.
    let sharedHeight = pages.map(\.height).max() ?? page.height
    // With a full-size content view the frame is the pane plus the title bar
    // and tab strip above it; measure that chrome instead of asking AppKit to
    // convert a content rect, which no longer excludes the title bar.
    let probe = NSRect(origin: .zero, size: SettingsMetrics.windowContent)
    let titlebar = NSWindow.frameRect(forContentRect: probe, styleMask: [.titled]).height - probe.height
    let chrome = titlebar + SettingsMetrics.tabStripHeight
    let full = NSSize(width: SettingsMetrics.windowContent.width, height: sharedHeight + chrome)
    var frame = window.frame
    frame.origin.y += frame.height - full.height
    frame.size = full
    // No min/max size: the window is not resizable, and with a full-size
    // content view AppKit re-adds the tab strip to them, which would clamp
    // the frame 56pt too tall.
    contentBox.subviews.forEach { $0.removeFromSuperview() }
    window.title = page.title
    for (buttonIndex, button) in tabButtons.enumerated() {
      button.state = buttonIndex == index ? .on : .off
      button.setAccessibilityValue(button.state.rawValue)
    }
    // Resize first, then size the pane to the final box. Sizing the pane before
    // setFrame lets autoresizing apply the height delta a second time.
    window.setFrame(frame, display: false)
    window.contentView?.layoutSubtreeIfNeeded()
    let hosted = page.hosting.view
    hosted.autoresizingMask = [.width, .height]
    hosted.frame = contentBox.bounds
    contentBox.addSubview(hosted)
    hosted.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
  }

  @objc private func selectPane(_ sender: NSButton) {
    guard let index = pages.firstIndex(where: { $0.identifier.rawValue == sender.identifier?.rawValue }) else { return }
    install(index)
  }
}
