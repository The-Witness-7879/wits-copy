import CryptoKit
import Sparkle
import XCTest
@testable import WitsCopy

@MainActor
final class SoftwareUpdaterTests: XCTestCase {
  func testBuiltBundleKeepsForkIdentityAndOwnFeed() throws {
    XCTAssertEqual(Bundle.main.bundleIdentifier, "local.thewitness.WitsCopy")
    XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "Wit's Copy")
    XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String, "WitsCopy")
    XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String, SoftwareUpdater.feedURL)
    XCTAssertEqual(SoftwareUpdater.feedURL,
      "https://github.com/The-Witness-7879/wits-copy/releases/latest/download/appcast.xml")
    let key = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
    let bytes = try XCTUnwrap(Data(base64Encoded: key))
    XCTAssertEqual(bytes.count, 32)
    XCTAssertNoThrow(try Curve25519.Signing.PublicKey(rawRepresentation: bytes))
    let framework = Bundle(for: SPUUpdater.self)
    XCTAssertEqual(framework.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, "2.10.1")
  }

  func testBuiltConfigurationChecksDailyWithoutSilentInstallOrProfiling() {
    XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool, true)
    XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "SUScheduledCheckInterval") as? Int, 86400)
    XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "SUAutomaticallyUpdate") as? Bool, false)
    XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "SUEnableSystemProfiling") as? Bool, false)
    XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "SUVerifyUpdateBeforeExtraction") as? Bool, true)
    XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "SURequireSignedFeed") as? Bool, true)
  }

  func testIsolatedHostCannotStartOrManuallyCheck() {
    XCTAssertTrue(LabRuntime.isUnitTestProcess)
    let updater = SoftwareUpdater()
    XCTAssertFalse(updater.isStarted)
    XCTAssertFalse(updater.canCheckForUpdates)
    updater.checkForUpdates()
    updater.setAutomaticallyChecksForUpdates(false)
    XCTAssertTrue(updater.automaticallyChecksForUpdates)
    XCTAssertFalse(updater.isStarted)
    XCTAssertFalse(AppState.shared.softwareUpdater.isStarted)
  }

  /// Exercises the actual Sparkle preferences API against a synthetic bundle/domain.
  /// Never starts its scheduler, fetches a feed, or instantiates history/clipboard.
  func testSparkleDefaultsAndUserOptOutPersistInIsolatedDomain() throws {
    TestDefaults.removeLeftovers(prefix: "local.thewitness.WitsCopy.updater-test.")
    let domain = "local.thewitness.WitsCopy.updater-test.\(UUID().uuidString)"
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(domain).app", isDirectory: true)
    let contents = root.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
    defer {
      TestDefaults.discard(domain)
      try? FileManager.default.removeItem(at: root)
    }
    var info = try XCTUnwrap(Bundle.main.infoDictionary)
    info["CFBundleIdentifier"] = domain
    info["SUDefaultsDomain"] = domain
    // A malicious/legacy override must not redirect the pinned delegate channel.
    defaults.set("https://example.invalid/untrusted.xml", forKey: "SUFeedURL")
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: contents.appendingPathComponent("Info.plist"))
    let host = try XCTUnwrap(Bundle(url: root))
    let delegate = WitsCopyUpdateFeedDelegate()
    func makeUpdater() -> SPUUpdater {
      SPUUpdater(hostBundle: host, applicationBundle: host,
        userDriver: SPUStandardUserDriver(hostBundle: host, delegate: nil), delegate: delegate)
    }
    let first = makeUpdater()
    XCTAssertTrue(first.automaticallyChecksForUpdates)
    XCTAssertEqual(first.updateCheckInterval, 86400)
    XCTAssertEqual(delegate.feedURLString(for: first), SoftwareUpdater.feedURL)
    first.automaticallyChecksForUpdates = false
    XCTAssertFalse(makeUpdater().automaticallyChecksForUpdates)
    first.automaticallyChecksForUpdates = true
    XCTAssertTrue(makeUpdater().automaticallyChecksForUpdates)
  }

  func testBothShippedLanguagesHaveUpdateLabelsAndHelp() throws {
    for language in ["en", "zh-Hans"] {
      let url = try XCTUnwrap(Bundle.main.url(forResource: "GeneralSettings", withExtension: "strings",
        subdirectory: nil, localization: language))
      let strings = try XCTUnwrap(try PropertyListSerialization.propertyList(
        from: Data(contentsOf: url), format: nil) as? [String: String])
      for key in ["CheckForUpdates", "CheckNow", "CheckForUpdatesTooltip", "CheckNowTooltip"] {
        XCTAssertFalse(try XCTUnwrap(strings[key]).isEmpty, "\(language): \(key)")
      }
    }
  }
}
