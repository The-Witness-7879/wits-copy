import AppKit
import Defaults
import Sauce
import SwiftData
import UniformTypeIdentifiers

@Model
class HistoryItem {
  static var supportedPins: Set<String> {
    // "a" reserved for select all
    // "q" reserved for quit
    // "v" reserved for paste
    // "w" reserved for close window
    // "z" reserved for undo/redo
    var keys = Set([
      "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l",
      "m", "n", "o", "p", "r", "s", "t", "u", "x", "y"
    ])

    if let deleteKey = KeyChord.deleteKey,
       let character = Sauce.shared.character(for: Int(deleteKey.QWERTYKeyCode), cocoaModifiers: []) {
      keys.remove(character)
    }

    if let pinKey = KeyChord.pinKey,
       let character = Sauce.shared.character(for: Int(pinKey.QWERTYKeyCode), cocoaModifiers: []) {
      keys.remove(character)
    }
    if let tagKey = KeyChord.tagKey,
       let character = Sauce.shared.character(for: Int(tagKey.QWERTYKeyCode), cocoaModifiers: []) {
      keys.remove(character)
    }
    if let previewKey = KeyChord.previewKey,
       let character = Sauce.shared.character(for: Int(previewKey.QWERTYKeyCode), cocoaModifiers: []) {
      keys.remove(character)
    }

    return keys
  }

  @MainActor
  static var availablePins: [String] {
    availablePins(in: History.shared.all.compactMap {
      if $0.isPinned { return $0.item }
      return nil
    })
  }

  @MainActor
  static func availablePins(in items: [HistoryItem]) -> [String] {
    let assignedPins = Set(items.compactMap(\.pin))
    return Array(supportedPins.subtracting(assignedPins))
  }

  @MainActor
  static var randomAvailablePin: String { availablePins.randomElement() ?? "" }

  private static let transientTypes: [String] = [
    NSPasteboard.PasteboardType.modified.rawValue,
    NSPasteboard.PasteboardType.fromWitsCopy.rawValue,
    NSPasteboard.PasteboardType.linkPresentationMetadata.rawValue,
    NSPasteboard.PasteboardType.customWebKitPasteboardData.rawValue,
    NSPasteboard.PasteboardType.source.rawValue,
    NSPasteboard.PasteboardType.customChromiumWebData.rawValue,
    NSPasteboard.PasteboardType.chromiumSourceUrl.rawValue,
    NSPasteboard.PasteboardType.chromiumSourceToken.rawValue,
    NSPasteboard.PasteboardType.notesRichText.rawValue
  ]
  private static let imageTypes: [NSPasteboard.PasteboardType] = StorageType.images.types

  var application: String?
  var firstCopiedAt: Date = Date.now
  var lastCopiedAt: Date = Date.now
  var numberOfCopies: Int = 1
  var pin: String?
  var tags: [String] = []
  var title = ""

  static let maxTagLength = 32

  static func normalizedTag(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= maxTagLength else { return nil }
    guard trimmed.allSatisfy({ !$0.isWhitespace }) else { return nil }
    return trimmed
  }

  /// Case-insensitive union. Existing spellings win. Copies, so deleting the old item cannot clear the new one.
  static func unionTags(_ existing: [String], _ incoming: [String]) -> [String] {
    var result: [String] = []
    for raw in existing + incoming {
      guard let name = normalizedTag(raw) else { continue }
      if result.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { continue }
      result.append(name)
    }
    return result
  }

  var isDisposable: Bool { pin == nil && tags.isEmpty }

  enum ContentKind: String {
    case text
    case image
    case video
    case audio
    case file
  }

  /// Image payload wins. A movie is a file URL whose extension conforms to `movie` or `video`.
  /// Extension only — do not read or decode the file. png/jpeg stay image; pdf/txt stay file.
  var contentKind: ContentKind {
    if hasImagePayload { return .image }
    if fileURLs.contains(where: Self.isMovieFile) { return .video }
    if fileURLs.contains(where: Self.isAudioFile) { return .audio }
    if !fileURLs.isEmpty { return .file }
    return .text
  }

  static func isMovieFile(_ url: URL) -> Bool {
    let ext = url.pathExtension
    guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
    return type.conforms(to: .movie) || type.conforms(to: .video)
  }

  /// Sound-only files: mp3, m4a, wav, aiff, flac… A movie with sound stays video.
  static func isAudioFile(_ url: URL) -> Bool {
    let ext = url.pathExtension
    guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
    return type.conforms(to: .audio) && !isMovieFile(url)
  }

  @Relationship(deleteRule: .cascade, inverse: \HistoryItemContent.item)
  var contents: [HistoryItemContent] = []

  @Transient private var cachedDecodedImage: NSImage?
  @Transient private var imageMaterializationCount = 0

  /// Times `image` actually decoded. Preview classification must not increment this.
  var imageMaterializations: Int { imageMaterializationCount }

  var hasImagePayload: Bool {
    if contents.contains(where: { content in
      Self.imageTypes.contains(NSPasteboard.PasteboardType(content.type)) && !(content.value?.isEmpty ?? true)
    }) {
      return true
    }
    return universalClipboardImage
  }

