import AppKit
import Defaults
import XCTest
@testable import WitsCopy

/// 标签外观：解析、回退和随分类变化的生命周期。
final class WorkspaceTagAppearanceTests: XCTestCase {
  private var previous: [String: WorkspaceTagStyle] = [:]

  override func setUpWithError() throws {
    try super.setUpWithError()
    guard LabRuntime.isIsolated, Defaults.Keys.workspaceTagStyles.suite !== UserDefaults.standard else {
      throw XCTSkip("appearance tests only run against the isolated preferences suite")
    }
    previous = Defaults[.workspaceTagStyles]
    Defaults[.workspaceTagStyles] = [:]
  }

  override func tearDown() {
    Defaults[.workspaceTagStyles] = previous
    super.tearDown()
  }

  func testCuratedSymbolsAreSolidAndLoad() {
    XCTAssertEqual(WorkspaceTagAppearance.symbols.count, 26, "dot plus 26 shapes fill three rows of nine")
    XCTAssertEqual(Set(WorkspaceTagAppearance.symbols).count, 26)
    for symbol in WorkspaceTagAppearance.symbols {
      XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
      XCTAssertTrue(symbol.hasSuffix(".fill") || symbol == "music.note", "\(symbol) is an outline glyph")
    }
  }

  func testResolutionFallsBackAndMapsEarlierOutlineNames() {
    XCTAssertEqual(WorkspaceTagAppearance.style(for: "work", in: [:]), WorkspaceTagStyle())
    XCTAssertEqual(WorkspaceTagAppearance.color(for: "work", style: WorkspaceTagStyle()), WorkspaceTagDot.color(for: "work"))
    XCTAssertEqual(WorkspaceTagAppearance.style(for: "Work", in: ["work": WorkspaceTagStyle(symbol: "book")]),
                   WorkspaceTagStyle(symbol: "book.fill"))
    XCTAssertEqual(WorkspaceTagAppearance.style(for: "work", in: ["work": WorkspaceTagStyle(symbol: "nope", colorIndex: 99)]),
                   WorkspaceTagStyle())
    XCTAssertEqual(WorkspaceTagAppearance.setting(WorkspaceTagStyle(), for: "work", in: ["work": WorkspaceTagStyle(colorIndex: 2)]),
                   [:], "restoring both defaults removes the override")
  }

  func testRenameKeepsLookButUnchangedConfirmWritesNothing() {
    XCTAssertEqual(WorkspaceTagAppearance.renaming([:], from: "work", to: "work", merging: false), [:])
    let renamed = WorkspaceTagAppearance.renaming([:], from: "old", to: "fresh", merging: false)
    XCTAssertEqual(WorkspaceTagAppearance.color(for: "fresh", style: WorkspaceTagAppearance.style(for: "fresh", in: renamed)),
                   WorkspaceTagDot.color(for: "old"), "renaming must not change the color")
  }

  func testMergeByEitherEntryKeepsTargetAndDeleteForgets() throws {
    let target = WorkspaceTagStyle(symbol: "folder.fill", colorIndex: 5)
    for merging in [true, false] {
      Defaults[.workspaceTagStyles] = ["source": WorkspaceTagStyle(symbol: "star.fill"), "target": target]
      try WorkspaceTagDirectoryActions.rename(
        from: "source", to: "TARGET", merging: merging, itemTagsAfter: { ["target"] },
        renameHistory: { true }, rollbackHistory: { _ in false },
        writer: Directory(names: ["source", "target"])
      ).get()
      XCTAssertEqual(Defaults[.workspaceTagStyles], ["target": target])
    }
    try WorkspaceTagDirectoryActions.delete(named: "target", itemTags: [], deleteHistory: { true },
                                            writer: Directory(names: ["target"])).get()
    XCTAssertEqual(Defaults[.workspaceTagStyles], [:])
  }

  func testFailedRenameLeavesAppearanceAlone() {
    let before = ["old": WorkspaceTagStyle(symbol: "star.fill")]
    Defaults[.workspaceTagStyles] = before
    let result = WorkspaceTagDirectoryActions.rename(
      from: "old", to: "fresh", itemTagsAfter: { ["fresh"] }, renameHistory: { true },
      rollbackHistory: { _ in true }, writer: Directory(names: ["old"], accepts: false)
    )
    guard case .failure(.persistFailed) = result else { return XCTFail("expected persistFailed, got \(result)") }
    XCTAssertEqual(Defaults[.workspaceTagStyles], before)
  }
}

private final class Directory: WorkspaceTagDirectoryWriting {
  var names: [String]
  let accepts: Bool
  init(names: [String], accepts: Bool = true) {
    self.names = names
    self.accepts = accepts
  }
  func loadNames() -> [String] { names }
  func saveNames(_ names: [String]) -> Bool {
    if accepts { self.names = names }
    return accepts
  }
}
