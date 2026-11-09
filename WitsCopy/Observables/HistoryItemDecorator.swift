import AppKit.NSPasteboard
import AppKit.NSWorkspace
import Defaults
import Foundation
import Observation
import Sauce

@Observable
class HistoryItemDecorator: Identifiable, Hashable, HasVisibility {
  static func == (lhs: HistoryItemDecorator, rhs: HistoryItemDecorator) -> Bool {
    return lhs.id == rhs.id
  }

  static var thumbnailImageSize: NSSize { NSSize(width: 340, height: Defaults[.imageMaxHeight]) }

  let id = UUID()
  /// Retained SwiftUI transition rows must never fault a deleted SwiftData model.
  private(set) var isRemoved = false

  @MainActor
  func prepareForRemoval() {
    isRemoved = true
    cleanupImages()
  }

  var title: String = ""
  var attributedTitle: AttributedString?

  var isVisible: Bool = true
  var selectionIndex: Int = -1
  var isSelected: Bool {
    return selectionIndex != -1
  }
  var shortcuts: [KeyShortcut] = []
  var tagRevision: Int = 0
  var contentRevision: Int = 0

  var application: String? {
    if item.application == LabRuntime.snippetSource {
      return NSLocalizedString("snippet_source", comment: "")
    }
    if item.universalClipboard {
      return "iCloud"
    }

    guard let bundle = item.application,
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
    else {
      return nil
    }

    return url.deletingPathExtension().lastPathComponent
  }

  var hasImage: Bool { item.hasImagePayload }

  var previewImageGenerationTask: Task<(), Never>?
  var thumbnailImageGenerationTask: Task<(), Never>?
  private var thumbnailGeneration = 0
  private var previewGeneration = 0
  var previewImage: NSImage?
  var previewText: String {
    item.previewableText
  }
  var thumbnailImage: NSImage?
  var applicationImage: ApplicationImage

  // 10k characters seems to be more than enough on large displays
  var text: String { previewText.shortened(to: 10_000) }

  var rowCaption: String {
    let source = application ?? NSLocalizedString("unknown_source", comment: "")
    let kind: String
    switch item.contentKind {
    case .text:
      kind = NSLocalizedString("kind_text", comment: "")
    case .image:
      kind = NSLocalizedString("kind_image", comment: "")
    case .video:
      kind = NSLocalizedString("kind_video", comment: "")
    case .audio:
      kind = NSLocalizedString("kind_audio", comment: "")
    case .file:
      kind = NSLocalizedString("kind_file", comment: "")
    }
    return "\(source) · \(kind)"
  }

  /// A bounded plain-text sample. Rich-only items already have a saved title;
  /// do not invoke the full HTML/RTF converter every time a row is laid out.
  var rowExcerpt: String {
    guard !isRemoved else { return "" }
    let contents = item.contents
    guard !contents.contains(where: { $0.type == NSPasteboard.PasteboardType.fileURL.rawValue }),
          let data = contents.first(where: { $0.type == NSPasteboard.PasteboardType.string.rawValue })?.value,
          !data.isEmpty else { return "" }
    let prefix = Data(data.prefix(1024))
    guard let decoded = PreviewClassifier.decodeUTF8(prefix, truncated: data.count > prefix.count) else { return "" }
    let body = String(decoded.prefix(180)).trimmingCharacters(in: .whitespacesAndNewlines)
    let shortTitle = String(title.prefix(180)).trimmingCharacters(in: .whitespacesAndNewlines)
    return body.isEmpty || body == shortTitle ? "" : body
  }

  var isPinned: Bool { item.pin != nil }
  var isUnpinned: Bool { item.pin == nil }

  func hash(into hasher: inout Hasher) {
    // Stable identity only. Title, highlight, and tagRevision are @Observable
    // and must not move this object inside a Set after insertion.
    hasher.combine(id)
  }

  private(set) var item: HistoryItem

  init(_ item: HistoryItem, shortcuts: [KeyShortcut] = []) {
    self.item = item
    self.shortcuts = shortcuts
    self.title = item.title
    self.applicationImage = ApplicationImageCache.shared.getImage(item: item)

    synchronizeItemPin()
    synchronizeItemTitle()
  }

