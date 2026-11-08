import AppKit
import PDFKit
import QuickLookUI
import SwiftUI

// MARK: - Quick Look host
//
// QLPreviewView.close() permanently refuses further preview items. The Lab crashes
// were updateNSView setting a non-nil item on a deactivated instance. This host never
// does that: URL/session changes allocate a new view; teardown nils, closes, and drops
// the instance. Public API only.

final class PreviewQLHost: NSView {
  private(set) var livePreview: QLPreviewView?
  private(set) var illegalNonNilAssignments = 0
  private(set) var installations = 0
  private var installedURL: URL?
  private var installedSession: String?
  private var closed = false

  func install(url: URL, sessionID: String, autostarts: Bool = false) {
    if closed { return }
    if installedURL == url, installedSession == sessionID, livePreview?.superview === self {
      return
    }
    retireLive()
    guard let preview = QLPreviewView(frame: bounds, style: .normal) else { return }
    preview.shouldCloseWithWindow = false
    preview.autostarts = autostarts
    preview.frame = bounds
    preview.autoresizingMask = [.width, .height]
    addSubview(preview)
    assign(url as NSURL, to: preview, closed: false)
    livePreview = preview
    installedURL = url
    installedSession = sessionID
    installations += 1
  }

  func retireLive() {
    guard let preview = livePreview else {
      installedURL = nil
      installedSession = nil
      return
    }
    assign(nil, to: preview, closed: false)
    preview.autostarts = false
    preview.close()
    preview.removeFromSuperview()
    livePreview = nil
    installedURL = nil
    installedSession = nil
  }

  func releaseAll() {
    closed = true
    retireLive()
  }

  private func assign(_ item: (any QLPreviewItem)?, to preview: QLPreviewView, closed: Bool) {
    if closed && item != nil {
      illegalNonNilAssignments += 1
      return
    }
    preview.previewItem = item
  }
}

struct QuickLookFileView: NSViewRepresentable {
  var url: URL
  var sessionID: String
  var autostarts = false

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> PreviewQLHost {
    let host = PreviewQLHost(frame: .zero)
    if !context.coordinator.disposed {
      host.install(url: url, sessionID: sessionID, autostarts: autostarts)
    }
    return host
  }

  func updateNSView(_ host: PreviewQLHost, context: Context) {
    guard !context.coordinator.disposed else { return }
    host.install(url: url, sessionID: sessionID, autostarts: autostarts)
  }

  static func dismantleNSView(_ host: PreviewQLHost, coordinator: Coordinator) {
    coordinator.disposed = true
    host.releaseAll()
  }

  final class Coordinator {
    var disposed = false
  }
}

// MARK: - GIF

