import AppKit
import Observation
import Sparkle

/// One controller for the process. Sparkle owns the persisted preferences and scheduler.
@MainActor
@Observable
final class SoftwareUpdater {
  nonisolated static let feedURL = "https://github.com/The-Witness-7879/wits-copy/releases/latest/download/appcast.xml"

  private(set) var automaticallyChecksForUpdates = true
  private(set) var canCheckForUpdates = false
  private(set) var isStarted = false

  @ObservationIgnored private var controller: SPUStandardUpdaterController?
  @ObservationIgnored private var automaticChecksObservation: NSKeyValueObservation?
  @ObservationIgnored private var availabilityObservation: NSKeyValueObservation?
  @ObservationIgnored private let feedDelegate = WitsCopyUpdateFeedDelegate()
  @ObservationIgnored private let windowGlass = UpdateWindowGlass()

  init() {
    // Never construct Sparkle in XCTest, previews, smoke/QA hosts, or another app's bundle.
    // In particular, a unit-test host must not schedule networking or touch production SU defaults.
    guard !LabRuntime.isIsolated, Bundle.main.bundleIdentifier == LabRuntime.bundleIdentifier else { return }

    let controller = SPUStandardUpdaterController(
      startingUpdater: false,
      updaterDelegate: feedDelegate,
      userDriverDelegate: windowGlass
    )
    self.controller = controller
    automaticChecksObservation = controller.updater.observe(
      \.automaticallyChecksForUpdates, options: [.initial, .new]
    ) { [weak self] updater, _ in
      MainActor.assumeIsolated {
        self?.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
      }
    }
    availabilityObservation = controller.updater.observe(
      \.canCheckForUpdates, options: [.initial, .new]
    ) { [weak self] updater, _ in
      MainActor.assumeIsolated {
        self?.canCheckForUpdates = updater.canCheckForUpdates
      }
    }
    // Default enablement and the one-day interval come from Info.plist, not setters
    // on every launch: an explicit user opt-out must survive subsequent launches.
    controller.startUpdater()
    isStarted = true
  }

  func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
    guard let updater = controller?.updater,
          updater.automaticallyChecksForUpdates != enabled else { return }
    updater.automaticallyChecksForUpdates = enabled
  }

  func checkForUpdates() {
    guard canCheckForUpdates else { return }
    controller?.checkForUpdates(nil)
  }
}

/// Pin the channel even if a legacy SUFeedURL exists in the preferences domain.
/// No runtime setter or alternate feed can redirect this fork to upstream Maccy.
final class WitsCopyUpdateFeedDelegate: NSObject, SPUUpdaterDelegate {
  func feedURLString(for updater: SPUUpdater) -> String? {
    SoftwareUpdater.feedURL
  }
}

/// Sparkle's update windows (update found, progress, ready to install) come
/// from its own nibs with an opaque window background. Each one gets the
/// clipboard panel's glass shell as it appears; Sparkle's layout is untouched.
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

  /// Sparkle builds the window right after this; adopt before the first paint
  /// where possible. The notifications above catch any window shown later.
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
