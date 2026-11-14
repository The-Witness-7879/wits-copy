import AppKit
import Observation
import Sparkle

enum RailUpdatePhase: Equatable {
  case available
  case downloading
  case ready
}

struct RailUpdateOffer: Equatable {
  var version: String
  var phase: RailUpdatePhase
  var preview: Bool
}

/// One updater for the process. Sparkle still owns scheduling, verification, and installation.
@MainActor
@Observable
final class SoftwareUpdater {
  nonisolated static let feedURL = "https://github.com/The-Witness-7879/wits-copy/releases/latest/download/appcast.xml"
  nonisolated static let previewArgument = "--lab-update-preview"

  private(set) var automaticallyChecksForUpdates = true
  private(set) var canCheckForUpdates = false
  private(set) var isStarted = false
  private(set) var railOffer: RailUpdateOffer?

  var canOpenUpdate: Bool { canCheckForUpdates || railOffer != nil }

  @ObservationIgnored private var sparkle: SPUUpdater?
  @ObservationIgnored private var driver: RailUpdateDriver?
  @ObservationIgnored private var automaticChecksObservation: NSKeyValueObservation?
  @ObservationIgnored private var availabilityObservation: NSKeyValueObservation?
  @ObservationIgnored private let feedDelegate = WitsCopyUpdateFeedDelegate()
  @ObservationIgnored private let windowGlass = UpdateWindowGlass()
  @ObservationIgnored private var installReply: ((SPUUserUpdateChoice) -> Void)?
  @ObservationIgnored private var readyReply: ((SPUUserUpdateChoice) -> Void)?

  init() {
    // Never construct Sparkle in XCTest, previews, smoke/QA hosts, or another app's bundle.
    guard !LabRuntime.isIsolated, Bundle.main.bundleIdentifier == LabRuntime.bundleIdentifier else {
      if Self.smokePreviewRequested {
        railOffer = RailUpdateOffer(version: "0.2.4", phase: .available, preview: true)
      }
      return
    }

    let driver = RailUpdateDriver(hostBundle: Bundle.main, glass: windowGlass)
    driver.owner = self
    let updater = SPUUpdater(
      hostBundle: Bundle.main,
      applicationBundle: Bundle.main,
      userDriver: driver,
      delegate: feedDelegate
    )
    self.driver = driver
    self.sparkle = updater
    automaticChecksObservation = updater.observe(
      \.automaticallyChecksForUpdates, options: [.initial, .new]
    ) { [weak self] updater, _ in
      MainActor.assumeIsolated {
        self?.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
      }
    }
    availabilityObservation = updater.observe(
      \.canCheckForUpdates, options: [.initial, .new]
    ) { [weak self] updater, _ in
      MainActor.assumeIsolated {
        self?.canCheckForUpdates = updater.canCheckForUpdates
      }
    }
    // Info.plist owns the default and one-day interval. Do not set them on every launch.
    do {
      try updater.start()
      isStarted = true
    } catch {
      isStarted = false
    }
  }

  nonisolated static var smokePreviewRequested: Bool {
    LabRuntime.isSmoke && CommandLine.arguments.contains(previewArgument)
  }

  /// Scheduled, installable updates stay in the sidebar. Manual checks and special updates keep Sparkle's dialog.
  nonisolated static func offersInlineDownload(
    userInitiated: Bool,
    informationOnly: Bool,
    majorUpgrade: Bool
  ) -> Bool {
    !userInitiated && !informationOnly && !majorUpgrade
  }

  func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
    guard let updater = sparkle,
          updater.automaticallyChecksForUpdates != enabled else { return }
    updater.automaticallyChecksForUpdates = enabled
  }

  func checkForUpdates() {
    if driver?.revealHeldUpdate() == true { return }
    guard canCheckForUpdates else { return }
    sparkle?.checkForUpdates()
  }

  func acceptRailUpdate() {
    guard let offer = railOffer else { return }
    if offer.preview {
      switch offer.phase {
      case .available:
        railOffer?.phase = .downloading
      case .downloading:
        railOffer?.phase = .ready
      case .ready:
        break
      }
      return
    }
    switch offer.phase {
    case .available:
      guard let reply = installReply else { return }
      installReply = nil
      driver?.forgetHeldUpdate()
      railOffer?.phase = .downloading
      reply(.install)
    case .ready:
      guard let reply = readyReply else { return }
      readyReply = nil
      reply(.install)
    case .downloading:
      break
    }
  }

  func presentInstallable(version: String, reply: @escaping (SPUUserUpdateChoice) -> Void) {
    let stale = installReply
    installReply = nil
    readyReply = nil
    installReply = reply
    railOffer = RailUpdateOffer(version: version, phase: .available, preview: false)
    stale?(.dismiss)
  }

  func presentPreview(version: String) {
    installReply = nil
    readyReply = nil
    railOffer = RailUpdateOffer(version: version, phase: .available, preview: true)
  }

  func presentReady(reply: @escaping (SPUUserUpdateChoice) -> Void) {
    guard railOffer?.preview == false else {
      reply(.dismiss)
      return
    }
    readyReply = reply
    railOffer?.phase = .ready
  }

  func clearRailSession() {
    let install = installReply
    let ready = readyReply
    installReply = nil
    readyReply = nil
    railOffer = nil
    install?(.dismiss)
    ready?(.dismiss)
  }

  func releaseHeldOffer() {
    installReply = nil
    readyReply = nil
    railOffer = nil
  }

  var holdsInlineSession: Bool {
    railOffer?.preview == false && (installReply != nil || readyReply != nil || railOffer?.phase == .downloading)
  }
}

