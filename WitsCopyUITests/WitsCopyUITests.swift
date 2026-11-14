import Carbon
import XCTest

// swiftlint:disable file_length
// swiftlint:disable type_body_length
class WitsCopyUITests: XCTestCase {
  let app = XCUIApplication()
  let pasteboard = NSPasteboard.general

  let copy1 = UUID().uuidString
  let copy2 = UUID().uuidString
  let copy3 = UUID().uuidString

  // https://hetima.github.io/fucking_nsimage_syntax
  let image1 = NSImage(named: "NSAddTemplate")!
  let image2 = NSImage(named: "NSBluetoothTemplate")!

  let file1 = URL.applicationSupportDirectory.appendingPathComponent("file1.txt")
  let file2 = URL.applicationSupportDirectory.appendingPathComponent("file2.txt")

  let rtf1 = NSAttributedString(string: "foo").rtf(
    from: NSRange(0...2),
    documentAttributes: [:]
  )
  let rtf2 = NSAttributedString(string: "bar").rtf(
    from: NSRange(0...2),
    documentAttributes: [:]
  )

  let html1 = "<a href='#'>foo</a>".data(using: .utf8)
  let html2 = "<a href='#'>bar</a>".data(using: .utf8)

  let imageType = NSPredicate(
    format: "elementType == %lu",
    argumentArray: [XCUIElement.ElementType.image.rawValue]
  )