  @MainActor
  func ensureThumbnailImage() {
    guard hasImage else { return }
    guard thumbnailImage == nil, thumbnailImageGenerationTask == nil else { return }
    thumbnailGeneration += 1
    let generation = thumbnailGeneration
    guard let payload = item.imagePayloadReference() else { return }
    let maxEdge = Int(max(Self.thumbnailImageSize.width, Self.thumbnailImageSize.height) * 2)
    thumbnailImageGenerationTask = Task { [weak self] in
      let cgImage = await Task.detached {
        switch payload {
        case .data(let data):
          return ImageProbe.downsample(data: data, maxEdge: maxEdge)
        case .file(let url):
          return ImageProbe.downsample(url: url, maxEdge: maxEdge, metrics: nil)
        }
      }.value
      guard let self, self.thumbnailGeneration == generation, !Task.isCancelled else { return }
      if let cgImage {
        let pixels = CGSize(width: cgImage.width, height: cgImage.height)
        self.thumbnailImage = NSImage(cgImage: cgImage, size: self.fittedPointSize(pixels, max: Self.thumbnailImageSize))
      }
      self.thumbnailImageGenerationTask = nil
    }
  }

  @MainActor
  func cleanupImages() {
    thumbnailGeneration += 1
    previewGeneration += 1
    thumbnailImageGenerationTask?.cancel()
    previewImageGenerationTask?.cancel()
    thumbnailImageGenerationTask = nil
    previewImageGenerationTask = nil
    thumbnailImage?.recache()
    previewImage?.recache()
    thumbnailImage = nil
    previewImage = nil
    item.clearDecodedImageCache()
  }

  @MainActor
  func beginThumbnailGenerationForTest() -> Int {
    thumbnailGeneration += 1
    return thumbnailGeneration
  }

  @MainActor
  func invalidateImageGenerationForTest() {
    thumbnailGeneration += 1
    previewGeneration += 1
  }

  @MainActor
  func commitThumbnailForTest(_ image: NSImage, generation: Int) {
    guard thumbnailGeneration == generation else { return }
    thumbnailImage = image
  }

  private func fittedPointSize(_ pixels: CGSize, max maxSize: NSSize) -> NSSize {
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    let points = NSSize(width: pixels.width / scale, height: pixels.height / scale)
    guard points.width > 0, points.height > 0 else { return points }
    let ratio = min(maxSize.width / points.width, maxSize.height / points.height, 1)
    return NSSize(width: points.width * ratio, height: points.height * ratio)
  }

  func highlight(_ query: String, _ ranges: [Range<String.Index>]) {
    guard !query.isEmpty, !title.isEmpty else {
      attributedTitle = nil
      return
    }

    var attributedString = AttributedString(title.shortened(to: 500))
    for range in ranges {
      if let lowerBound = AttributedString.Index(range.lowerBound, within: attributedString),
         let upperBound = AttributedString.Index(range.upperBound, within: attributedString) {
        switch Defaults[.highlightMatch] {
        case .bold:
          attributedString[lowerBound..<upperBound].font = .bold(.body)()
        case .italic:
          attributedString[lowerBound..<upperBound].font = .italic(.body)()
        case .underline:
          attributedString[lowerBound..<upperBound].underlineStyle = .single
        default:
          attributedString[lowerBound..<upperBound].backgroundColor = .findHighlightColor
          attributedString[lowerBound..<upperBound].foregroundColor = .black
        }
      }
    }

    attributedTitle = attributedString
  }

  @MainActor
  func noteTagsChanged() {
    tagRevision += 1
  }

  @MainActor
  func noteContentChanged() {
    contentRevision += 1
  }

  @MainActor
  func togglePin() {
    if item.pin != nil {
      item.pin = nil
    } else {
      let pin = HistoryItem.randomAvailablePin
      item.pin = pin
    }
  }

  private func synchronizeItemPin() {
    guard !isRemoved else { return }
    _ = withObservationTracking {
      item.pin
    } onChange: { [weak self] in
      DispatchQueue.main.async { [weak self] in
        guard let self, !self.isRemoved else { return }
        // Position shortcuts (1–9) belong to updateUnpinnedShortcuts. Writing []
        // here races that assignment and leaves the first unpinned row blank.
        if let pin = self.item.pin {
          self.shortcuts = pin.isEmpty ? [] : KeyShortcut.create(character: pin)
        }
        self.synchronizeItemPin()
      }
    }
  }

  private func synchronizeItemTitle() {
    guard !isRemoved else { return }
    _ = withObservationTracking {
      item.title
    } onChange: { [weak self] in
      DispatchQueue.main.async { [weak self] in
        guard let self, !self.isRemoved else { return }
        self.title = self.item.title
        self.synchronizeItemTitle()
      }
    }
  }
}
