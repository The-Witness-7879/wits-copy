import AppKit
import Defaults
import SwiftUI
import XCTest
@testable import WitsCopy

/// 真实叶子组件的离屏布局与原生按钮路径，不启动应用，不读写系统剪贴板。
@MainActor
final class WorkspaceTagUITests: XCTestCase {
  private var window: NSWindow?
  private var oldStyles: [String: WorkspaceTagStyle] = [:]
  private var oldCompact = false
  private var oldIcons = false
  private var oldFilter: String?

  override func setUp() {
    super.setUp()
    oldStyles = Defaults[.workspaceTagStyles]
    oldCompact = Defaults[.compactRows]
    oldIcons = Defaults[.showApplicationIcons]
    oldFilter = AppState.shared.history.tagFilter
    Defaults[.workspaceTagStyles] = [:]
    Defaults[.compactRows] = false
    Defaults[.showApplicationIcons] = false
    AppState.shared.history.tagFilter = nil
  }

  override func tearDown() {
    window?.close()
    window = nil
    Defaults[.workspaceTagStyles] = oldStyles
    Defaults[.compactRows] = oldCompact
    Defaults[.showApplicationIcons] = oldIcons
    AppState.shared.history.tagFilter = oldFilter
    super.tearDown()
  }

  func testShortTagKeepsItsNameBeforeALongSourceAtNarrowWidths() throws {
    for width in [240.0, 300.0, 460.0] {
      let id = UUID()
      let host = mount(row(id: id, tag: "12345", source: "An Application With An Extremely Long Name · Text"), width: width, height: 80)
      let tag = try rect("lab-row-category-12345", in: host)
      let source = try rect("lab-row-source-\(id.uuidString)", in: host)
      XCTAssertGreaterThanOrEqual(tag.width, 50, "短标签不应被长应用名挤成一个点")
      XCTAssertLessThan(tag.maxX, source.minX)
      XCTAssertLessThanOrEqual(source.maxX, width - HistoryRowMetrics.pinWidth - HistoryRowMetrics.shortcutWidth + 1)
      let natural = tag.width
      let short = mount(row(id: id, tag: "12345", source: "App · Text"), width: width, height: 80)
      XCTAssertEqual(try rect("lab-row-category-12345", in: short).width, natural, accuracy: 0.5)
    }
  }

  func testLongTagIsBoundedAndUnlabelledRowsDoNotReserveABadgeSlot() throws {
    let long = String(repeating: "标签", count: 16)
    let id = UUID()
    let host = mount(row(id: id, tag: long), width: 280, height: 80)
    let tag = try rect("lab-row-category-\(long)", in: host)
    let source = try rect("lab-row-source-\(id.uuidString)", in: host)
    XCTAssertLessThanOrEqual(tag.width, 144)
    XCTAssertGreaterThan(tag.width, 50)
    XCTAssertGreaterThan(source.width, 0)
    XCTAssertGreaterThan(source.minX, tag.maxX)
    let plainID = UUID()
    let plain = mount(row(id: plainID, tag: nil), width: 280, height: 80)
    XCTAssertNil(find("lab-row-category-\(long)", in: plain))
    let caption = try rect("lab-row-source-\(plainID.uuidString)", in: plain)
    XCTAssertEqual(caption.minX, 10, accuracy: 0.5)
  }

  func testFilteredCategoryDoesNotRepeatItsNameButCompactRowsKeepReadableTags() throws {
    AppState.shared.history.tagFilter = "WORK"
    let filtered = mount(row(tag: "work"), width: 320, height: 80)
    XCTAssertNil(find("lab-row-category-work", in: filtered))
    AppState.shared.history.tagFilter = nil
    Defaults[.compactRows] = true
    let compact = mount(row(tag: "work"), width: 320, height: 80)
    let tag = try rect("lab-row-category-work", in: compact)
    XCTAssertGreaterThan(tag.width, 40, "紧凑模式也不能退回只有颜色的圆点")
    XCTAssertGreaterThan(tag.height, 10)
  }

  func testImageRowsKeepTagAndSourceInsideTheExistingRowHeight() throws {
    let image = NSImage(size: NSSize(width: 300, height: 150))
    let id = UUID()
    let host = mount(row(id: id, tag: "work", image: image), width: 320, height: 60)
    let tag = try rect("lab-row-category-work", in: host)
    let preview = try rect("lab-row-preview-\(id.uuidString)", in: host)
    let source = try rect("lab-row-source-\(id.uuidString)", in: host)
    XCTAssertGreaterThan(tag.width, 40)
    XCTAssertLessThan(tag.maxX, source.minX)
    XCTAssertGreaterThan(preview.height, 20)
    XCTAssertLessThan(preview.height, HistoryRowMetrics.contentHeight)
    XCTAssertLessThanOrEqual(max(tag.maxY, preview.maxY), host.bounds.maxY + 0.5)
    XCTAssertGreaterThanOrEqual(min(tag.minY, preview.minY), host.bounds.minY - 0.5)
  }

