import AppKit
import Defaults
import Foundation
import SwiftData
import XCTest
@testable import WitsCopy

/// Pure rules plus private named-board captures; never reads or writes the system clipboard.
final class ClipboardPrivacyTests: XCTestCase {
  func testApplicationBlacklistAndWhitelist() {
    for whitelist in [false, true] {
      XCTAssertEqual(ClipboardIgnoreRules.shouldIgnore(
        sourceAppBundle: "com.example.private",
        ignoredApps: ["com.example.private"],
        ignoreAllAppsExceptListed: whitelist
      ), !whitelist)
      XCTAssertEqual(ClipboardIgnoreRules.shouldIgnore(
        sourceAppBundle: "com.example.other",
        ignoredApps: ["com.example.private"],
        ignoreAllAppsExceptListed: whitelist
      ), whitelist)
      XCTAssertEqual(ClipboardIgnoreRules.shouldIgnore(
        sourceAppBundle: "com.example.other",
        ignoredApps: [],
        ignoreAllAppsExceptListed: whitelist
      ), whitelist)
      XCTAssertEqual(ClipboardIgnoreRules.shouldIgnore(
        sourceAppBundle: nil,
        ignoredApps: ["com.example.private"],
        ignoreAllAppsExceptListed: whitelist
      ), whitelist)
    }
  }

  func testNonemptySecretAssignmentsInEnglishChineseAndJSON() {
    for key in [
      "password", "passwd", "pwd", "passphrase", "secret", "token", "api_key",
      "access_key", "auth_token", "client_secret", "private_key",
      "密码", "口令", "密钥", "令牌", "凭证"
    ] {
      assertSensitive("\(key)=sample-value")
      assertSensitive("\(key)：示例值")
      assertSensitive("{\"\(key)\":\"sample-value\"}")
    }
    assertSensitive("PASSWORD: 'sample value'")
    assertSensitive("登录密码：示例值")
    assertSensitive("password=\"null\"")
    assertSensitive("password='nil'")
  }

  func testCredentialsPrivateKeysAndAuthorizationHeaders() {
    for text in [
      "https://alice:sample-password@example.test/path",
      "postgres://alice:secret@example.test/db",
      "Bearer abc123",
      "Basic dTpw",
      "Authorization: Bearer abc123456789.def456789",
      "Authorization: Basic dXNlcjpwYXNz",
      "-----BEGIN PGP PRIVATE KEY BLOCK-----",
      "-----BEGIN PRIVATE KEY-----\nexample\n-----END PRIVATE KEY-----",
      "-----BEGIN RSA PRIVATE KEY-----\nexample\n-----END RSA PRIVATE KEY-----",
      "-----BEGIN OPENSSH PRIVATE KEY-----\nexample\n-----END OPENSSH PRIVATE KEY-----"
    ] {
      assertSensitive(text)
    }
  }

  func testCommonProviderTokens() {
    // Synthetic format fixtures, not live credentials.
    for text in [
      "ghp_" + String(repeating: "a", count: 36),
      "github_pat_" + String(repeating: "b", count: 82),
      "glpat-" + String(repeating: "c", count: 20),
      "sk-" + String(repeating: "d", count: 48),
      "sk-proj-" + String(repeating: "e", count: 64),
      "sk-svcacct-" + String(repeating: "f", count: 64),
      "AKIAIOSFODNN7EXAMPLE",
      "ASIAIOSFODNN7EXAMPLE",
      "xoxb-1234567890-1234567890-synthetic",
      "xapp-1-" + String(repeating: "g", count: 24),
      "AIza" + String(repeating: "h", count: 35),
      "npm_" + String(repeating: "i", count: 36),
      "sk_live_" + String(repeating: "j", count: 24),
      "rk_test_" + String(repeating: "k", count: 24),
      "ya29." + String(repeating: "l", count: 24),
      "dckr_pat_" + String(repeating: "m", count: 24),
      "shpat_" + String(repeating: "n", count: 32),
      "SG." + String(repeating: "o", count: 20) + "." + String(repeating: "p", count: 20)
    ] {
      assertSensitive(text)
    }
  }

  func testJWTAndNearbySixDigitVerificationCodes() {
    assertSensitive("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJzeW50aGV0aWMifQ.c3ludGhldGljc2lnbmF0dXJl")
    for text in [
      "验证码为 123456，请勿分享", "您的校验码：654321", "动态口令 135790",
      "OTP: 246810", "Your verification code is 123456", "Security code: 123456",
      "One-time code: 123456", "123456 is your verification code", "123456 是您的验证码"
    ] {
      assertSensitive(text)
    }
  }