  /// Value copy for background work. Does not decode a bitmap and does not leave the model.
  func imagePayloadReference() -> PreviewImagePayload? {
    if let data = contentData(Self.imageTypes), !data.isEmpty {
      return .data(data)
    }
    if universalClipboardImage, let url = fileURLs.first {
      return .file(url)
    }
    return nil
  }

  init(contents: [HistoryItemContent] = []) {
    self.firstCopiedAt = firstCopiedAt
    self.lastCopiedAt = lastCopiedAt
    self.contents = contents
  }

  func supersedes(_ item: HistoryItem) -> Bool {
    return item.contents
      .filter { content in
        !Self.transientTypes.contains(content.type)
      }
      .allSatisfy { content in
        contents.contains(where: { $0.type == content.type && $0.value == content.value })
      }
  }

  func generateTitle() -> String {
    // Images are not OCR'd here. Recognition is an explicit preview action and must not
    // overwrite a manual title, or run Vision on the model from this call.
    if hasImagePayload {
      return title
    }

    // 1k characters is trade-off for performance
    var title = previewableText.shortened(to: 1_000)

    if Defaults[.showSpecialSymbols] {
      if let range = title.range(of: "^ +", options: .regularExpression) {
        title = title.replacingOccurrences(of: " ", with: "·", range: range)
      }
      if let range = title.range(of: " +$", options: .regularExpression) {
        title = title.replacingOccurrences(of: " ", with: "·", range: range)
      }
      title = title
        .replacingOccurrences(of: "\n", with: "⏎")
        .replacingOccurrences(of: "\t", with: "⇥")
    } else {
      title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return title
  }

  var previewableText: String {
    if !fileURLs.isEmpty {
      fileURLs
        .compactMap { $0.absoluteString.removingPercentEncoding }
        .joined(separator: "\n")
    } else if let text = text, !text.isEmpty {
      text
    } else if let rtf = rtf, !rtf.string.isEmpty {
      rtf.string
    } else if let html = html, !html.string.isEmpty {
      html.string
    } else {
      title
    }
  }

  var fileURLs: [URL] {
    guard !universalClipboardText else {
      return []
    }

    return allContentData([.fileURL])
      .compactMap { URL(dataRepresentation: $0, relativeTo: nil, isAbsolute: true) }
  }

  var htmlData: Data? { contentData([.html]) }
  /// Display text only. Stored HTML bytes stay on `htmlData`.
  /// Uses the verified codec and tag strip. Does not call `NSAttributedString(html:)`,
  /// which turns charset-less UTF-8 into mojibake (`中文` → `涓枃`).
  var html: NSAttributedString? {
    guard let data = htmlData else { return nil }
    let plain = HTMLTextStrip.plainText(data)
    guard !plain.isEmpty else { return nil }
    return NSAttributedString(string: plain)
  }

  var imageData: Data? {
    var data: Data?
    data = contentData(Self.imageTypes)
    if data == nil, universalClipboardImage, let url = fileURLs.first {
      data = try? Data(contentsOf: url)
    }

    return data
  }

  var image: NSImage? {
    if let img = cachedDecodedImage {
      return img
    }
    guard let data = imageData else {
      return nil
    }

    imageMaterializationCount += 1
    cachedDecodedImage = NSImage(data: data)
    return cachedDecodedImage
  }

  var rtfData: Data? { contentData([.rtf]) }
  var rtf: NSAttributedString? {
    guard let data = rtfData else {
      return nil
    }

    return NSAttributedString(rtf: data, documentAttributes: nil)
  }

  func clearDecodedImageCache() {
    cachedDecodedImage?.recache()
    cachedDecodedImage = nil
  }

  var text: String? {
    let pairs = contents.compactMap { item -> (type: String, value: Data)? in
      guard let value = item.value else { return nil }
      return (item.type, value)
    }
    return PreviewTextCodec.reliablePlain(pairs, isPlain: RichTextTypes.isPlain)
  }

  var modified: Int? {
    guard let data = contentData([.modified]),
          let modified = String(data: data, encoding: .utf8) else {
      return nil
    }

    return Int(modified)
  }

  var fromWitsCopy: Bool { contentData([.fromWitsCopy]) != nil }
  var universalClipboard: Bool { contentData([.universalClipboard]) != nil }

  private var universalClipboardImage: Bool { universalClipboard && fileURLs.first?.pathExtension == "jpeg" }
  private var universalClipboardText: Bool {
    universalClipboard && contentData([.html, .tiff, .png, .jpeg, .rtf, .string, .heic]) != nil
  }

  private func contentData(_ types: [NSPasteboard.PasteboardType]) -> Data? {
    let content = contents.first(where: { content in
      return types.contains(NSPasteboard.PasteboardType(content.type))
    })

    return content?.value
  }

  private func allContentData(_ types: [NSPasteboard.PasteboardType]) -> [Data] {
    return contents
      .filter { types.contains(NSPasteboard.PasteboardType($0.type)) }
      .compactMap { $0.value }
  }

}