  func testCompactImagesKeepFullThumbnailHeightBesideTheTagName() throws {
    Defaults[.compactRows] = true
    let id = UUID()
    let image = NSImage(size: NSSize(width: 300, height: 150))
    let host = mount(row(id: id, tag: "work", image: image), width: 320, height: Popup.itemHeight)
    let tag = try rect("lab-row-category-work", in: host)
    let preview = try rect("lab-row-preview-\(id.uuidString)", in: host)
    XCTAssertEqual(preview.height, Popup.itemHeight, accuracy: 0.5)
    XCTAssertGreaterThan(tag.width, 40)
    XCTAssertLessThan(tag.maxX, preview.minX)
    XCTAssertEqual(tag.midY, preview.midY, accuracy: 1)
  }

  func testPickerPersistsChoicesAndIsCompact() throws {
    var host = mount(WorkspaceTagAppearancePopover(tag: "work"), width: 300, height: 300)
    let size = host.fittingSize
    XCTAssertLessThanOrEqual(size.width, 250)
    XCTAssertLessThanOrEqual(size.height, 150)
    try press("lab-tag-symbol-folder.fill", in: host)
    try press("lab-tag-color-5", in: host)
    XCTAssertEqual(WorkspaceTagAppearance.style(for: "WORK", in: Defaults[.workspaceTagStyles]),
                   WorkspaceTagStyle(symbol: "folder.fill", colorIndex: 5))
    host = mount(WorkspaceTagAppearancePopover(tag: "WORK"), width: 300, height: 300)
    XCTAssertEqual(try button("lab-tag-symbol-folder.fill", in: host).accessibilityValue() as? String, "selected")
    XCTAssertEqual(try button("lab-tag-color-5", in: host).accessibilityValue() as? String, "selected")
    try press("lab-tag-symbol-dot", in: host)
    try press("lab-tag-color-auto", in: host)
    XCTAssertEqual(Defaults[.workspaceTagStyles], [:])
  }

  func testEarlierOutlineChoiceAndKeptColorStaySelected() throws {
    Defaults[.workspaceTagStyles] = ["work": WorkspaceTagStyle(symbol: "folder", colorIndex: 10)]
    let host = mount(WorkspaceTagAppearancePopover(tag: "work"), width: 300, height: 300)
    XCTAssertEqual(try button("lab-tag-symbol-folder.fill", in: host).accessibilityValue() as? String, "selected")
    XCTAssertEqual(try button("lab-tag-color-10", in: host).accessibilityValue() as? String, "selected")
    let ids = ["lab-tag-symbol-dot", "lab-tag-color-auto", "lab-tag-color-10"]
      + WorkspaceTagAppearance.symbols.map { "lab-tag-symbol-\($0)" }
      + WorkspaceTagAppearance.selectableColorIndices.map { "lab-tag-color-\($0)" }
    for id in ids {
      let tip = try button(id, in: host).toolTip ?? ""
      XCTAssertFalse(tip.isEmpty || tip.hasPrefix("tag_"), id)
    }
  }

  private func row(id: UUID = UUID(), tag: String?, source: String = "App · Text", image: NSImage? = nil) -> some View {
    ListItemView(
      id: id, selectionId: id, appIcon: nil, image: image,
      attributedTitle: nil, shortcuts: [], isSelected: false,
      subtitle: source, previewSlotID: id.uuidString, categoryTag: tag
    ) {
      Text(verbatim: "Hello, 世界！")
    }
  }

  private func mount<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> NSView {
    window?.close()
    let window = NSWindow(contentRect: NSRect(x: -24000, y: -24000, width: width, height: height),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: view.environment(AppState.shared).environment(ModifierFlags()))
    host.sizingOptions = []
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    window.contentView = host
    self.window = window
    drain()
    host.layoutSubtreeIfNeeded()
    XCTAssertFalse(window.isVisible)
    return host
  }

  private func drain() { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }

  private func find(_ id: String, in view: NSView) -> NSView? {
    if view.accessibilityIdentifier() == id { return view }
    return view.subviews.lazy.compactMap { self.find(id, in: $0) }.first
  }

  private func rect(_ id: String, in host: NSView) throws -> CGRect {
    let view = try XCTUnwrap(find(id, in: host), "missing \(id)")
    return view.convert(view.bounds, to: host)
  }

  private func button(_ id: String, in host: NSView) throws -> ImmediateActionButton {
    try XCTUnwrap(find(id, in: host) as? ImmediateActionButton, "missing \(id)")
  }

  private func press(_ id: String, in host: NSView) throws {
    XCTAssertTrue(try button(id, in: host).accessibilityPerformPress())
    drain()
    host.layoutSubtreeIfNeeded()
  }
}