final class GIFPlaybackView: NSView {
  private let imageView = NSImageView()
  private var task: Task<Void, Never>?
  private var retainedProvider: GIFFrameProvider?
  private var generation = 0
  private(set) var stopped = true

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    clipsToBounds = true
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.imageAlignment = .alignCenter
    imageView.frame = bounds
    imageView.autoresizingMask = [.width, .height]
    addSubview(imageView)
    setAccessibilityElement(true)
    setAccessibilityIdentifier("lab-gif-preview")
  }

  required init?(coder: NSCoder) { nil }

  func play(frames: [NSImage], timeline: GIFTimeline) {
    stop()
    guard !frames.isEmpty else { return }
    generation += 1
    let token = generation
    stopped = false
    let start = ContinuousClock.now
    task = Task { @MainActor in
      var shown = -1
      while !Task.isCancelled && self.generation == token {
        let elapsed = Self.seconds(from: start, to: .now)
        let index = min(timeline.frameIndex(at: elapsed), frames.count - 1)
        if index != shown {
          self.imageView.image = frames[index]
          shown = index
        }
        let wait = timeline.secondsUntilNextBoundary(after: Self.seconds(from: start, to: .now))
        try? await Task.sleep(nanoseconds: Self.nanos(wait))
      }
      if self.generation == token {
        self.stopped = true
      }
    }
  }

  func play(provider: GIFFrameProvider, timeline: GIFTimeline) {
    stop()
    guard provider.frameCount > 0 else { return }
    generation += 1
    let token = generation
    stopped = false
    retainedProvider = provider
    let start = ContinuousClock.now
    task = Task { @MainActor in
      var shown = -1
      while !Task.isCancelled && self.generation == token {
        let elapsed = Self.seconds(from: start, to: .now)
        let index = min(timeline.frameIndex(at: elapsed), provider.frameCount - 1)
        if index != shown {
          let cgImage = await provider.frame(at: index)
          if Task.isCancelled || self.generation != token { break }
          if let cgImage {
            self.imageView.image = NSImage(cgImage: cgImage, size: self.pointSize(cgImage))
            shown = index
          }
        }
        let wait = timeline.secondsUntilNextBoundary(after: Self.seconds(from: start, to: .now))
        try? await Task.sleep(nanoseconds: Self.nanos(wait))
      }
      if self.generation == token {
        self.finish(token: token)
      }
    }
  }

  func stop() {
    generation += 1
    task?.cancel()
    task = nil
    imageView.image = nil
    retainedProvider?.release()
    retainedProvider = nil
    stopped = true
  }

  private func finish(token: Int) {
    guard generation == token else { return }
    task = nil
    imageView.image = nil
    retainedProvider?.release()
    retainedProvider = nil
    stopped = true
  }

  private func pointSize(_ image: CGImage) -> NSSize {
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    return NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
  }

  private static func nanos(_ seconds: Double) -> UInt64 {
    guard seconds.isFinite, seconds > 0 else { return 100_000_000 }
    let value = min(seconds, 60) * 1_000_000_000
    return max(UInt64(value.rounded()), 1)
  }

  private static func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: end)
    return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }
}

struct GIFPreviewView: NSViewRepresentable {
  var frames: [NSImage]
  var provider: GIFFrameProvider?
  var timeline: GIFTimeline
  var playToken: Int

  init(provider: GIFFrameProvider, timeline: GIFTimeline, playToken: Int) {
    self.frames = []
    self.provider = provider
    self.timeline = timeline
    self.playToken = playToken
  }

  func makeNSView(context: Context) -> GIFPlaybackView {
    let view = GIFPlaybackView(frame: .zero)
    start(view, coordinator: context.coordinator)
    return view
  }

  func updateNSView(_ view: GIFPlaybackView, context: Context) {
    guard !context.coordinator.disposed else {
      view.stop()
      return
    }
    let providerChanged = context.coordinator.provider !== provider
    if providerChanged || context.coordinator.token != playToken {
      start(view, coordinator: context.coordinator)
    }
  }

  static func dismantleNSView(_ view: GIFPlaybackView, coordinator: Coordinator) {
    coordinator.disposed = true
    view.stop()
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  private func start(_ view: GIFPlaybackView, coordinator: Coordinator) {
    coordinator.token = playToken
    coordinator.provider = provider
    if let provider {
      view.play(provider: provider, timeline: timeline)
    } else {
      view.play(frames: frames, timeline: timeline)
    }
  }

  final class Coordinator {
    var disposed = false
    var token = -1
    var provider: GIFFrameProvider?
  }
}

// MARK: - PDF

struct PDFKitPreview: NSViewRepresentable {
  var document: PDFDocument
  var pageIndex: Int
  var scale: CGFloat

  func makeNSView(context: Context) -> CanvasPDFView {
    let view = CanvasPDFView()
    view.displayMode = .singlePage
    view.autoScales = false
    view.minScaleFactor = 0.01
    view.maxScaleFactor = 8
    view.document = document
    view.relativeScale = scale
    if let page = document.page(at: pageIndex) {
      view.go(to: page)
    }
    view.applyFittedScale()
    return view
  }

  func updateNSView(_ view: CanvasPDFView, context: Context) {
    guard !context.coordinator.disposed else { return }
    if view.document !== document {
      view.document = document
    }
    if let page = document.page(at: pageIndex), view.currentPage != page {
      view.go(to: page)
    }
    view.relativeScale = scale
    view.applyFittedScale()
  }