  var items: XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "copy-history-item")
  }

  var itemTitles: [String] {
    items.allElementsBoundByIndex
      .sorted(by: { $0.frame.origin.y < $1.frame.origin.y })
      .compactMap { $0.value as? String }
  }

  override func setUp() {
    super.setUp()

    try? "Hello world".write(to: file1, atomically: true, encoding: .utf8)
    try? "Hello world".write(to: file2, atomically: true, encoding: .utf8)

    app.launchArguments.append("enable-testing")
    app.launch()

    copyToClipboard(copy2)
    copyToClipboard(copy1)

  }

  override func tearDown() {
    super.tearDown()
    app.terminate()
  }

  func testPopupWithHotkey() throws {
    popUpWithHotkey()
    assertExists(items[copy1])
    assertExists(items[copy2])
  }

  func testCloseWithHotkey() throws {
    popUpWithMouse()
    assertExists(items[copy1])
    simulatePopupHotkey()
    assertNotExists(items[copy1])
  }

  func testPopupWithMenubar() {
    popUpWithMouse()
    assertExists(items[copy1])
    assertExists(items[copy2])
  }

  func testNewCopyIsAdded() {
    popUpWithMouse()
    let copy3 = UUID().uuidString
    copyToClipboard(copy3)
    assertExists(items[copy3])
    app.typeKey(.escape, modifierFlags: [])
    popUpWithMouse()
    assertExists(items[copy2])
  }

  func testSearch() {
    popUpWithMouse()
    search(copy2)
    assertSearchFieldValue(copy2)
    assertExists(app.staticTexts[copy2])
    assertNotExists(items[copy1])
  }

  func testSearchFiles() {
    copyToClipboard(file2)
    copyToClipboard(file1)
    popUpWithMouse()
    search(file2.lastPathComponent)
    assertExists(items[file2.absoluteString.removingPercentEncoding!])
    assertNotExists(items[file1.absoluteString.removingPercentEncoding!])
  }

  func testCopyWithClick() {
    popUpWithMouse()
    scrollIntoViewIfNeeded(items[copy2].firstMatch)
    items[copy2].firstMatch.click()
    assertPasteboardStringEquals(copy2)
  }

  func testCopyWithEnter() {
    popUpWithMouse()
    scrollIntoViewIfNeeded(items[copy2].firstMatch)
    hover(items[copy2].firstMatch)
    app.typeKey(.enter, modifierFlags: [])
    assertPasteboardStringEquals(copy2)
  }

  func testCopyWithCommandShortcut() {
    popUpWithMouse()
    app.typeKey("2", modifierFlags: [.command])
    assertPasteboardStringEquals(copy2)
  }

  func testSearchAndCopyWithCommandShortcut() {
    popUpWithMouse()
    search(copy2)
    app.typeKey("1", modifierFlags: [.command])
    assertPasteboardStringEquals(copy2)
  }

  func testCopyImage() {
    copyToClipboard(image2)
    copyToClipboard(image1)
    popUpWithMouse()
    scrollIntoViewIfNeeded(items.matching(imageType).allElementsBoundByIndex[1])
    hoverAndClick(items.matching(imageType).allElementsBoundByIndex[1])
    assertPasteboardDataCountEquals(image2.tiffRepresentation!.count, forType: .tiff)
  }

  func testCopyFile() {
    copyToClipboard(file2)
    copyToClipboard(file1)
    popUpWithMouse()

    XCTAssertEqual(itemTitles[0...1], [
      file1.absoluteString.removingPercentEncoding!,
      file2.absoluteString.removingPercentEncoding!
    ])
    scrollIntoViewIfNeeded(items[file2.absoluteString.removingPercentEncoding!].firstMatch)
    hoverAndClick(items[file2.absoluteString.removingPercentEncoding!].firstMatch)
    assertPasteboardStringEquals(file2.absoluteString, forType: .fileURL)
  }

  func testCopyRTF() {
    copyToClipboard(rtf2, .rtf)
    popUpWithHotkey()
    closePopupByClickingOutside()
    copyToClipboard(rtf1, .rtf)
    popUpWithHotkey()
    XCTAssertEqual(itemTitles[0...1], ["foo", "bar"])
    scrollIntoViewIfNeeded(app.staticTexts["bar"].firstMatch)
    hoverAndClick(app.staticTexts["bar"].firstMatch)
    XCTAssertEqual(pasteboard.data(forType: .rtf), rtf1)
  }

  func testCopyHTML() {
    copyToClipboard(html2, .html)
    copyToClipboard(html1, .html)
    popUpWithMouse()
    XCTAssertEqual(itemTitles[0...1], ["foo", "bar"])
    scrollIntoViewIfNeeded(items["bar"].firstMatch)
    hoverAndClick(items["bar"].firstMatch)
    assertPasteboardDataEquals(html2, forType: .html)
  }

  func testDownArrow() {
    popUpWithMouse()
    app.typeKey(.downArrow, modifierFlags: [])
    app.typeKey(.enter, modifierFlags: [])
    assertPasteboardStringEquals(copy2)
  }

  func testUpArrow() {
    popUpWithMouse()
    app.typeKey(.downArrow, modifierFlags: [])
    app.typeKey(.upArrow, modifierFlags: [])
    app.typeKey(.enter, modifierFlags: [])
    assertPasteboardStringEquals(copy1)
  }

  func testControlJ() {
    popUpWithMouse()
    app.typeKey("j", modifierFlags: [.control])
    app.typeKey(.enter, modifierFlags: [])
    assertPasteboardStringEquals(copy2)
  }

  func testControlK() {
    popUpWithMouse()
    app.typeKey("j", modifierFlags: [.control])
    app.typeKey("k", modifierFlags: [.control])
    app.typeKey(.enter, modifierFlags: [])
    assertPasteboardStringEquals(copy1)
  }

  func testDeleteEntry() {
    popUpWithMouse()
    app.typeKey(.delete, modifierFlags: [.option])
    assertNotExists(items[copy1])

    app.typeKey(.escape, modifierFlags: [])
    popUpWithMouse()
    assertNotExists(items[copy1])
  }

  func testDeleteEntryDuringSearch() {
    popUpWithMouse()
    search(copy2)
    app.typeKey(.delete, modifierFlags: [.option])
    assertNotExists(items[copy2])

    app.typeKey(.escape, modifierFlags: [])
    popUpWithMouse()
    assertNotExists(items[copy2])
  }

  func testClear() {
    popUpWithMouse()
    scrollIntoViewIfNeeded(items[copy2].firstMatch)
    pin(copy2)
    hoverAndClick(app.staticTexts["Clear"].firstMatch)
    confirmClear()
    popUpWithMouse()
    assertNotExists(items[copy1])
    assertExists(items[copy2])
  }

  func testClearDuringSearch() {
    popUpWithMouse()
    search(copy2)
    hoverAndClick(app.staticTexts["Clear"].firstMatch)
    confirmClear()
    popUpWithMouse()
    assertNotExists(items[copy1])
    assertNotExists(items[copy2])
  }

  func testClearAll() {
    popUpWithMouse()
    scrollIntoViewIfNeeded(items[copy2].firstMatch)
    pin(copy2)
    XCUIElement.perform(withKeyModifiers: [.shift]) {
      hoverAndClick(app.staticTexts["Clear all"].firstMatch)
    }
    confirmClear()
    popUpWithMouse()
    assertNotExists(items[copy1])
    assertNotExists(items[copy2])
  }

  func testPin() {
    popUpWithMouse()
    scrollIntoViewIfNeeded(items[copy2].firstMatch)
    pin(copy2)
    XCTAssertEqual(itemTitles[0...1], [copy2, copy1])

    app.typeKey(.escape, modifierFlags: [])
    popUpWithMouse()
    XCTAssertEqual(itemTitles[0...1], [copy2, copy1])
  }

  func testPinDuringSearch() {
    popUpWithMouse()
    search(copy2)
    scrollIntoViewIfNeeded(items[copy2].firstMatch)
    pin(copy2)
    assertSearchFieldValue("")
    XCTAssertEqual(itemTitles[0...1], [copy2, copy1])
  }

  func testUnpin() {
    popUpWithMouse()
    scrollIntoViewIfNeeded(items[copy2].firstMatch)
    pin(copy2)
    pin(copy2)
    XCTAssertEqual(itemTitles[0...1], [copy1, copy2])
  }

  func testRemoveLastWordFromSearchWithControlW() {
    popUpWithMouse()
    search("foo bar")
    app.typeKey("w", modifierFlags: [.control])
    assertSearchFieldValue("foo ")
  }

  func testPasteToSearch() {
    popUpWithMouse()
    app.typeKey("v", modifierFlags: [.command])
    waitForSearch()
    assertSearchFieldValue(copy1)
    assertExists(items[copy1])
    assertNotExists(items[copy2])
  }

  func testDisablesOnOptionClickingMenubarIcon() {
    XCUIElement.perform(withKeyModifiers: .option) {
      app.statusItems.firstMatch.click()
    }

    let copy3 = UUID().uuidString
    let copy4 = UUID().uuidString
    copyToClipboard(copy3)
    copyToClipboard(copy4)

    popUpWithMouse()
    assertNotExists(items[copy3])
    assertNotExists(items[copy4])

    app.typeKey(.escape, modifierFlags: [])
    XCUIElement.perform(withKeyModifiers: .option) {
      app.statusItems.firstMatch.click()
    }
  }

  func testDisablesOnlyForNextCopyOnOptionShiftClickingMenubarIcon() {
    XCUIElement.perform(withKeyModifiers: [.option, .shift]) {
      app.statusItems.firstMatch.click()
    }

    let copy3 = UUID().uuidString
    let copy4 = UUID().uuidString
    copyToClipboard(copy3)
    copyToClipboard(copy4)

    popUpWithMouse()
    assertNotExists(items[copy3])
    assertExists(items[copy4])
  }

  func testCreatesNewCopyOnEnterWhenSearchResultsAreEmpty() {
    popUpWithMouse()
    search("foo bar")
    app.typeKey(.return, modifierFlags: [])
    XCTAssertEqual(pasteboard.string(forType: .string), "foo bar")
    assertExists(items["foo bar"])
  }

  func testOpenAndClose() throws {
    // Simulate the popup hotkey press (Cmd + Shift + C).
    let cDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)!
    cDown.flags = [.maskCommand, .maskShift]
    cDown.post(tap: .cghidEventTap)

    waitUntilPoppedUp()

    // Release the 'C' key but keep the popup open.
    let cUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)!
    cUp.flags = [.maskCommand, .maskShift]
    cUp.post(tap: .cghidEventTap)

    waitUntilPoppedUp()

    // Release the 'Shift' key and assert that the popup remains open - "normal" mode.
    let shiftUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Shift), keyDown: false)!
    shiftUp.flags = [.maskCommand] // Command remains active, Shift released
    shiftUp.post(tap: .cghidEventTap)

    waitUntilPoppedUp()

    // Release the 'CMD' key and assert that the popup remains open - "normal" mode.
    let commandUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Command), keyDown: false)!
    commandUp.flags = []
    commandUp.post(tap: .cghidEventTap)

    waitUntilPoppedUp()

    // Press shortcut again and assert the window closes
    cDown.flags = [.maskCommand, .maskShift]
    cDown.post(tap: .cghidEventTap)

    assertPopupDismissed()
  }

  func testOpenAndSelectSecondItem() throws {
    // Simulate the popup hotkey press (Cmd + Shift + C).
    let cDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)!
    cDown.flags = [.maskCommand, .maskShift]
    cDown.post(tap: .cghidEventTap)

    waitUntilPoppedUp()

    let cUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)!
    cUp.flags = [.maskCommand, .maskShift]
    cUp.post(tap: .cghidEventTap)

    // Press C 1 more time while keeping the modifier keys pressed
    cDown.post(tap: .cghidEventTap)

    // Release all modifiers keys and assert that the popup closes.
    let modifiersUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Shift), keyDown: false)!
    modifiersUp.flags = []
    modifiersUp.post(tap: .cghidEventTap)

    assertPopupDismissed()
    assertPasteboardStringEquals(copy2)
  }

  func testOpenAndSelectThirdItem() throws {
    copyToClipboard(copy3)

    // Simulate the popup hotkey press (Cmd + Shift + C).
    let cDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)!
    cDown.flags = [.maskCommand, .maskShift]
    cDown.post(tap: .cghidEventTap)

    waitUntilPoppedUp()

    let cUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)!
    cUp.flags = [.maskCommand, .maskShift]
    cUp.post(tap: .cghidEventTap)

    // Press C 2 more times while keeping the modifier keys pressed
    cDown.post(tap: .cghidEventTap)
    cUp.post(tap: .cghidEventTap)
    cDown.post(tap: .cghidEventTap)

    // Release all modifiers keys and assert that the popup closes.
    let modifiersUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Shift), keyDown: false)!
    modifiersUp.flags = []
    modifiersUp.post(tap: .cghidEventTap)

    assertPopupDismissed()
    assertPasteboardStringEquals(copy2)
  }

  func testOpenAndSelectThirdItemRepeatedPress() throws {
    copyToClipboard(copy3)

    // Simulate the popup hotkey press (Cmd + Shift + C).
    let cDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)!
    cDown.flags = [.maskCommand, .maskShift]
    cDown.post(tap: .cghidEventTap)

    waitUntilPoppedUp()

    // Press C 2 more times while keeping the modifier keys pressed
    cDown.post(tap: .cghidEventTap)
    cDown.post(tap: .cghidEventTap)

    // Release all modifiers keys and assert that the popup closes.
    let modifiersUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Shift), keyDown: false)!
    modifiersUp.flags = []
    modifiersUp.post(tap: .cghidEventTap)

    assertPopupDismissed()
    assertPasteboardStringEquals(copy2)
  }

  func testTogglePopupAndCloseOnClickOutside() {
    popUpWithHotkey()

    closePopupByClickingOutside()
    assertNotExists(items[copy1])

    // Assert that the hotkeys still work
    popUpWithHotkey()

    simulatePopupHotkey()
    assertPopupDismissed()
  }

  private func popUpWithHotkey() {
    simulatePopupHotkey()
    waitUntilPoppedUp()
  }

  // Click outside the popup to close it
  private func closePopupByClickingOutside() {
    let statusBar = app.statusItems.firstMatch
    let coordinate = statusBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 10.0))
    coordinate.click()
  }

  private func popUpWithMouse() {
    app.statusItems.firstMatch.click()
    waitUntilPoppedUp()
  }

  private func simulatePopupHotkey() {
    let commandDown = CGEvent(
      keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Command), keyDown: true)!
    let commandUp = CGEvent(
      keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Command), keyDown: false)!
    let shiftDown = CGEvent(
      keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Shift), keyDown: true)!
    let shiftUp = CGEvent(
      keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Shift), keyDown: false)!
    shiftDown.flags = [.maskCommand]
    shiftUp.flags = [.maskCommand]
    let cDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)!
    let cUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)!
    cDown.flags = [.maskCommand, .maskShift]
    cUp.flags = [.maskCommand, .maskShift]
    commandDown.post(tap: .cghidEventTap)
    shiftDown.post(tap: .cghidEventTap)
    cDown.post(tap: .cghidEventTap)
    cUp.post(tap: .cghidEventTap)
    shiftUp.post(tap: .cghidEventTap)
    commandUp.post(tap: .cghidEventTap)
  }

  private func waitUntilPoppedUp() {
    if !app.staticTexts.firstMatch.waitForExistence(timeout: 3) {
      XCTFail("WitsCopy did not pop up")
    }
  }

  private func assertPopupDismissed() {
    if !app.staticTexts.firstMatch.waitForNonExistence(timeout: 3) {
      XCTFail("WitsCopy did not dismiss")
    }
  }

  private func copyToClipboard(_ content: String) {
    pasteboard.clearContents()
    pasteboard.setString(content, forType: .string)
    waitTillClipboardCheck()
  }

  private func copyToClipboard(_ content: NSImage) {
    pasteboard.clearContents()
    pasteboard.setData(content.tiffRepresentation, forType: .tiff)
    waitTillClipboardCheck()
  }

  private func copyToClipboard(_ content: URL) {
    pasteboard.clearContents()
    pasteboard.setData(content.dataRepresentation, forType: .fileURL)
    // WTF: The subsequent writes to pasteboard are not
    // visible unless we explicitly read the last one?!
    pasteboard.string(forType: .fileURL)
    waitTillClipboardCheck()
  }

  private func copyToClipboard(_ content: Data?, _ type: NSPasteboard.PasteboardType) {
    pasteboard.clearContents()
    pasteboard.setData(content, forType: type)
    waitTillClipboardCheck()
  }

  // Default interval for WitsCopy to check clipboard is 1 second
  private func waitTillClipboardCheck() {
    usleep(1_500_000)
  }

  private func pin(_ title: String) {
    hover(items[title].firstMatch)
    app.typeKey("p", modifierFlags: [.option])
    usleep(1_500_000)
  }

  private func hoverAndClick(_ element: XCUIElement) {
    let coordinate = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    coordinate.hover()
    usleep(200_000)
    coordinate.click()
  }

  private func scrollIntoViewIfNeeded(_ element: XCUIElement) {
    guard element.exists else {
      return
    }

    let container = app.scrollViews["history-scroll-view"].firstMatch
    guard container.exists else {
      return
    }

    var attempts = 0
    while !container.frame.contains(element.frame) && attempts < 15 {
      // Negative deltaY scrolls down (reveals elements below the viewport).
      let delta: CGFloat = element.frame.midY > container.frame.midY ? -10 : 10
      container.scroll(byDeltaX: 0, deltaY: delta)
      usleep(100_000)
      attempts += 1
    }
  }

  private func hover(_ element: XCUIElement) {
    element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).hover()
    usleep(50_000)
    element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
    usleep(200_000)
  }

  private func search(_ string: String) {
    // NOTE: app.typeText is broken in Sonoma and causes some
    //       Chars to be submitted with a .command mask (e.g. 'p', 'k' or 'j')
    string.forEach {
      app.typeKey("\($0)", modifierFlags: [])
    }
    waitForSearch()
  }

  private func waitForSearch() {
    // NOTE: This is a hack and is flaky.
    // Ideally we should wait for a proper condition to detect that search has settled down.
    usleep(500000)  // wait for search throttle
  }

  private func assertExists(_ element: XCUIElement) {
    expectation(for: NSPredicate(format: "exists = 1"), evaluatedWith: element)
    waitForExpectations(timeout: 3)
  }

  private func assertNotExists(_ element: XCUIElement) {
    expectation(for: NSPredicate(format: "exists = 0"), evaluatedWith: element)
    waitForExpectations(timeout: 3)
  }

  private func assertPasteboardDataEquals(
    _ expected: Data?, forType: NSPasteboard.PasteboardType = .string
  ) {
    let predicate = NSPredicate { (object, _) -> Bool in
      guard let copy = object as? Data else {
        return false
      }

      return self.pasteboard.data(forType: forType) == copy
    }
    expectation(for: predicate, evaluatedWith: expected)
    waitForExpectations(timeout: 3)
  }

  private func assertPasteboardDataCountEquals(
    _ expected: Int, forType: NSPasteboard.PasteboardType = .string
  ) {
    let predicate = NSPredicate { (object, _) -> Bool in
      guard let count = object as? Int else {
        return false
      }

      return self.pasteboard.data(forType: forType)!.count == count
    }
    expectation(for: predicate, evaluatedWith: expected)
    waitForExpectations(timeout: 3)
  }

  private func assertPasteboardStringEquals(_ expected: String?, forType: NSPasteboard.PasteboardType = .string) {
      let predicate = NSPredicate { (object, _) -> Bool in
        guard let copy = object as? String else {
          return false
        }
        return self.pasteboard.string(forType: forType) == copy
      }
      expectation(for: predicate, evaluatedWith: expected)
      waitForExpectations(timeout: 3)
    }

  private func assertSearchFieldValue(_ string: String) {
    XCTAssertEqual(app.textFields.firstMatch.value as? String, string)
  }

  private func confirmClear() {
    let button = app.dialogs.firstMatch.buttons["Clear"].firstMatch
    expectation(for: NSPredicate(format: "isHittable = 1"), evaluatedWith: button)
    waitForExpectations(timeout: 3)
    button.click()
  }
}
// swiftlint:enable type_body_length
// swiftlint:enable file_length

