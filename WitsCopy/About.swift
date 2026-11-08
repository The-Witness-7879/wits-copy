import Cocoa

/// LSUIElement apps get an empty system about panel. This window is the about UI.
final class AboutPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

/// What an about window owes the user: who made this, which exact build is
/// running, where it came from, and where to go next (updates, release notes,
/// source, bug reports, licenses). Nothing here is decorative.
enum AboutInfo {
  static let repository = URL(string: "https://github.com/The-Witness-7879/wits-copy")!
  static var releaseNotes: URL { repository.appendingPathComponent("releases") }
  static var issues: URL { repository.appendingPathComponent("issues") }
  /// Full license texts ship in the bundle, so they read offline and match this build.
  static var acknowledgements: URL? { Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt") }

  static var minimumSystem: String {
    Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String ?? ""
  }

  static var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
  }

  static var build: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
  }

  /// "版本 0.1.0（2026110908）" / "Version 0.1.0 (2026110908)": the build is
  /// what tells two copies of the same version apart in a bug report.
  static var versionLine: String {
    String(format: NSLocalizedString("about_version", comment: ""), version, build)
  }
}

final class About {
  static let textWidth: CGFloat = 280
  static let sideMargin: CGFloat = 28
  private var panel: AboutPanel?
  private var targets: [AboutLinkTarget] = []
  private weak var updateButton: NSButton?
  private var closeObserver: NSObjectProtocol?

  @objc
  func openAbout(_ sender: NSMenuItem?) {
    let panel = self.panel ?? makePanel()
    self.panel = panel
    // Sparkle refuses a second check while one runs; say so instead of a dead link.
    updateButton?.isEnabled = MainActor.assumeIsolated { AppState.shared.softwareUpdater.canCheckForUpdates }
    if let screen = NSScreen.main {
      panel.setFrameOrigin(NSPoint(
        x: screen.visibleFrame.midX - panel.frame.width / 2,
        y: screen.visibleFrame.midY - panel.frame.height / 2
      ))
    }
    // An ordinary window, like Settings: the clipboard panel steps down while
    // the about window is open. Floating it above popUpMenu instead also put it
    // above Sparkle's windows and its app-modal "up to date" alert; the alert
    // then sat hidden behind this window while blocking its close button.
    MainActor.assumeIsolated { AppState.shared.yieldPanelBelowSettings() }
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
  }

  var isVisible: Bool { panel?.isVisible ?? false }

  private func makePanel() -> AboutPanel {
    let panel = AboutPanel(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    panel.title = NSLocalizedString("about", comment: "")
    panel.titleVisibility = .hidden
    panel.isReleasedWhenClosed = false
    panel.level = .normal
    panel.contentView = makeContent()
    if let content = panel.contentView {
      content.layoutSubtreeIfNeeded()
      panel.setContentSize(content.fittingSize)
    }
    // Menu actions arrive on the main thread.
    MainActor.assumeIsolated { _ = GlassShell.adopt(panel) }
    closeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: panel, queue: .main
    ) { _ in
      // willClose fires while the window is still on screen; decide after it is gone.
      DispatchQueue.main.async {
        MainActor.assumeIsolated { AppState.shared.restorePanelLevelAfterSettings() }
      }
    }
    return panel
  }