  func testPaymentCardsRequireKnownIINLengthAndLuhn() {
    for text in [
      "4222222222222", "4111 1111 1111 1111", "4012888888881881",
      "5555-5555-5555-4444", "2223003122003222", "378282246310005",
      "6011111111111117", "3530111333300000", "30569309025904",
      "6200000000000005", "4000000000000000006"
    ] {
      assertSensitive(text)
    }
    for text in [
      "4111 1111 1111 1112", "5555555555554445", "378282246310006",
      "0000000000000000", "1234567890123456", "9111111111111110",
      "411111111111", "41111111111111111111"
    ] {
      assertBenign(text)
    }
  }

  func testBenignTextIsNotMistakenForSecrets() {
    for text in [
      "密码管理器使用说明", "如何设置密码", "password manager documentation",
      "password", "password=", "password: \"\"", "password = '   '",
      "{\"password\": \"\", \"token\": null}", "api_key: \"  \"",
      "passwordless=true", "my_tokenizer=example", "sk-", "sk-short", "sk-learn-example-slug",
      "token: <your-key>", "token: $TOKEN", "token: ${TOKEN}", "token: true", "secret: required",
      "{\"password\": false}", "password: ********",
      "Order 123456 is ready", "123456", "验证码说明：请稍后重试", "OTP: 1234567",
      "https://example.test/path?q=hello", "https://user@example.test/repo",
      "ssh://git@github.com/org/repo.git", "git@github.com:org/repo.git", "mailto:alice@example.test",
      "-----BEGIN PUBLIC KEY-----", "A normal paragraph about access control."
    ] {
      assertBenign(text)
    }
  }

  func testPasswordManagerSourcesAndPasteboardTypes() {
    for bundle in [
      "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
      "org.keepassxc.keepassxc", "net.antelle.keeweb", "in.sinew.Enpass-Desktop",
      "com.lastpass.LastPass", "com.dashlane.Dashlane", "com.dashlane.mac.Dashlane"
    ] {
      XCTAssertTrue(SensitiveContentDetector.isSensitiveSource(bundle), bundle)
    }
    XCTAssertFalse(SensitiveContentDetector.isSensitiveSource(nil))
    XCTAssertFalse(SensitiveContentDetector.isSensitiveSource("com.apple.Safari"))
    XCTAssertFalse(SensitiveContentDetector.isSensitiveSource("com.bitwarden.desktop.imposter"))
    for type in [
      "com.agilebits.onepassword", "net.antelle.keeweb", "de.petermaurer.TransientPasteboardType",
      "Pasteboard generator type", "com.typeit4me.clipping"
    ] {
      XCTAssertTrue(SensitiveContentDetector.hasSensitivePasteboardType(["public.utf8-plain-text", type]), type)
    }
    XCTAssertFalse(SensitiveContentDetector.hasSensitivePasteboardType([]))
    XCTAssertFalse(SensitiveContentDetector.hasSensitivePasteboardType(["public.utf8-plain-text", "public.html"]))
  }