final class LabTagUITests: XCTestCase {
  let app = XCUIApplication()

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
    app.launchArguments = [
      "--lab-smoke",
      "-AppleLanguages", "(zh-Hans)",
      "-AppleLocale", "zh_Hans"
    ]
    app.launch()
  }

  override func tearDown() {
    app.terminate()
    super.tearDown()
  }

  func testTagButtonAddsChineseChipFiltersAndClears() {
    let button = app.buttons["lab-tag-button"]
    XCTAssertTrue(button.waitForExistence(timeout: 8))
    button.click()

    let field = app.textFields["lab-tag-field"]
    XCTAssertTrue(field.waitForExistence(timeout: 4))
    field.click()
    field.typeText("地址")

    let add = app.buttons["lab-tag-add"]
    XCTAssertTrue(add.waitForExistence(timeout: 2))
    add.click()

    let chip = app.buttons["lab-tag-chip-地址"]
    XCTAssertTrue(chip.waitForExistence(timeout: 4))

    if button.exists {
      button.click()
    }

    let other = app.descendants(matching: .any)
      .matching(identifier: "copy-history-item")
      .matching(NSPredicate(format: "value == %@", "Standup notes for Monday"))
      .firstMatch
    XCTAssertTrue(other.waitForExistence(timeout: 4))

    chip.click()

    let clear = app.buttons["lab-clear-tag-filter"]
    XCTAssertTrue(clear.waitForExistence(timeout: 4))
    XCTAssertFalse(other.exists)

    clear.click()
    XCTAssertTrue(other.waitForExistence(timeout: 4))
    XCTAssertFalse(app.buttons["lab-clear-tag-filter"].exists)
  }
}

