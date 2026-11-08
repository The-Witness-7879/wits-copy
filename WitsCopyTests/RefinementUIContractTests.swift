import XCTest
@testable import WitsCopy

final class RefinementUIContractTests: XCTestCase {
  func testToolStripPlacesWrapLeftAndOCRRightAndOmitsInapplicableKinds() {
    XCTAssertEqual(PreviewToolStrip.tools(kind: "plain"), [.wrap])
    XCTAssertEqual(PreviewToolStrip.tools(kind: "code"), [.wrap, .lineNumbers])
    XCTAssertEqual(PreviewToolStrip.tools(kind: "image"), [.recognize])
    XCTAssertEqual(PreviewToolStrip.tools(kind: "gif"), [.recognize])
    XCTAssertEqual(PreviewToolStrip.tools(kind: "missing"), [])
    XCTAssertFalse(PreviewToolStrip.tools(kind: "plain").contains(.recognize))
    XCTAssertEqual(PreviewToolStrip.tools(kind: "image").first, .recognize)
    let pdf = PreviewToolStrip.tools(kind: "pdf")
    XCTAssertTrue(pdf.contains(.pdfZoomOut))
    XCTAssertFalse(pdf.contains(.wrap))
  }

  func testDeleteConfirmationDefaultsOnAndUsesItsOwnKey() {
    XCTAssertTrue(DeleteItemConfirmation.shouldPrompt(suppressed: false))
    XCTAssertFalse(DeleteItemConfirmation.shouldPrompt(suppressed: true))
    XCTAssertEqual(DeleteItemConfirmation.suppressKeyName, "suppressDeleteItemAlert")
    XCTAssertNotEqual(DeleteItemConfirmation.suppressKeyName, "suppressClearAlert")
    XCTAssertNotEqual(DeleteItemConfirmation.suppressKeyName, "suppressQuitAlert")
  }

  func testBodySaveStripsRichAndTitleOrCancelDoesNot() {
    XCTAssertFalse(RichRepresentation.isRich("public.utf8-plain-text"))
    XCTAssertFalse(RichRepresentation.isRich("NSStringPboardType"))
  }

}
