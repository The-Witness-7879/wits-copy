import AppKit
import XCTest
@testable import WitsCopy

/// Layout, dot, and drop contracts for the tag rail. Does not order a window front or activate the app.
final class WorkspaceRailContractTests: XCTestCase {
  func testFlowKeepsTheAddButtonImmediatelyAfterTheBoxWhenThereAreNoTags() {
    XCTAssertEqual(WorkspaceSection.primaryRail.count, 1)
  }

  func testNewTagIsInsertedBetweenTheBoxAndTheAddButton() throws {
    let stored = try WorkspaceTagDirectory.inserting("beta", into: ["solo"], itemTags: []).get()
    XCTAssertEqual(stored, ["solo", "beta"])
    XCTAssertEqual(WorkspaceTagDirectory.ordered(stored: ["solo"], itemTags: []), ["solo"])
  }

  func testDotColorIsStableAndIndependentOfOrder() {
    XCTAssertEqual(WorkspaceTagDot.index(for: "Work"), WorkspaceTagDot.index(for: "work"))
    XCTAssertEqual(WorkspaceTagDot.index(for: "工作"), WorkspaceTagDot.index(for: "工作"))
    XCTAssertNotEqual(WorkspaceTagDot.index(for: "alpha"), WorkspaceTagDot.index(for: "zeta"))
    let alone = WorkspaceTagDot.index(for: "alpha")
    XCTAssertEqual(alone, WorkspaceTagDot.index(for: "alpha"))
    XCTAssertGreaterThanOrEqual(WorkspaceRailMetrics.hit, 35)
  }

  func testSelectionAndDropFeedbackDoNotReplaceEachOther() {
    XCTAssertEqual(WorkspaceRailFeedback.accessibilityValue(selected: false, dropTarget: false), "")
    XCTAssertEqual(WorkspaceRailFeedback.accessibilityValue(selected: true, dropTarget: false), "selected")
    XCTAssertEqual(WorkspaceRailFeedback.accessibilityValue(selected: false, dropTarget: true), "drop-target")
    XCTAssertEqual(
      WorkspaceRailFeedback.accessibilityValue(selected: true, dropTarget: true),
      "selected drop-target"
    )
    XCTAssertTrue(WorkspaceDropHighlight.highlighted(after: .entered(true)))
    XCTAssertFalse(WorkspaceDropHighlight.highlighted(after: .entered(false)))
    XCTAssertFalse(WorkspaceDropHighlight.highlighted(after: .exited))
    XCTAssertFalse(WorkspaceDropHighlight.highlighted(after: .performed))
    XCTAssertFalse(WorkspaceDropHighlight.highlighted(after: .concluded))
    XCTAssertFalse(WorkspaceDropHighlight.highlighted(after: .ended))
    let operation = WorkspaceDropHighlight.operation(allowed: true)
    XCTAssertEqual(operation, .copy)
    XCTAssertFalse(operation.contains(.move))
    XCTAssertFalse(operation.contains(.delete))
    XCTAssertEqual(WorkspaceDropHighlight.operation(allowed: false), [])
    XCTAssertFalse(WorkspaceItemDrag.sourceOperation(withinApplication: true).contains(.move))
  }