/// Synthetic in-memory smoke rows only; no system pasteboard or real user store.
/// Leader: xcodebuild -project WitsCopy.xcodeproj -scheme WitsCopy -destination 'platform=macOS'
///   -only-testing:WitsCopyUITests/LabTitleUITests test
final class LabTitleUITests: XCTestCase {
  let app = XCUIApplication()

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
    app.launchArguments = ["--lab-smoke", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_Hans"]
    app.launch()
  }

  override func tearDown() {
    app.terminate()
    super.tearDown()
  }

  func testRowMenuRenameSaveReplaceAndRestoreAutomaticTitle() {
    let original = "Standup notes for Monday"
    openRename(on: original)
    let field = app.textFields["lab-title-field"]
    XCTAssertEqual(field.value as? String, original)
    XCTAssertFalse(app.buttons["lab-title-restore"].exists)
    XCTAssertTrue(app.buttons["lab-title-cancel"].exists)
    replaceName("邮箱", in: field)
    app.typeKey(.enter, modifierFlags: [])
    XCTAssertTrue(row("邮箱").waitForExistence(timeout: 4))
    XCTAssertFalse(field.exists)

    openRename(on: "邮箱")
    replaceName("工作邮箱", in: app.textFields["lab-title-field"])
    app.buttons["lab-title-save"].click()
    XCTAssertTrue(row("工作邮箱").waitForExistence(timeout: 4))

    openRename(on: "工作邮箱")
    replaceName("", in: app.textFields["lab-title-field"])
    app.buttons["lab-title-save"].click()
    XCTAssertTrue(row(original).waitForExistence(timeout: 4))
    XCTAssertFalse(app.textFields["lab-title-field"].exists)
  }