  static func dismantleNSView(_ view: CanvasPDFView, coordinator: Coordinator) {
    coordinator.disposed = true
    view.document = nil
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  final class Coordinator {
    var disposed = false
  }
}

/// Fits one page to the view, then applies the caller's zoom as a multiple of that fit.
final class CanvasPDFView: PDFView {
  var relativeScale: CGFloat = 1
  private var applied: CGFloat = -1

  override func layout() {
    super.layout()
    applyFittedScale()
  }

  func applyFittedScale() {
    guard bounds.width > 8, bounds.height > 8, document != nil else { return }
    let fit = scaleFactorForSizeToFit
    guard fit.isFinite, fit > 0.01 else { return }
    let target = min(max(fit * relativeScale, minScaleFactor), maxScaleFactor)
    guard abs(target - applied) > 0.015 || abs(scaleFactor - target) > 0.015 else { return }
    applied = target
    autoScales = false
    scaleFactor = target
  }
}

enum PreviewCanvasFit {
  static func size(_ image: CGSize, in canvas: CGSize) -> CGSize {
    guard image.width > 0, image.height > 0, canvas.width > 1, canvas.height > 1 else { return canvas }
    let scale = min(canvas.width / image.width, canvas.height / image.height)
    return CGSize(width: image.width * scale, height: image.height * scale)
  }
}

struct PreviewCanvasBox: NSViewRepresentable {
  func makeNSView(context: Context) -> PreviewCanvasView {
    PreviewCanvasView()
  }

  func updateNSView(_ view: PreviewCanvasView, context: Context) {}

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: PreviewCanvasView, context: Context) -> CGSize? {
    CGSize(width: max(proposal.width ?? 10, 1), height: max(proposal.height ?? 10, 1))
  }
}

final class PreviewCanvasView: NSView {
  let canvas = NSView()

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    canvas.setAccessibilityElement(true)
    canvas.setAccessibilityIdentifier("lab-preview-canvas")
    addSubview(canvas)
  }

  required init?(coder: NSCoder) { nil }

  override func layout() {
    super.layout()
    let inset = PreviewCanvasMetrics.inset
    canvas.frame = NSRect(
      x: inset,
      y: inset,
      width: max(1, bounds.width - inset * 2),
      height: max(1, bounds.height - inset * 2)
    )
  }
}

enum PreviewCanvasMetrics {
  static let inset: CGFloat = 16
}

struct FittedImageCanvas: NSViewRepresentable {
  var image: NSImage

  func makeNSView(context: Context) -> FittedImageHost {
    let host = FittedImageHost()
    host.image = image
    return host
  }

  func updateNSView(_ host: FittedImageHost, context: Context) {
    host.image = image
    host.needsLayout = true
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: FittedImageHost, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? nsView.bounds.width, height: proposal.height ?? nsView.bounds.height)
  }
}

final class FittedImageHost: NSView {
  let imageView = NSImageView()

  var image: NSImage? {
    didSet {
      imageView.image = image
      needsLayout = true
    }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.imageAlignment = .alignCenter
    imageView.setAccessibilityElement(true)
    imageView.setAccessibilityIdentifier("lab-image-preview")
    clipsToBounds = true
    addSubview(imageView)
  }

  required init?(coder: NSCoder) { nil }

  override func layout() {
    super.layout()
    guard let image, image.size.width > 0, image.size.height > 0, bounds.width > 1, bounds.height > 1 else {
      imageView.frame = bounds
      return
    }
    let fitted = PreviewCanvasFit.size(image.size, in: bounds.insetBy(dx: 0, dy: 0).size)
    let width = min(floor(fitted.width), bounds.width)
    let height = min(floor(fitted.height), bounds.height)
    imageView.frame = NSRect(
      x: (bounds.width - width) / 2,
      y: (bounds.height - height) / 2,
      width: width,
      height: height
    )
  }
}
