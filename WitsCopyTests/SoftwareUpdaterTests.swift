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
    for language in ["en", "zh-Hans"] {
      let url = try XCTUnwrap(Bundle.main.url(forResource: "Localizable", withExtension: "strings",
        subdirectory: nil, localization: language))
      let strings = try XCTUnwrap(try PropertyListSerialization.propertyList(
        from: Data(contentsOf: url), format: nil) as? [String: String])
      for key in ["rail_update_download", "rail_update_download_help", "rail_update_busy",
                   "rail_update_busy_help", "rail_update_restart", "rail_update_restart_help"] {
        XCTAssertFalse(try XCTUnwrap(strings[key]).isEmpty, "\(language): \(key)")
      }
    }
  }

  func testScheduledInstallableUpdateUsesTheSidebarAndConsumesEachReplyOnce() {
    XCTAssertTrue(SoftwareUpdater.offersInlineDownload(userInitiated: false, informationOnly: false, majorUpgrade: false))
    XCTAssertFalse(SoftwareUpdater.offersInlineDownload(userInitiated: true, informationOnly: false, majorUpgrade: false))
    XCTAssertFalse(SoftwareUpdater.offersInlineDownload(userInitiated: false, informationOnly: true, majorUpgrade: false))
    XCTAssertFalse(SoftwareUpdater.offersInlineDownload(userInitiated: false, informationOnly: false, majorUpgrade: true))

    let updater = SoftwareUpdater()
    XCTAssertNil(updater.railOffer)
    var choices: [SPUUserUpdateChoice] = []
    updater.presentInstallable(version: "9.9.9") { choices.append($0) }
    XCTAssertEqual(updater.railOffer, RailUpdateOffer(version: "9.9.9", phase: .available, preview: false))
    updater.acceptRailUpdate()
    updater.acceptRailUpdate()
    XCTAssertEqual(choices, [.install])
    XCTAssertEqual(updater.railOffer?.phase, .downloading)

    updater.presentReady { choices.append($0) }
    XCTAssertEqual(updater.railOffer?.phase, .ready)
    updater.acceptRailUpdate()
    updater.acceptRailUpdate()
    XCTAssertEqual(choices, [.install, .install])
    updater.clearRailSession()
    XCTAssertNil(updater.railOffer)
    updater.acceptRailUpdate()
    XCTAssertEqual(choices, [.install, .install])
  }

  func testANewOfferDismissesThePreviousReplyAndPreviewCannotInstall() {
    let updater = SoftwareUpdater()
    var first: [SPUUserUpdateChoice] = []
    var second: [SPUUserUpdateChoice] = []
    updater.presentInstallable(version: "1") { first.append($0) }
    updater.presentInstallable(version: "2") { second.append($0) }
    XCTAssertEqual(first, [.dismiss])
    updater.clearRailSession()
    XCTAssertEqual(second, [.dismiss])

    updater.presentPreview(version: "preview")
    updater.acceptRailUpdate()
    XCTAssertEqual(updater.railOffer?.phase, .downloading)
    updater.acceptRailUpdate()
    XCTAssertEqual(updater.railOffer?.phase, .ready)
    updater.acceptRailUpdate()
    XCTAssertEqual(updater.railOffer?.phase, .ready)
  }
}