  func testAllTextRepresentationsAndLongTextAreScannedWithoutScanningFilesOrImages() {
    let plain = "public.utf8-plain-text"
    let secret = Data("password=synthetic".utf8)
    XCTAssertTrue(SensitiveContentDetector.containsSensitiveContent(in: [(plain, secret)]))
    XCTAssertTrue(SensitiveContentDetector.containsSensitiveContent(in: [("public.html", secret)]))
    XCTAssertTrue(SensitiveContentDetector.containsSensitiveContent(in: [("public.rtf", secret)]))
    XCTAssertTrue(SensitiveContentDetector.containsSensitiveContent(in: [(plain, nil), ("public.html", secret)]))
    XCTAssertTrue(SensitiveContentDetector.containsSensitiveContent(in: [(plain, Data()), ("public.html", secret)]))
    XCTAssertTrue(SensitiveContentDetector.containsSensitiveContent(inItems: [
      [(plain, Data("normal text".utf8))], [("public.html", secret)]
    ]))
    XCTAssertTrue(SensitiveContentDetector.containsSensitiveContent(in: [
      (plain, Data("normal text".utf8)), ("public.html", secret)
    ]))
    XCTAssertFalse(SensitiveContentDetector.containsSensitiveContent(in: [
      ("public.file-url", secret), ("public.png", secret), ("public.tiff", secret)
    ]))
    XCTAssertFalse(SensitiveContentDetector.containsSensitiveContent(in: [(plain, Data([0xFF]))]))

    for encoding in [String.Encoding.utf16, .utf16LittleEndian, .utf16BigEndian] {
      let encoded = "password=synthetic".data(using: encoding)
      XCTAssertTrue(SensitiveContentDetector.containsSensitiveContent(in: [("public.utf16-plain-text", encoded)]))
    }
    XCTAssertTrue(SensitiveContentDetector.containsSensitiveContent(in: [("NSStringPboardType", secret)]))
    let chunk = SensitiveContentDetector.scanChunkCharacterCount
    let ordinaryLongText = String(repeating: " ", count: chunk * 2 + 100)
    XCTAssertFalse(SensitiveContentDetector.containsSensitiveText(ordinaryLongText))
    XCTAssertFalse(SensitiveContentDetector.containsSensitiveContent(inItems: [
      [(plain, Data(ordinaryLongText.utf8))], [(plain, Data("extra text".utf8))]
    ]))
    let secretBeyondFirstChunk = String(repeating: " ", count: chunk + 100) + "password=synthetic"
    XCTAssertTrue(SensitiveContentDetector.containsSensitiveText(secretBeyondFirstChunk))
    let secretAcrossBoundary = String(repeating: " ", count: chunk - 8) + "password=synthetic"
    XCTAssertTrue(SensitiveContentDetector.containsSensitiveText(secretAcrossBoundary))
  }

  @MainActor
  func testRejectedCapturesNeverReachTheHistoryStore() throws {
    try XCTSkipUnless(LabRuntime.isUnitTestProcess)
    let oldProtection = Defaults[.protectSensitiveContent]
    let oldApps = Defaults[.ignoredApps]
    let oldWhitelist = Defaults[.ignoreAllAppsExceptListed]
    let oldTypes = Defaults[.enabledPasteboardTypes]
    defer {
      Defaults[.protectSensitiveContent] = oldProtection
      Defaults[.ignoredApps] = oldApps
      Defaults[.ignoreAllAppsExceptListed] = oldWhitelist
      Defaults[.enabledPasteboardTypes] = oldTypes
    }
    Defaults[.protectSensitiveContent] = true
    Defaults[.ignoredApps] = []
    Defaults[.ignoreAllAppsExceptListed] = false
    Defaults[.enabledPasteboardTypes] = [.string, .html, .rtf]

    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let directory = root.appendingPathComponent("lab/results/privacy-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = Storage(inMemory: false, url: directory.appendingPathComponent("Storage.sqlite"))
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    var bundle = "com.example.editor"
    let clipboard = Clipboard(pasteboard: board, sourceAppBundleProvider: { bundle })
    var accepted = 0
    var saveError: Error?
    clipboard.onNewCopy { item in
      accepted += 1
      store.context.insert(item)
      do { try store.save() } catch { saveError = error }
    }
    func capture(_ text: String, marker: NSPasteboard.PasteboardType? = nil) {
      board.clearContents()
      board.setString(text, forType: .string)
      if let marker { board.setString("", forType: marker) }
      clipboard.checkForChangesInPasteboard()
    }
    let ordinary = "Ordinary synthetic clipboard text"
    let secret = "password=privacy-test-\(UUID().uuidString)"
    capture(ordinary)
    XCTAssertEqual(accepted, 1, "positive capture control must reach the store")
    capture(secret)
    for marker in [NSPasteboard.PasteboardType.concealed, .transient, .autoGenerated] {
      capture(ordinary, marker: marker)
    }
    bundle = "com.bitwarden.desktop"
    capture("Synthetic unlabelled password")
    XCTAssertEqual(accepted, 1, "rejected captures must not invoke persistence hooks")
    XCTAssertNil(saveError)
    let items = try store.context.fetch(FetchDescriptor<HistoryItem>())
    XCTAssertEqual(items.count, 1)
    XCTAssertEqual(items.first?.application, "com.example.editor")
    XCTAssertEqual(items.first?.contents.first(where: { $0.type == NSPasteboard.PasteboardType.string.rawValue })?.value,
                   Data(ordinary.utf8))
    for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
      let bytes = try Data(contentsOf: url)
      XCTAssertNil(bytes.range(of: Data(secret.utf8)), "rejected secret leaked into \(url.lastPathComponent)")
    }
  }