  func testRailSourceUsesTheTopFlowAndDoesNotDrawLetterGlyphs() throws {
    let rail = try labSource("WitsCopy/WorkspaceManagementView.swift")
    let box = try XCTUnwrap(rail.range(of: "WorkspaceSection.primaryRail"))
    let tags = try XCTUnwrap(rail.range(of: "ForEach(tags, id:"))
    let add = try XCTUnwrap(rail.range(of: "lab-rail-add-tag"))
    XCTAssertLessThan(box.lowerBound, tags.lowerBound)
    XCTAssertLessThan(tags.lowerBound, add.lowerBound)
    let flowStart = try XCTUnwrap(rail.range(of: "VStack(alignment: .leading, spacing: WorkspaceRailFlow.spacing)"))
    let flowEnd = try XCTUnwrap(rail.range(of: ".padding(.vertical, WorkspaceRailFlow.verticalPadding)"))
    let flow = String(rail[flowStart.lowerBound..<flowEnd.lowerBound])
    XCTAssertFalse(flow.contains("Spacer("), "the vertical rail flow must not pin the add button")
    XCTAssertFalse(rail.contains("layoutPriority"))
    XCTAssertFalse(rail.contains("WorkspaceRailPolicy.glyph"))
    XCTAssertFalse(rail.contains("glyph:"))
    XCTAssertTrue(rail.contains("WorkspaceRailFeedback.accessibilityValue"))
    XCTAssertTrue(rail.contains(".frame(width: rowWidth, height: WorkspaceRailMetrics.hit"))
    XCTAssertTrue(rail.contains("applyCategoryDrop"))
    let drag = try labSource("WitsCopy/WorkspaceTagRail.swift")
    XCTAssertTrue(drag.contains("override func draggingEnded"))
    XCTAssertTrue(drag.contains("draggingExited"))
    XCTAssertTrue(drag.contains("performDragOperation"))
    XCTAssertTrue(drag.contains("concludeDragOperation"))
    XCTAssertTrue(drag.contains("draggingEntered"))
    XCTAssertTrue(drag.contains("WorkspaceItemDrag.draggingImage"))
  }

  @MainActor
  func testClosedTagFormLeavesNoBlockerInTheHitChainWithoutShowingTheWindow() {
    let window = NSWindow(
      contentRect: NSRect(x: -24000, y: -24000, width: 640, height: 400),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    let hosting = ProbeNSHostingView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    hosting.setAccessibilityIdentifier("hosting")
    window.contentView = hosting
    let anchor = NSView(frame: NSRect(x: 1, y: 40, width: 35, height: 35))
    hosting.addSubview(anchor)
    let controller = WorkspaceTagCreateController()
    controller.present(
      from: anchor,
      onCommit: { _ in nil },
      onCancel: {}
    )
    XCTAssertFalse(window.isVisible)
    XCTAssertFalse(window.isKeyWindow)
    XCTAssertEqual(window.contentView?.accessibilityIdentifier(), "hosting")
    XCTAssertNil(window.contentView?.subviews.first { $0.accessibilityIdentifier() == "lab-tag-form-blocker" })
    XCTAssertEqual(window.contentView?.hitTest(NSPoint(x: 20, y: 20))?.accessibilityIdentifier(), "hosting")
    controller.dismiss(cancelled: false)
    XCTAssertNil(window.contentView?.subviews.first { $0.accessibilityIdentifier() == "lab-tag-form-blocker" })
    XCTAssertNil(window.contentView?.subviews.first { $0.accessibilityIdentifier() == "lab-rail-new-tag-form" })
    XCTAssertEqual(window.contentView?.hitTest(NSPoint(x: 20, y: 20))?.accessibilityIdentifier(), "hosting")
    XCTAssertFalse(controller.isPresented)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    XCTAssertNil(window.contentView?.subviews.first { $0.accessibilityIdentifier() == "lab-tag-form-blocker" })
    XCTAssertFalse(window.isVisible)
    XCTAssertFalse(window.isKeyWindow)
    window.close()
  }

  func testExpandedListSpanGrowsWithoutShrinkingTheListColumn() {
    let controller = SlideoutController()
    controller.layoutListWidth = 520
    let narrow = controller.listSpan(railVisible: false, railWidth: PanelSplit.navigationRailWidth)
    let expanded = controller.listSpan(
      railVisible: true,
      railWidth: 108
    )
    let extra = 108 - PanelSplit.navigationRailWidth
    XCTAssertEqual(narrow, 520)
    // 左栏向外展开：这一跨多出 72pt，条目列本身一点不让。
    XCTAssertEqual(expanded, 520 + extra)
    XCTAssertEqual(controller.layoutListWidth, 520)
    XCTAssertEqual(expanded - narrow, extra)
  }

  private func labSource(_ relative: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(contentsOf: root.appending(path: relative), encoding: .utf8)
  }
}

/// Class name contains `NSHostingView`, so `WorkspaceTagCreateController` takes the real shell-wrap path.
private final class ProbeNSHostingView: NSView {}