  func testLongManualNameKeepsNoExcerptTitleOnOneLine() {
    app.terminate()
    app.launchArguments += ["--lab-title-no-excerpt-smoke", "-compactRows", "NO"]
    app.launch()

    // 仅含 RTF：改名后也无摘要，避免摘要分支原有的单行限制掩盖回归。
    let original = "合成无摘要标题"
    let originalTitle = app.staticTexts.matching(identifier: "copy-history-item")
      .matching(NSPredicate(format: "value == %@", original)).firstMatch
    XCTAssertTrue(originalTitle.waitForExistence(timeout: 8))
    let singleLineHeight = originalTitle.frame.height
    XCTAssertGreaterThan(singleLineHeight, 0)

    let longName = String(repeating: "这是用于验证单行截断的超长手工标题", count: 12)
    openRename(on: original)
    replaceName(longName, in: app.textFields["lab-title-field"])
    app.buttons["lab-title-save"].click()

    let savedTitle = app.staticTexts.matching(identifier: "copy-history-item")
      .matching(NSPredicate(format: "value == %@", longName)).firstMatch
    XCTAssertTrue(savedTitle.waitForExistence(timeout: 4))
    XCTAssertFalse(app.textFields["lab-title-field"].exists)
    XCTAssertEqual(savedTitle.frame.height, singleLineHeight, accuracy: 1)
  }