  @MainActor
  func testNamedBoardApplicationFilteringAndExplicitCopies() throws {
    try XCTSkipUnless(LabRuntime.isUnitTestProcess)
    let oldProtection = Defaults[.protectSensitiveContent]
    let oldApps = Defaults[.ignoredApps]
    let oldWhitelist = Defaults[.ignoreAllAppsExceptListed]
    let oldTypes = Defaults[.enabledPasteboardTypes]
    defer {
      Defaults[.protectSensitiveContent] = oldProtection
      Defaults[.ignoredApps] = oldApps
      Defaults[.ignoreAllAppsExceptListed] = oldWhitelist
      Defaults[.enabledPasteboardTypes] = oldTypes
    }
    Defaults[.protectSensitiveContent] = true
    Defaults[.ignoredApps] = ["com.example.private"]
    Defaults[.ignoreAllAppsExceptListed] = false
    Defaults[.enabledPasteboardTypes] = [.string]
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    var bundle: String? = "com.example.private"
    var sourceReads = 0
    let clipboard = Clipboard(pasteboard: board, sourceAppBundleProvider: {
      sourceReads += 1
      return bundle
    })
    var accepted = 0
    clipboard.onNewCopy { _ in accepted += 1 }
    func capture() {
      sourceReads = 0
      board.clearContents()
      board.setString("Ordinary synthetic text", forType: .string)
      clipboard.checkForChangesInPasteboard()
      XCTAssertEqual(sourceReads, 1)
    }
    capture()
    XCTAssertEqual(accepted, 0)
    bundle = "com.example.allowed"
    capture()
    XCTAssertEqual(accepted, 1)
    Defaults[.ignoreAllAppsExceptListed] = true
    capture()
    XCTAssertEqual(accepted, 1)
    bundle = nil
    capture()
    XCTAssertEqual(accepted, 1)
    bundle = "com.example.private"
    capture()
    XCTAssertEqual(accepted, 2)
    Defaults[.ignoredApps] = []
    clipboard.copyInWitsCopy("Explicit synthetic copy")
    XCTAssertEqual(board.string(forType: .string), "Explicit synthetic copy")
    XCTAssertEqual(accepted, 3, "own copies must not be swallowed by the app whitelist")
    clipboard.copyInWitsCopy("password=synthetic-secret")
    XCTAssertEqual(accepted, 3, "own copies must still respect sensitive capture protection")
    XCTAssertEqual(board.string(forType: .string), "password=synthetic-secret", "explicit copy remains available")
    Defaults[.protectSensitiveContent] = false
    clipboard.copyInWitsCopy("password=synthetic-secret")
    XCTAssertEqual(accepted, 4, "disabling protection must change the real capture path")
  }

  func testPrivacyDefaultsUseTheIsolatedPreferenceSuiteAndMenuKeepsCustomAssets() throws {
    let keys = try source("WitsCopy/Extensions/Defaults.Keys+Names.swift")
    XCTAssertTrue(keys.contains("preferencesSuite: UserDefaults { LabDefaults.suite }"))
    for definition in [
      "Key<Bool>(\"protectSensitiveContent\", default: true, suite: preferencesSuite)",
      "Key<[String]>(\"ignoredApps\", default: [], suite: preferencesSuite)",
      "Key<Bool>(\"ignoreAllAppsExceptListed\", default: false, suite: preferencesSuite)",
      "Key<MenuIcon>(\"menuIcon\", default: .clipboard, suite: preferencesSuite)"
    ] {
      XCTAssertTrue(keys.contains(definition), definition)
    }
    XCTAssertEqual(MenuIcon.allCases.map(\.rawValue), ["clipboard", "scissors", "paperclip"])
    let menu = try source("WitsCopy/MenuIcon.swift")
    XCTAssertFalse(menu.contains("systemSymbolName"))
    for asset in ["clipboard.fill", "scissors", "paperclip"] {
      let json = try source("WitsCopy/Assets.xcassets/\(asset).imageset/Contents.json")
      let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
      let properties = try XCTUnwrap(value["properties"] as? [String: String])
      XCTAssertEqual(properties["template-rendering-intent"], "template", asset)
    }
  }