  private func label(_ text: String, font: NSFont, color: NSColor = .labelColor, id: String) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = font
    field.textColor = color
    field.alignment = .center
    field.preferredMaxLayoutWidth = Self.textWidth
    field.setAccessibilityIdentifier(id)
    return field
  }

  private func link(_ key: String, help: String, id: String, action: @escaping () -> Void) -> NSButton {
    let target = AboutLinkTarget(action: action)
    targets.append(target)
    let button = NSButton(title: NSLocalizedString(key, comment: ""), target: target, action: #selector(AboutLinkTarget.fire))
    button.isBordered = false
    button.contentTintColor = .linkColor
    button.font = .systemFont(ofSize: 12)
    button.toolTip = NSLocalizedString(help, comment: "")
    button.setAccessibilityIdentifier(id)
    return button
  }

  private func makeContent() -> NSView {
    let icon = NSImageView()
    icon.image = NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName)
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.setAccessibilityIdentifier("lab-about-icon")

    let name = label(LabRuntime.displayName, font: .systemFont(ofSize: 18, weight: .semibold), id: "lab-about-name")
    let version = label(AboutInfo.versionLine, font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                        color: .secondaryLabelColor, id: "lab-about-version")
    version.isSelectable = true
    let tagline = label(NSLocalizedString("about_tagline", comment: ""), font: .systemFont(ofSize: 13, weight: .medium),
                        id: "lab-about-tagline")
    let summary = label(NSLocalizedString("about_summary", comment: ""), font: .systemFont(ofSize: 12),
                        color: .secondaryLabelColor, id: "lab-about-summary")

    let update = link("about_check_updates", help: "about_check_updates_help", id: "lab-about-updates") {
      MainActor.assumeIsolated { AppState.shared.softwareUpdater.checkForUpdates() }
    }
    updateButton = update
    // Two centered columns of two: four links in one row overflow the panel
    // in English; each column centers its own pair, the pair of columns
    // centers in the panel.
    func column(_ views: [NSView]) -> NSStackView {
      let column = NSStackView(views: views)
      column.orientation = .vertical
      column.alignment = .centerX
      column.spacing = 2
      return column
    }
    let links = NSStackView(views: [
      column([update, link("about_source", help: "about_source_help", id: "lab-about-source") {
        NSWorkspace.shared.open(AboutInfo.repository)
      }]),
      column([link("about_release_notes", help: "about_release_notes_help", id: "lab-about-release-notes") {
        NSWorkspace.shared.open(AboutInfo.releaseNotes)
      }, link("about_feedback", help: "about_feedback_help", id: "lab-about-feedback") {
        NSWorkspace.shared.open(AboutInfo.issues)
      }])
    ])
    links.orientation = .horizontal
    links.alignment = .top
    links.spacing = 28

    let copyright = label(NSLocalizedString("about_copyright", comment: ""), font: .systemFont(ofSize: 10.5),
                          color: .tertiaryLabelColor, id: "lab-about-copyright")
    let upstream = label(NSLocalizedString("about_upstream", comment: ""), font: .systemFont(ofSize: 10.5),
                         color: .tertiaryLabelColor, id: "lab-about-upstream")
    let licenses = link("about_licenses", help: "about_licenses_help", id: "lab-about-licenses") {
      if let url = AboutInfo.acknowledgements { NSWorkspace.shared.open(url) }
    }
    licenses.font = .systemFont(ofSize: 10.5)
    let requirement = label(
      String(format: NSLocalizedString("about_requirement", comment: ""), AboutInfo.minimumSystem),
      font: .systemFont(ofSize: 10.5), color: .tertiaryLabelColor, id: "lab-about-requirement"
    )

    let stack = NSStackView(views: [icon, name, version, tagline, summary, links, copyright, upstream, requirement, licenses])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 4
    stack.setCustomSpacing(10, after: icon)
    stack.setCustomSpacing(12, after: version)
    stack.setCustomSpacing(16, after: summary)
    stack.setCustomSpacing(16, after: links)
    stack.setCustomSpacing(2, after: copyright)
    stack.setCustomSpacing(2, after: upstream)
    stack.setCustomSpacing(6, after: requirement)
    stack.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.addSubview(stack)
    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: 72),
      icon.heightAnchor.constraint(equalToConstant: 72),
      summary.widthAnchor.constraint(equalToConstant: Self.textWidth),
      tagline.widthAnchor.constraint(lessThanOrEqualToConstant: Self.textWidth),
      copyright.widthAnchor.constraint(lessThanOrEqualToConstant: Self.textWidth),
      upstream.widthAnchor.constraint(lessThanOrEqualToConstant: Self.textWidth),
      // Explicit margins: the title bar overlays the top (full-size content).
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.sideMargin),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.sideMargin),
      stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 36),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -28)
    ])
    return container
  }
}

final class AboutLinkTarget: NSObject {
  let action: () -> Void
  init(action: @escaping () -> Void) { self.action = action }
  @objc func fire() { action() }
}