  func testEmptyNameDisablesSaveAndEscapeCancelsWithoutChangingRow() {
    let original = "Standup notes for Monday"
    openRename(on: original)
    let field = app.textFields["lab-title-field"]
    replaceName("  ", in: field)
    XCTAssertTrue(app.buttons["lab-title-save"].isEnabled)
    app.buttons["lab-title-cancel"].click()
    assertTitleEditorCancelled(original: original)

    // Reopening without typing must start a fresh Esc-cancel session.
    openRename(on: original)
    app.typeKey(.escape, modifierFlags: [])
    assertTitleEditorCancelled(original: original)
  }

  func testTitleEditorOwnsTextEditingAndListShortcuts() {
    let original = "Standup notes for Monday"
    openRename(on: original)
    let field = app.textFields["lab-title-field"]
    replaceName("alpha beta", in: field)
    // Option-Delete deletes a word in the field, never the selected history row.
    field.typeKey(.delete, modifierFlags: .option)
    XCTAssertEqual(field.value as? String, "alpha ")
    XCTAssertTrue(row(original).exists)

    // The panel's positional copy shortcut must not steal an editor keystroke.
    field.typeKey("1", modifierFlags: .command)
    XCTAssertTrue(field.exists)
    XCTAssertEqual(field.value as? String, "alpha ")
    XCTAssertTrue(app.windows["WitsCopy synthetic"].isHittable)
    field.typeText("gamma")
    app.typeKey(.enter, modifierFlags: [])
    XCTAssertTrue(row("alpha gamma").waitForExistence(timeout: 4))
  }