  func testSettingsCleanupDoesNotRemoveLocalShortcutsOrLiveControls() throws {
    let general = try source("WitsCopy/Settings/GeneralSettingsPane.swift")
    // The popup recorder stays; it is hosted in the glass field skin.
    XCTAssertTrue(general.contains("SettingsShortcutRecorder(name: .popup"))
    for name in ["pin", "tag", "delete", "togglePreview"] {
      XCTAssertFalse(general.contains("KeyboardShortcuts.Recorder(for: .\(name)"), name)
      XCTAssertFalse(general.contains("SettingsShortcutRecorder(name: .\(name)"), name)
    }
    let delegate = try source("WitsCopy/AppDelegate.swift")
    XCTAssertTrue(delegate.contains("disableUnusedGlobalHotkeys()"))
    XCTAssertTrue(delegate.contains("[.delete, .pin, .tag, .togglePreview]"))
    XCTAssertTrue(delegate.contains("KeyboardShortcuts.disable(names)"))
    XCTAssertTrue(delegate.contains("KeyboardShortcuts_shortcutByNameDidChange"))
    XCTAssertTrue(delegate.contains("KeyboardShortcuts.disable(name)"))
    XCTAssertTrue(delegate.contains("2024-07-01-version-2"))
    XCTAssertTrue(delegate.contains("Defaults[.showSearch] = !suite.bool(forKey: \"hideSearch\")"))
    let names = try source("WitsCopy/Extensions/KeyboardShortcuts.Name+Shortcuts.swift")
    for name in ["pin", "tag", "delete", "togglePreview"] {
      XCTAssertTrue(names.contains("static let \(name)"), name)
    }
    let keys = try source("WitsCopy/Extensions/Defaults.Keys+Names.swift")
    for key in ["showFooter", "showTitle"] {
      XCTAssertFalse(keys.contains("static let \(key)"), key)
    }
    let removedByTable = [
      "General": ["Pin", "PinTooltip", "Tag", "TagTooltip", "Delete", "DeleteTooltip", "ShowPreview", "ShowPreviewTooltip"],
      "Advanced": ["TurnOff", "TurnOffDescription", "TurnOffShellScript", "TurnOffViaMenuIconDescription", "TurnOffNextShellScript"],
      "Appearance": ["SearchVisibilityAlways", "SearchVisibilityDuringSearch", "PreviewDelay", "PreviewDelayTooltip",
                     "ShowTitleBeforeSearchField", "ShowFooter", "OpenPreferencesWarning", "ComfortableRows"]
    ]
    for language in ["en", "zh-Hans"] {
      for (table, removed) in removedByTable {
        let strings = try source("WitsCopy/Settings/\(language).lproj/\(table)Settings.strings")
        for key in removed { XCTAssertFalse(strings.contains("\"\(key)\" ="), "\(language)/\(table)/\(key)") }
      }
      let privacy = try source("WitsCopy/Settings/\(language).lproj/PrivacySettings.strings")
      for key in ["Title", "ProtectSensitiveContent", "ProtectSensitiveContentDescription", "Applications",
                  "AddApplication", "RemoveApplication", "OnlyRecordListedApplications", "ApplicationsDescription"] {
        XCTAssertTrue(privacy.contains("\"\(key)\" ="), "\(language)/Privacy/\(key)")
      }
    }
    let chinese = try source("WitsCopy/Settings/zh-Hans.lproj/GeneralSettings.strings")
    XCTAssertFalse(chinese.contains("\"RemoveTrackingParameters\" ="))
    let privacy = try source("WitsCopy/Settings/zh-Hans.lproj/PrivacySettings.strings")
    XCTAssertTrue(privacy.contains("仅影响之后复制的内容。"))
  }

