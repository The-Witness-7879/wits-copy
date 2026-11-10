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

  // MARK: - Whole-text open target

  private var everyPathExists: PreviewOpenTarget.FileProbe {
    PreviewOpenTarget.FileProbe(exists: { _ in true }, isDirectory: { _ in false })
  }

  func testWholeWebURLsResolve() {
    guard case .web(let https)? = PreviewOpenTarget.resolve(
      "https://example.com/a?b=1#c",
      probe: everyPathExists
    ) else {
      return XCTFail("https URL did not resolve")
    }
    XCTAssertEqual(https.scheme, "https")
    XCTAssertEqual(https.host, "example.com")
    XCTAssertEqual(https.absoluteString, "https://example.com/a?b=1#c")

    guard case .web(let http)? = PreviewOpenTarget.resolve("http://example.com", probe: everyPathExists) else {
      return XCTFail("http URL did not resolve")
    }
    XCTAssertEqual(http.scheme, "http")
    XCTAssertEqual(http.host, "example.com")
  }

  func testSurroundingWhitespaceIsTrimmedBeforeMatching() {
    guard case .web(let url)? = PreviewOpenTarget.resolve("  https://example.com\n\n", probe: everyPathExists) else {
      return XCTFail("a URL padded with whitespace did not resolve")
    }
    XCTAssertEqual(url.host, "example.com")
    XCTAssertNil(PreviewOpenTarget.resolve(" \n\t ", probe: everyPathExists))
    XCTAssertNil(PreviewOpenTarget.resolve(nil, probe: everyPathExists))
  }

  func testProsePartialLinksAndOtherSchemesAreNotTargets() {
    let rejected = [
      "hello world",
      "Please see https://example.com for details",
      "see https://example.com",
      "www.example.com",
      "example.com",
      "mailto:someone@example.com",
      "ftp://example.com/file",
      "custom-scheme://example.com",
      "https://example.com\nsecond line",
      "https://",
      "relative/path.txt",
      "../notes.txt",
      "file://"
    ]
    for text in rejected {
      XCTAssertNil(PreviewOpenTarget.resolve(text, probe: everyPathExists), "recognised: \(text)")
    }
  }

  func testAbsoluteTildeAndFileURLPathsResolveAsFiles() {
    let plain = "/tmp/notes.txt"
    XCTAssertEqual(
      PreviewOpenTarget.resolve(plain, probe: everyPathExists),
      .file(URL(fileURLWithPath: plain), isDirectory: false)
    )

    let tilde = "~/Desktop/notes.txt"
    let expanded = (tilde as NSString).expandingTildeInPath
    XCTAssertEqual(
      PreviewOpenTarget.resolve(tilde, probe: everyPathExists),
      .file(URL(fileURLWithPath: expanded), isDirectory: false)
    )

    let fileURL = URL(fileURLWithPath: plain)
    XCTAssertEqual(
      PreviewOpenTarget.resolve(fileURL.absoluteString, probe: everyPathExists),
      .file(fileURL, isDirectory: false)
    )
  }

  func testFilesAndDirectoriesAreDistinguished() {
    let probe = PreviewOpenTarget.FileProbe(
      exists: { _ in true },
      isDirectory: { $0.path.hasSuffix("/Folder") }
    )
    guard case .file(let folderURL, let folderIsDirectory)? = PreviewOpenTarget.resolve("/tmp/Folder", probe: probe) else {
      return XCTFail("directory path did not resolve")
    }
    XCTAssertEqual(folderURL.path, "/tmp/Folder")
    XCTAssertTrue(folderIsDirectory)

    guard case .file(let fileURL, let fileIsDirectory)? = PreviewOpenTarget.resolve("/tmp/Folder/note.txt", probe: probe) else {
      return XCTFail("file path did not resolve")
    }
    XCTAssertEqual(fileURL.path, "/tmp/Folder/note.txt")
    XCTAssertFalse(fileIsDirectory)
  }

  func testOnlyPathsThatExistOnDiskResolve() throws {
    let manager = FileManager.default
    let base = manager.temporaryDirectory.appendingPathComponent("witscopy-open-\(UUID().uuidString)")
    try manager.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: base) }
    let file = base.appendingPathComponent("note.txt")
    try "note".write(to: file, atomically: true, encoding: .utf8)

    guard case .file(let directoryURL, let directoryIsDirectory)? = PreviewOpenTarget.resolve(base.path) else {
      return XCTFail("an existing directory did not resolve")
    }
    XCTAssertEqual(directoryURL.path, base.path)
    XCTAssertTrue(directoryIsDirectory)

    guard case .file(let fileURL, let fileIsDirectory)? = PreviewOpenTarget.resolve(file.path) else {
      return XCTFail("an existing file did not resolve")
    }
    XCTAssertEqual(fileURL.path, file.path)
    XCTAssertFalse(fileIsDirectory)

    guard case .file(_, let fileURLIsDirectory)? = PreviewOpenTarget.resolve(file.absoluteString) else {
      return XCTFail("an existing file:// URL did not resolve")
    }
    XCTAssertFalse(fileURLIsDirectory)

    XCTAssertNil(PreviewOpenTarget.resolve(base.appendingPathComponent("missing.txt").path))
    XCTAssertNil(PreviewOpenTarget.resolve("~/this-home-path-\(UUID().uuidString)"))
    XCTAssertNil(PreviewOpenTarget.resolve(file.absoluteString + "?ignored=1"))
  }

  func testOpenTargetClosesPanelBeforeExternalHandoff() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: root.appendingPathComponent("WitsCopy/Views/PreviewItemView.swift"),
      encoding: .utf8
    )
    let functionStart = try XCTUnwrap(source.range(of: "private func openTarget(_ target: PreviewOpenTarget)"))
    let functionEnd = try XCTUnwrap(source.range(of: "private var centersInCanvas", range: functionStart.upperBound..<source.endIndex))
    let function = source[functionStart.lowerBound..<functionEnd.lowerBound]
    let close = try XCTUnwrap(
      function.range(of: "PanelClosePolicy.decide(.externalHandoff"),
      "external handoff must ask the close policy before leaving"
    )
    let handoff = try XCTUnwrap(function.range(of: "NSWorkspace.shared.open"))
    XCTAssertTrue(close.lowerBound < handoff.lowerBound, "the browser must not take focus before the panel decides whether to hide")
    XCTAssertTrue(function.contains("appState.popup.close()"), "an unpinned panel must actually close")
  }

  func testOpenToolFollowsWrapAndDefaultsStayUnchanged() {
    XCTAssertEqual(PreviewToolStrip.tools(kind: "plain"), [.wrap])
    XCTAssertEqual(PreviewToolStrip.tools(kind: "plain", hasOpenTarget: false), [.wrap])
    XCTAssertEqual(PreviewToolStrip.tools(kind: "plain", hasOpenTarget: true), [.wrap, .open])
    XCTAssertEqual(PreviewToolStrip.tools(kind: "markdown", hasOpenTarget: true), [.wrap, .open])
    XCTAssertEqual(PreviewToolStrip.tools(kind: "code"), [.wrap, .lineNumbers])
    XCTAssertEqual(PreviewToolStrip.tools(kind: "code", hasOpenTarget: true), [.wrap, .open, .lineNumbers])
    XCTAssertEqual(
      PreviewToolStrip.tools(kind: "pdf", hasOpenTarget: true),
      [.pdfZoomOut, .pdfZoomIn, .pdfPrevious, .pdfNext]
    )
    XCTAssertEqual(PreviewToolStrip.tools(kind: "image", hasOpenTarget: true), [.recognize])
    XCTAssertEqual(PreviewToolStrip.tools(kind: "missing", hasOpenTarget: true), [])
  }
}
