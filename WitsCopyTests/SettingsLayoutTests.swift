import AppKit
import XCTest
@testable import WitsCopy

final class SettingsLayoutTests: XCTestCase {
  private var settingsRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("WitsCopy/Settings")
  }

  func testAllSettingsPanesUseTheSharedGrid() throws {
    for name in ["General", "Storage", "Privacy", "Appearance", "Advanced"] {
      let source = try String(contentsOf: settingsRoot.appendingPathComponent("\(name)SettingsPane.swift"))
      XCTAssertFalse(source.contains("Settings.Container("), name)
      XCTAssertFalse(source.contains("Settings.Section("), name)
      XCTAssertTrue(source.contains("SettingsLayout.form {"), "\(name): page is one shared grid")
      XCTAssertTrue(source.contains("SettingsLayout.row("), name)
      XCTAssertFalse(source.contains(".frame(width: 141"), "\(name): pickers share SettingsLayout.pickerWidth")
    }

    let layout = try String(contentsOf: settingsRoot.appendingPathComponent("SettingsLayout.swift"))
    XCTAssertFalse(layout.contains("Divider()"), "settings groups use spacing, not decorative separators")
  }

  /// Unlabeled controls belong to the control column of the same grid, so they
  /// start on the same x as labeled controls. The old contract centered them
  /// in a separate 240pt column, which left checkboxes floating between columns.
  func testUnlabeledControlsShareTheControlColumn() throws {
    let layout = try String(contentsOf: settingsRoot.appendingPathComponent("SettingsLayout.swift"))
    XCTAssertTrue(layout.contains("Grid(alignment: .leading"), "one two-column grid per page")
    XCTAssertTrue(layout.contains(".gridColumnAlignment(.trailing)"), "labels are right-aligned")
    XCTAssertTrue(layout.contains(".gridCellUnsizedAxes([.horizontal, .vertical])"),
                  "an unlabeled row leaves the label cell empty instead of building its own column")
    XCTAssertFalse(layout.contains("standaloneContentWidth"), "no separate centered column")
    XCTAssertFalse(layout.contains(".offset("), "alignment comes from the grid, not offsets")
  }

  func testAppearanceGroupsByMeaningAndIndentsDependentOption() throws {
    let source = try String(contentsOf: settingsRoot.appendingPathComponent("AppearanceSettingsPane.swift"))
    for key in ["\"Panel\"", "\"Items\"", "\"MenuBar\""] {
      XCTAssertTrue(source.contains("SettingsLayout.row(\(key)"), "missing group label \(key)")
    }
    XCTAssertTrue(source.contains("SettingsLayout.dependent {"), "recent copy depends on the menu icon")
    for table in ["en", "zh-Hans"] {
      let strings = try String(contentsOf: settingsRoot.appendingPathComponent("\(table).lproj/AppearanceSettings.strings"))
      for key in ["Panel", "Items", "MenuBar"] {
        XCTAssertTrue(strings.contains("\"\(key)\" = "), "\(table) missing \(key)")
      }
    }
  }

  /// Text inputs share the panel's translucent field skin. A bare TextField,
  /// the stock shortcut recorder, or an opaque control background paints a
  /// solid box on the glass shell while pop-ups next to it stay translucent.
  func testTextInputsUseTheTranslucentFieldSkin() throws {
    for name in ["General", "Storage", "Privacy", "Appearance", "Advanced"] {
      let source = try String(contentsOf: settingsRoot.appendingPathComponent("\(name)SettingsPane.swift"))
      XCTAssertFalse(source.contains("TextField("), "\(name): use SettingsNumberField")
      XCTAssertFalse(source.contains("KeyboardShortcuts.Recorder("), "\(name): use SettingsShortcutRecorder")
      XCTAssertFalse(source.contains("controlBackgroundColor"), "\(name): use SettingsFieldChrome.fill")
      XCTAssertFalse(source.contains("windowBackgroundColor"), "\(name): the window is glass")
    }
    let layout = try String(contentsOf: settingsRoot.appendingPathComponent("SettingsLayout.swift"))
    let shared = try String(contentsOf: settingsRoot.deletingLastPathComponent().appendingPathComponent("Views/VisualEffectView.swift"))
    XCTAssertTrue(shared.contains(".textFieldStyle(.plain)"))
    XCTAssertTrue(layout.contains("recorder.drawsBackground = false"))
    XCTAssertTrue(layout.contains("recorder.isBezeled = false"))
  }

  /// Windows laid out by someone else (Sparkle, the about panel) keep their
  /// geometry; only the frame turns transparent and the glass goes under it.
  @MainActor
  func testGlassShellAdoptsAForeignWindowOnce() throws {
    let window = NSWindow(
      contentRect: NSRect(x: -24000, y: -24000, width: 300, height: 120),
      styleMask: [.titled, .closable], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let content = try XCTUnwrap(window.contentView)
    let before = content.frame
    XCTAssertTrue(GlassShell.adopt(window))
    XCTAssertFalse(GlassShell.adopt(window), "adopting twice must not stack glass")
    XCTAssertFalse(window.isOpaque)
    XCTAssertTrue(window.titlebarAppearsTransparent)
    XCTAssertEqual(window.titlebarSeparatorStyle, .none)
    XCTAssertEqual(content.frame, before, "layout is not touched")
    let frameView = try XCTUnwrap(content.superview)
    let glass = try XCTUnwrap(frameView.subviews.first)
    XCTAssertEqual(glass.accessibilityIdentifier(), GlassShell.backgroundIdentifier, "glass sits under everything")
    XCTAssertEqual(glass.frame, frameView.bounds, "glass covers the title bar too")
  }

  @MainActor
  func testGlassShellUsesTheContentViewOfAFullSizeWindow() throws {
    let window = NSWindow(
      contentRect: NSRect(x: -24000, y: -24000, width: 300, height: 120),
      styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    XCTAssertTrue(GlassShell.adopt(window))
    let content = try XCTUnwrap(window.contentView)
    XCTAssertEqual(content.subviews.first?.accessibilityIdentifier(), GlassShell.backgroundIdentifier)
  }

  func testSparkleWindowsAndAboutPanelWearTheGlassShell() throws {
    let root = settingsRoot.deletingLastPathComponent()
    let updater = try String(contentsOf: root.appendingPathComponent("SoftwareUpdater.swift"))
    XCTAssertTrue(updater.contains("userDriverDelegate: windowGlass"), "Sparkle's driver reports to the glass adopter")
    XCTAssertTrue(updater.contains("GlassShell.adopt(window)"))
    let about = try String(contentsOf: root.appendingPathComponent("About.swift"))
    XCTAssertTrue(about.contains("GlassShell.adopt(panel)"))
  }

  /// Every text field the app draws (settings, tag and snippet popovers) uses
  /// the shared glass skin. A default bezeled field, a rounded-border SwiftUI
  /// field, or an opaque system background paints a solid box.
  func testNoOpaqueTextFieldsAnywhereInTheApp() throws {
    let app = settingsRoot.deletingLastPathComponent()
    let files = try XCTUnwrap(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil))
      .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    XCTAssertGreaterThan(files.count, 50)
    for file in files {
      let source = try String(contentsOf: file)
      let name = file.lastPathComponent
      XCTAssertFalse(source.contains(".roundedBorder"), "\(name): use .glassTextField()")
      XCTAssertFalse(source.contains(".roundedBezel"), "\(name): use GlassTextField")
      XCTAssertFalse(source.contains("NSTextField(string:"), "\(name): use GlassTextField")
      XCTAssertFalse(source.contains("NSColor.textBackgroundColor"), "\(name): opaque fill on glass")
      XCTAssertFalse(source.contains("NSColor.controlBackgroundColor"), "\(name): opaque fill on glass")
    }
  }

  @MainActor
  func testGlassTextFieldHasNoBezelAndTheSharedHeight() {
    let field = GlassTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
    XCTAssertTrue(field.cell is GlassFieldCell)
    XCTAssertFalse(field.isBezeled)
    XCTAssertFalse(field.drawsBackground)
    XCTAssertTrue(field.isEditable)
    XCTAssertEqual(field.alignmentRectInsets.left, 0)
    XCTAssertEqual(field.alignmentRectInsets.right, 0)
    XCTAssertEqual(field.intrinsicContentSize.height, GlassField.height)
    let drawing = field.cell!.drawingRect(forBounds: field.bounds)
    XCTAssertGreaterThanOrEqual(drawing.minX, GlassField.horizontalPadding, "text does not touch the edge")
  }

  /// Licenses must read offline and match the shipped build, not a web page.
  func testAboutLicensesShipInTheBundle() throws {
    let url = try XCTUnwrap(AboutInfo.acknowledgements)
    let text = try String(contentsOf: url, encoding: .utf8)
    for name in ["Maccy", "Sparkle", "KeyboardShortcuts", "Defaults", "LaunchAtLogin", "Sauce", "Fuse",
                 "SwiftHEXColors", "swift-log", "Apache License", "Permission is hereby granted"] {
      XCTAssertTrue(text.contains(name), name)
    }
    XCTAssertFalse(AboutInfo.minimumSystem.isEmpty)
  }

  func testAboutShowsBuildLinksAndLicenses() throws {
    let about = try String(contentsOf: settingsRoot.deletingLastPathComponent().appendingPathComponent("About.swift"))
    for key in ["about_version", "about_tagline", "about_summary", "about_check_updates", "about_release_notes",
                "about_source", "about_feedback", "about_copyright", "about_licenses", "CFBundleVersion"] {
      XCTAssertTrue(about.contains(key), key)
    }
    for lang in ["en", "zh-Hans"] {
      let strings = try String(contentsOf: settingsRoot.deletingLastPathComponent()
        .appendingPathComponent("\(lang).lproj/Localizable.strings"))
      for key in ["about_version", "about_tagline", "about_check_updates", "about_licenses_help", "about_requirement"] {
        XCTAssertTrue(strings.contains("\"\(key)\" = "), "\(lang) \(key)")
      }
    }
  }

  /// Sparkle's "up to date" and error alerts are app-modal at modalPanel
  /// level. A window above that level hides the alert while the modal session
  /// blocks the window's own close button, which reads as a frozen window.
  func testAboutStaysBelowSparkleModalAlerts() throws {
    let root = settingsRoot.deletingLastPathComponent()
    let about = try String(contentsOf: root.appendingPathComponent("About.swift"))
    XCTAssertFalse(about.contains("popUpMenuWindow"), "about must not float above modal alerts")
    XCTAssertTrue(about.contains("panel.level = .normal"))
    XCTAssertTrue(about.contains("yieldPanelBelowSettings()"), "the clipboard panel steps down instead")
    XCTAssertLessThan(NSWindow.Level.normal.rawValue, NSWindow.Level.modalPanel.rawValue)
    let app = try String(contentsOf: root.appendingPathComponent("Observables/AppState.swift"))
    XCTAssertTrue(app.contains("guard !about.isVisible, settingsWindowController?.window?.isVisible != true"),
                  "the panel returns only when neither settings nor about is open")
  }
}