  @MainActor
  func testStorageTypeSwitchesDecideWhatIsRecorded() throws {
    try XCTSkipUnless(LabRuntime.isUnitTestProcess)
    let oldProtection = Defaults[.protectSensitiveContent]
    let oldApps = Defaults[.ignoredApps]
    let oldWhitelist = Defaults[.ignoreAllAppsExceptListed]
    let oldTypes = Defaults[.enabledPasteboardTypes]
    let oldVideos = Defaults[.saveVideos]
    defer {
      Defaults[.protectSensitiveContent] = oldProtection
      Defaults[.ignoredApps] = oldApps
      Defaults[.ignoreAllAppsExceptListed] = oldWhitelist
      Defaults[.enabledPasteboardTypes] = oldTypes
      Defaults[.saveVideos] = oldVideos
    }
    Defaults[.protectSensitiveContent] = false
    Defaults[.ignoredApps] = []
    Defaults[.ignoreAllAppsExceptListed] = false

    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let clipboard = Clipboard(pasteboard: board, sourceAppBundleProvider: { "com.example.editor" })
    var recorded: [HistoryItem] = []
    clipboard.onNewCopy { recorded.append($0) }

    let pixel = try XCTUnwrap(NSImage(size: NSSize(width: 1, height: 1), flipped: false) { rect in
      NSColor.red.setFill(); rect.fill(); return true
    }.tiffRepresentation)
    // Mirrors Finder: the file URL travels with its filename text and icon.
    func copyFile(_ path: String) -> HistoryItem? {
      let item = NSPasteboardItem()
      item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
      item.setString((path as NSString).lastPathComponent, forType: .string)
      item.setData(pixel, forType: .tiff)
      return capture([item])
    }
    func copyText() -> HistoryItem? {
      let item = NSPasteboardItem()
      item.setString("Ordinary synthetic text", forType: .string)
      return capture([item])
    }
    func copyImage(_ type: NSPasteboard.PasteboardType) -> HistoryItem? {
      let item = NSPasteboardItem()
      item.setData(pixel, forType: type)
      return capture([item])
    }
    func capture(_ items: [NSPasteboardItem]) -> HistoryItem? {
      let before = recorded.count
      board.clearContents()
      board.writeObjects(items)
      clipboard.checkForChangesInPasteboard()
      return recorded.count > before ? recorded.last : nil
    }
    func set(text: Bool, images: Bool, videos: Bool, files: Bool) {
      var types = Set<NSPasteboard.PasteboardType>()
      if text { types.formUnion(StorageType.text.types) }
      if images { types.formUnion(StorageType.images.types) }
      if files { types.formUnion(StorageType.files.types) }
      Defaults[.enabledPasteboardTypes] = types
      Defaults[.saveVideos] = videos
    }
    let video = "/tmp/witscopy-synthetic/clip.mp4"
    let document = "/tmp/witscopy-synthetic/notes.pdf"

    set(text: true, images: true, videos: true, files: true)
    XCTAssertEqual(copyText()?.contentKind, .text)
    XCTAssertEqual(copyImage(.png)?.contentKind, .image)
    XCTAssertEqual(copyFile(video)?.fileURLs.first.map(HistoryItem.isMovieFile), true)
    XCTAssertEqual(copyFile(document)?.fileURLs.first?.lastPathComponent, "notes.pdf")

    set(text: false, images: true, videos: true, files: true)
    XCTAssertNil(copyText(), "text off: plain text is not recorded")

    set(text: true, images: false, videos: true, files: true)
    for type in [NSPasteboard.PasteboardType.png, .tiff, .jpeg, .heic] {
      XCTAssertNil(copyImage(type), "images off: \(type.rawValue) is not recorded")
      // Web pages copy text and a picture together; only the text may remain.
      let item = NSPasteboardItem()
      item.setString("Caption", forType: .string)
      item.setData(pixel, forType: type)
      let withText = try XCTUnwrap(capture([item]))
      XCTAssertEqual(withText.contentKind, .text, "images off: \(type.rawValue) dropped beside text")
      XCTAssertFalse(withText.contents.contains { $0.type == type.rawValue }, type.rawValue)
    }

    set(text: true, images: true, videos: false, files: true)
    XCTAssertNil(copyFile(video), "videos off: neither the video nor its filename text/icon is recorded")
    XCTAssertEqual(copyFile(document)?.fileURLs.first?.lastPathComponent, "notes.pdf", "files stay on")

    set(text: true, images: true, videos: true, files: false)
    XCTAssertNil(copyFile(document), "files off: neither the file nor its filename text/icon is recorded")
    let keptVideo = try XCTUnwrap(copyFile(video), "videos stay on while files are off")
    XCTAssertEqual(keptVideo.fileURLs.first?.lastPathComponent, "clip.mp4")

    set(text: false, images: false, videos: true, files: false)
    XCTAssertEqual(copyFile(video)?.fileURLs.first?.lastPathComponent, "clip.mp4", "only videos on")
    XCTAssertNil(copyText())
    XCTAssertNil(copyImage(.png))

    set(text: true, images: true, videos: true, files: true)
    let mixed = [video, document].map { path -> NSPasteboardItem in
      let item = NSPasteboardItem()
      item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
      return item
    }
    Defaults[.saveVideos] = false
    let partial = try XCTUnwrap(capture(mixed), "a mixed copy keeps the allowed file")
    XCTAssertEqual(partial.fileURLs.map(\.lastPathComponent), ["notes.pdf"])
  }

  private func source(_ relativePath: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
  }

  private func assertSensitive(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(SensitiveContentDetector.containsSensitiveText(text), text, file: file, line: line)
  }

  private func assertBenign(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertFalse(SensitiveContentDetector.containsSensitiveText(text), text, file: file, line: line)
  }
}