  private func assertTitleEditorCancelled(original: String) {
    let gone = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"),
      object: app.textFields["lab-title-field"]
    )
    XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 4), .completed)
    XCTAssertTrue(row(original).isHittable)
    XCTAssertTrue(app.windows["WitsCopy synthetic"].isHittable)
  }

  private func row(_ title: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: "copy-history-item")
      .matching(NSPredicate(format: "value == %@", title)).firstMatch
  }

  private func openRename(on title: String) {
    let target = row(title)
    XCTAssertTrue(target.waitForExistence(timeout: 8))
    target.rightClick()
    let prefixes = ["lab-row-rename-", "lab-row-tag-", "lab-row-pin-", "lab-row-delete-"]
    let rename = app.menuItems.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefixes[0])).firstMatch
    XCTAssertTrue(rename.waitForExistence(timeout: 3))
    let entries = app.menuItems.allElementsBoundByIndex.compactMap { entry in
      prefixes.first { entry.identifier.hasPrefix($0) }
    }
    XCTAssertEqual(entries, prefixes)
    rename.click()
    XCTAssertTrue(app.textFields["lab-title-field"].waitForExistence(timeout: 4))
    XCTAssertTrue(app.descendants(matching: .any)["lab-row-title-editor"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["lab-row-tag-editor"].exists)
  }

  private func replaceName(_ name: String, in field: XCUIElement) {
    field.click()
    field.typeKey("a", modifierFlags: .command)
    field.typeText(name)
  }
}