/// Pin the channel even if a legacy SUFeedURL exists in the preferences domain.
final class WitsCopyUpdateFeedDelegate: NSObject, SPUUpdaterDelegate {
  func feedURLString(for updater: SPUUpdater) -> String? {
    SoftwareUpdater.feedURL
  }
}

/// Forwards Sparkle's standard progress and dialogs, but keeps an ordinary scheduled update in the sidebar.
final class RailUpdateDriver: NSObject, SPUUserDriver {
  weak var owner: SoftwareUpdater?
  private let standard: SPUStandardUserDriver
  private var heldItem: SUAppcastItem?
  private var heldState: SPUUserUpdateState?
  private var heldReply: ((SPUUserUpdateChoice) -> Void)?

  init(hostBundle: Bundle, glass: UpdateWindowGlass) {
    standard = SPUStandardUserDriver(hostBundle: hostBundle, delegate: glass)
    super.init()
  }

  func forgetHeldUpdate() {
    heldItem = nil
    heldState = nil
    heldReply = nil
  }

  func revealHeldUpdate() -> Bool {
    guard let item = heldItem, let state = heldState, let reply = heldReply else { return false }
    heldItem = nil
    heldState = nil
    heldReply = nil
    owner?.releaseHeldOffer()
    standard.showUpdateFound(with: item, state: state, reply: reply)
    standard.showUpdateInFocus()
    return true
  }

  func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
    standard.show(request, reply: reply)
  }

  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
    standard.showUserInitiatedUpdateCheck(cancellation: cancellation)
  }

  func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
    guard SoftwareUpdater.offersInlineDownload(
      userInitiated: state.userInitiated,
      informationOnly: item.isInformationOnlyUpdate,
      majorUpgrade: item.isMajorUpgrade
    ) else {
      standard.showUpdateFound(with: item, state: state, reply: reply)
      return
    }
    heldItem = item
    heldState = state
    heldReply = reply
    owner?.presentInstallable(version: item.displayVersionString, reply: reply)
  }

  func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
    standard.showUpdateReleaseNotes(with: downloadData)
  }

  func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
    standard.showUpdateReleaseNotesFailedToDownloadWithError(error)
  }

  func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
    standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
  }

  func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
    clearHeld()
    owner?.clearRailSession()
    standard.showUpdaterError(error, acknowledgement: acknowledgement)
  }

  func showDownloadInitiated(cancellation: @escaping () -> Void) {
    standard.showDownloadInitiated(cancellation: cancellation)
  }

  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
    standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
  }

  func showDownloadDidReceiveData(ofLength length: UInt64) {
    standard.showDownloadDidReceiveData(ofLength: length)
  }

  func showDownloadDidStartExtractingUpdate() {
    standard.showDownloadDidStartExtractingUpdate()
  }

  func showExtractionReceivedProgress(_ progress: Double) {
    standard.showExtractionReceivedProgress(progress)
  }

  func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
    guard owner?.holdsInlineSession == true else {
      standard.showReady(toInstallAndRelaunch: reply)
      return
    }
    owner?.presentReady(reply: reply)
  }

  func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
    standard.showInstallingUpdate(
      withApplicationTerminated: applicationTerminated,
      retryTerminatingApplication: retryTerminatingApplication
    )
  }

  func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
    clearHeld()
    owner?.clearRailSession()
    standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
  }

  func dismissUpdateInstallation() {
    clearHeld()
    owner?.clearRailSession()
    standard.dismissUpdateInstallation()
  }

  func showUpdateInFocus() {
    if revealHeldUpdate() { return }
    standard.showUpdateInFocus()
  }

  private func clearHeld() {
    heldItem = nil
    heldState = nil
    heldReply = nil
  }
}

/// Sparkle's update windows come from its own nibs. Each one gets the clipboard panel's glass shell.
final class UpdateWindowGlass: NSObject, SPUStandardUserDriverDelegate {
  private var observers: [NSObjectProtocol] = []

  override init() {
    super.init()
    let names: [Notification.Name] = [
      NSWindow.didBecomeKeyNotification,
      NSWindow.didBecomeMainNotification,
      NSWindow.didChangeOcclusionStateNotification
    ]
    observers = names.map { name in
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
        guard let window = note.object as? NSWindow else { return }
        MainActor.assumeIsolated { Self.adoptIfOwnedBySparkle(window) }
      }
    }
  }

  deinit {
    observers.forEach(NotificationCenter.default.removeObserver)
  }

  func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool,
    forUpdate update: SUAppcastItem,
    state: SPUUserUpdateState
  ) {
    DispatchQueue.main.async {
      MainActor.assumeIsolated { NSApp.windows.forEach(Self.adoptIfOwnedBySparkle) }
    }
  }

  @MainActor
  static func isOwnedBySparkle(_ window: NSWindow) -> Bool {
    guard let controller = window.windowController else { return false }
    return Bundle(for: type(of: controller)) == Bundle(for: SPUStandardUserDriver.self)
  }

  @MainActor
  static func adoptIfOwnedBySparkle(_ window: NSWindow) {
    guard isOwnedBySparkle(window) else { return }
    GlassShell.adopt(window)
  }
}
