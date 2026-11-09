import AppKit
import Foundation
import ImageIO
import Vision
import zlib

// MARK: - Limits and metrics

enum PreviewLimits {
  /// Display cap. The original clipboard/file copy is not rewritten.
  static let maxDisplayCharacters = 64_000
  static let maxHighlightCharacters = 80_000
  static let maxTextReadBytes = 4 * 1024 * 1024
  static let maxDocumentBytes = 32 * 1024 * 1024
  static let maxImageEdge = 2_048
  static let ocrMaxEdge = 1_600
  /// Bounded prefix for extensionless UTF-8/BOM sniff. Not a full-file read.
  static let textSniffBytes = 64 * 1024
  static let maxGIFFrames = 10_000
  static let maxDecodedFrameBytes = 32 * 1024 * 1024
  static let maxCachedGIFFrames = 3
  /// Only zero/missing GIF delays. A positive unclamped delay such as 0.01 is kept.
  static let zeroGIFDelay = 0.1
}

struct PreviewMetricSnapshot: Equatable {
  var previewStarts: Int
  var recognizerStarts: Int
  var fileReads: Int
  /// In-flight heavy jobs. Not the visible preview session.
  var activeHeavy: Int
  /// Peak of `activeHeavy`. Begin/cancel must not write this.
  var peakHeavy: Int
  var visibleSessions: Int
  var executingJobs: Int
  var peakJobs: Int
}

/// Preview, recognizer, and preview file reads only. List thumbnails must not touch this.
final class PreviewMetrics: @unchecked Sendable {
  private let lock = NSLock()
  private var previewStarts = 0
  private var recognizerStarts = 0
  private var fileReads = 0
  private var activeHeavy = 0
  private var peakHeavy = 0
  private var visibleSessions = 0
  private var executingJobs = 0
  private var peakJobs = 0

  func recordPreviewStart() {
    lock.lock()
    previewStarts += 1
    lock.unlock()
  }

  func recordRecognizerStart() {
    lock.lock()
    recognizerStarts += 1
    lock.unlock()
  }

  func recordFileRead() {
    lock.lock()
    fileReads += 1
    lock.unlock()
  }

  func setVisibleSessions(_ value: Int) {
    lock.lock()
    visibleSessions = value
    lock.unlock()
  }

  /// Real job bracket. The serial queue is what keeps the peak at one.
  func enterJob() {
    lock.lock()
    executingJobs += 1
    peakJobs = max(peakJobs, executingJobs)
    activeHeavy = executingJobs
    peakHeavy = peakJobs
    lock.unlock()
  }

  func leaveJob() {
    lock.lock()
    executingJobs = max(0, executingJobs - 1)
    activeHeavy = executingJobs
    lock.unlock()
  }

  func snapshot() -> PreviewMetricSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return PreviewMetricSnapshot(
      previewStarts: previewStarts,
      recognizerStarts: recognizerStarts,
      fileReads: fileReads,
      activeHeavy: activeHeavy,
      peakHeavy: peakHeavy,
      visibleSessions: visibleSessions,
      executingJobs: executingJobs,
      peakJobs: peakJobs
    )
  }
}

// MARK: - Kinds and value snapshot

enum PreviewRenderKind: String, Equatable, Sendable {
  case plain
  case code
  case markdown
  case image
  case gif
  case pdf
  case office
  case media
  case fallback
  case missing
}

enum PreviewTextMode: String, Equatable, Sendable {
  case plain
  case code
  case markdown
}

enum PreviewNotice: Equatable, Sendable {
  case truncated
  case oversize
  case missingReference
  case remoteImagesSkipped(Int)
  case officeExtracted
  case cannotDecode
  case systemPreviewUnavailable
}

struct PreviewRoute: Equatable, Sendable {
  var kind: PreviewRenderKind
  var notice: PreviewNotice?
  /// Extensionless bytes were probed and must not enter the text decoder.
  var textRejected: Bool
}

enum PreviewImagePayload: Equatable, Sendable {
  case data(Data)
  case file(URL)
}

struct PreviewSource: Equatable, Sendable {
  var identity: String
  var title: String
  var text: String?
  var image: PreviewImagePayload?
  var fileURLs: [URL]
  var filename: String?
  var fileExists: Bool?
  var application: String?
  var firstCopiedAt: Date
  var lastCopiedAt: Date
  var numberOfCopies: Int
  var pixelSize: CGSize?
}

enum PreviewSnapshotter {
  /// MainActor only. Copies SwiftData values. No FileManager, ImageIO, or model escape.
  @MainActor
  static func capture(
    _ item: HistoryItem,
    identity: String,
    application: String?
  ) -> PreviewSource {
    let urls = item.fileURLs
    let payload = item.imagePayloadReference()
    let text: String?
    if item.hasImagePayload || !urls.isEmpty {
      text = nil
    } else if let inline = item.text, !inline.isEmpty {
      text = inline
    } else if let rtf = item.rtf?.string, !rtf.isEmpty {
      text = rtf
    } else if let html = item.htmlData {
      text = HTMLTextStrip.plainText(html)
    } else {
      text = nil
    }
    return PreviewSource(
      identity: identity,
      title: item.title,
      text: text,
      image: payload,
      fileURLs: urls,
      filename: urls.first?.lastPathComponent,
      fileExists: nil,
      application: application,
      firstCopiedAt: item.firstCopiedAt,
      lastCopiedAt: item.lastCopiedAt,
      numberOfCopies: item.numberOfCopies,
      pixelSize: nil
    )
  }
}

enum PreviewClassifier {
  static func classify(source: PreviewSource, fileIndex: Int = 0) -> PreviewRenderKind {
    resolveRoute(source: source, fileIndex: fileIndex, sample: nil).kind
  }

  /// Product entry. Known extensions are unchanged. Extensionless files are a bounded
  /// UTF-8/BOM candidate so plain/code/markdown mode can attach; binary stays fallback.
  static func resolve(
    source: PreviewSource,
    fileIndex: Int = 0,
    metrics: PreviewMetrics,
    permit: PreviewReadPermit
  ) async -> PreviewRoute? {
    if permit.isCancelled || Task.isCancelled { return nil }
    if source.image != nil && source.fileURLs.isEmpty {
      return resolveRoute(source: source, fileIndex: fileIndex, sample: nil)
    }
    guard source.fileURLs.indices.contains(fileIndex) else {
      return resolveRoute(source: source, fileIndex: fileIndex, sample: nil)
    }
    let url = source.fileURLs[fileIndex]
    if source.fileExists == false && fileIndex == 0 {
      return PreviewRoute(kind: .missing, notice: .missingReference, textRejected: false)
    }
    if url.pathExtension.isEmpty == false {
      if let facts = await PreviewFileAccess.facts(
        url: url,
        includePixelSize: false,
        metrics: metrics,
        permit: permit
      ) {
        if facts.exists == false {
          return PreviewRoute(kind: .missing, notice: .missingReference, textRejected: false)
        }
      } else {
        return nil
      }
      return PreviewRoute(
        kind: kind(forExtension: url.pathExtension, filename: url.lastPathComponent),
        notice: nil,
        textRejected: false
      )
    }
    let sample = await PreviewFileAccess.read(
      url: url,
      limit: PreviewLimits.textSniffBytes,
      policy: .text,
      metrics: metrics,
      permit: permit
    )
    guard let sample else { return nil }
    if sample.readFailed {
      return PreviewRoute(kind: .fallback, notice: .cannotDecode, textRejected: true)
    }
    if sample.missing {
      return PreviewRoute(kind: .missing, notice: .missingReference, textRejected: false)
    }
    return sniffExtensionless(sample.data)
  }

  /// Sync route. Empty extension without a probed sample is fallback, never assumed text.
  static func resolveRoute(
    source: PreviewSource,
    fileIndex: Int,
    sample: Data?
  ) -> PreviewRoute {
    if let payload = source.image, source.fileURLs.isEmpty {
      return PreviewRoute(
        kind: kind(forImage: payload),
        notice: nil,
        textRejected: false
      )
    }
    guard source.fileURLs.indices.contains(fileIndex) else {
      if source.text != nil {
        return PreviewRoute(kind: .plain, notice: nil, textRejected: false)
      }
      return PreviewRoute(kind: .fallback, notice: nil, textRejected: false)
    }
    let url = source.fileURLs[fileIndex]
    if source.fileExists == false && fileIndex == 0 {
      return PreviewRoute(kind: .missing, notice: .missingReference, textRejected: false)
    }
    if url.pathExtension.isEmpty {
      guard let sample else {
        return PreviewRoute(kind: .fallback, notice: nil, textRejected: false)
      }
      return sniffExtensionless(sample)
    }
    return PreviewRoute(
      kind: kind(forExtension: url.pathExtension, filename: url.lastPathComponent),
      notice: nil,
      textRejected: false
    )
  }

  /// UTF-8 or UTF-8 BOM only. Binary magic, NUL, and invalid UTF-8 are not text.
  static func sniffExtensionless(_ data: Data) -> PreviewRoute {
    if isUTF8Text(data) {
      return PreviewRoute(kind: .plain, notice: nil, textRejected: false)
    }
    return PreviewRoute(kind: .fallback, notice: .cannotDecode, textRejected: true)
  }

  static func kind(filename: String?) -> PreviewRenderKind {
    kind(forExtension: (filename as NSString?)?.pathExtension ?? "", filename: filename)
  }

  static func languageLabel(filename: String?, mode: PreviewTextMode?) -> String {
    if let mode {
      switch mode {
      case .plain: return "Plain"
      case .markdown: return "Markdown"
      case .code: return codeLanguage(filename: filename) ?? "Code"
      }
    }
    switch kind(filename: filename) {
    case .markdown: return "Markdown"
    case .code: return codeLanguage(filename: filename) ?? "Code"
    default: return "Plain"
    }
  }

  static func codeLanguage(filename: String?) -> String? {
    switch (filename as NSString?)?.pathExtension.lowercased() {
    case "swift": return "Swift"
    case "py": return "Python"
    case "json": return "JSON"
    case "js", "jsx": return "JavaScript"
    case "ts", "tsx": return "TypeScript"
    case "rs": return "Rust"
    case "go": return "Go"
    case "rb": return "Ruby"
    case "java": return "Java"
    case "kt": return "Kotlin"
    case "c", "h": return "C"
    case "m", "mm": return "Objective-C"
    case "cpp", "cc", "hpp": return "C++"
    case "sh", "zsh": return "Shell"
    case "yml", "yaml": return "YAML"
    case "toml": return "TOML"
    case "css": return "CSS"
    case "html", "htm": return "HTML"
    case "xml": return "XML"
    case "sql": return "SQL"
    default: return nil
    }
  }

  private static func kind(forImage payload: PreviewImagePayload) -> PreviewRenderKind {
    switch payload {
    case .data(let data):
      if ImageProbe.isAnimatedGIF(data: data) { return .gif }
      if ImageProbe.isGIF(data: data) { return .image }
      return .image
    case .file(let url):
      return kind(forExtension: url.pathExtension, filename: url.lastPathComponent)
    }
  }

  private static func kind(forExtension ext: String, filename: String?) -> PreviewRenderKind {
    switch ext.lowercased() {
    case "gif": return .gif
    case "png", "jpg", "jpeg", "heic", "tif", "tiff", "bmp", "webp": return .image
    case "pdf": return .pdf
    case "doc", "docx", "docm": return .office
    case "md", "markdown", "mdown": return .markdown
    case "txt", "text", "log", "csv": return .plain
    case "mov", "mp4", "m4v", "avi", "mkv", "mp3", "m4a", "wav", "aac", "aiff": return .media
    default:
      if codeLanguage(filename: filename) != nil { return .code }
      return .fallback
    }
  }

  static func isUTF8Text(_ data: Data) -> Bool {
    if data.isEmpty { return true }
    if isBinaryMagic(data) { return false }
    var bytes = data
    if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
      bytes = bytes.dropFirst(3)
    }
    bytes = trimIncompleteUTF8Tail(bytes)
    if bytes.contains(0) { return false }
    guard let text = String(data: bytes, encoding: .utf8) else { return false }
    for scalar in text.unicodeScalars {
      let allowed = scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar == "\u{000C}"
      if scalar.value < 32 && !allowed { return false }
      if scalar == "\u{007F}" { return false }
    }
    return true
  }

  private static func isBinaryMagic(_ data: Data) -> Bool {
    let prefixes: [[UInt8]] = [
      [0x89, 0x50, 0x4E, 0x47],
      [0xFF, 0xD8, 0xFF],
      [0x47, 0x49, 0x46, 0x38],
      [0x25, 0x50, 0x44, 0x46],
      [0x50, 0x4B, 0x03, 0x04],
      [0x50, 0x4B, 0x05, 0x06],
      [0x7F, 0x45, 0x4C, 0x46],
      [0xFE, 0xFF],
      [0xFF, 0xFE],
      [0xD0, 0xCF, 0x11, 0xE0],
      [0x52, 0x49, 0x46, 0x46]
    ]
    for prefix in prefixes where data.starts(with: prefix) {
      return true
    }
    if data.count >= 12, data.subdata(in: 4..<8) == Data("ftyp".utf8) {
      return true
    }
    return false
  }

  static func decodeUTF8(_ data: Data, truncated: Bool = false) -> String? {
    if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
      return truncated ? nil : PreviewTextCodec.decodePlain(data)
    }
    let bytes = truncated ? trimIncompleteUTF8Tail(data) : data
    return PreviewTextCodec.decodePlain(bytes)
  }

  private static func trimIncompleteUTF8Tail(_ data: Data) -> Data {
    if data.isEmpty { return data }
    var index = data.endIndex - 1
    var continuation = 0
    while index >= data.startIndex && data[index] & 0xC0 == 0x80 {
      continuation += 1
      index -= 1
      if continuation > 3 { return data }
    }
    guard index >= data.startIndex else { return data }
    let lead = data[index]
    let expected: Int
    if lead & 0x80 == 0 { expected = 1 }
    else if lead & 0xE0 == 0xC0 { expected = 2 }
    else if lead & 0xF0 == 0xE0 { expected = 3 }
    else if lead & 0xF8 == 0xF0 { expected = 4 }
    else { return data }
    if continuation + 1 < expected {
      return data.prefix(index - data.startIndex)
    }
    return data
  }
}

// MARK: - Session

/// One visible preview at a time. Job peak comes from enter/leave, not from begin.
@MainActor
final class PreviewSession {
  let metrics: PreviewMetrics
  /// Visible session, 0 or 1. Not an executing decode/OCR/IO job.
  private(set) var activeHeavy = 0
  private(set) var currentToken: UInt64 = 0
  private var generation: UInt64 = 0
  private var activeToken: UInt64 = 0
  private var running = false
  private var work: Task<Void, Never>?
  private var recognition: PreviewRecognitionTicket?
  private var recognitionTask: Task<Void, Never>?
  private(set) var recognitionCancelCount = 0
  private var readPermit = PreviewReadPermit()
  var mediaStop: (() -> Void)?

  var visibleSessions: Int { activeHeavy }
  var currentReadPermit: PreviewReadPermit { readPermit }

  init(metrics: PreviewMetrics = PreviewMetrics()) {
    self.metrics = metrics
  }

  @discardableResult
  func begin(allowed: Bool, identity: String) -> UInt64? {
    invalidate()
    guard allowed, !identity.isEmpty else { return nil }
    generation &+= 1
    activeToken = generation
    currentToken = generation
    running = true
    activeHeavy = 1
    metrics.recordPreviewStart()
    metrics.setVisibleSessions(1)
    return activeToken
  }

  func cancel() {
    invalidate()
  }

  func isCurrent(_ token: UInt64) -> Bool {
    running && token == activeToken && token == generation
  }

  func trackRecognition(_ ticket: PreviewRecognitionTicket) {
    cancelRecognition()
    recognition = ticket
  }

  /// Cancels the Vision ticket and its task. Does not stop GIF or image playback.
  @discardableResult
  func cancelRecognition() -> Int {
    let ticket = recognition
    recognition = nil
    recognitionTask?.cancel()
    recognitionTask = nil
    ticket?.cancel()
    let count = ticket?.cancellationCount() ?? 0
    if ticket != nil {
      recognitionCancelCount += max(count, 1)
    }
    return count
  }

  /// Registers the Vision task. Hide/switch must call cancel/begin, not an untracked Task.
  func startRecognition(
    data: Data,
    token: UInt64,
    commit: @escaping @MainActor (Result<[OCRBlock], Error>) -> Void
  ) {
    guard isCurrent(token) else { return }
    cancelRecognition()
    let ticket = PreviewRecognitionTicket()
    recognition = ticket
    let metrics = self.metrics
    let task = Task { @MainActor in
      do {
        let blocks = try await PreviewRecognizer.recognize(
          data: data,
          metrics: metrics,
          ticket: ticket
        )
        guard self.isCurrent(token), !Task.isCancelled, ticket.cancellationCount() == 0 else { return }
        commit(.success(blocks))
      } catch is CancellationError {
        return
      } catch {
        guard self.isCurrent(token), !Task.isCancelled, ticket.cancellationCount() == 0 else { return }
        commit(.failure(error))
      }
    }
    recognitionTask = task
  }

  func deliver(token: UInt64, text: String, commit: (String) -> Void) -> Bool {
    guard isCurrent(token) else { return false }
    commit(text)
    return true
  }

  private func invalidate() {
    readPermit.cancel()
    readPermit = PreviewReadPermit()
    cancelRecognition()
    work?.cancel()
    work = nil
    mediaStop?()
    mediaStop = nil
    generation &+= 1
    activeToken = 0
    currentToken = 0
    if running || activeHeavy != 0 {
      running = false
      activeHeavy = 0
      metrics.setVisibleSessions(0)
    }
  }
}

// MARK: - File access
//
// FileHandle.read cannot be interrupted once started. Callers check the permit
// before enqueue and after return, and commit only on the main actor if the
// generation still matches. The serial queue keeps this off the main thread
// without spawning a thread per selection.

enum PreviewReadPolicy: Equatable, Sendable {
  /// Partial bytes may be returned. `truncated` must be shown; this buffer is not the copy.
  case text
  /// Over-limit files return empty `data`. Callers must not decode it.
  case complete
}

struct BoundedFileRead: Equatable, Sendable {
  var data: Data
  var totalBytes: Int
  var truncated: Bool
  var missing: Bool
  var refusedPartial: Bool = false
  var readFailed: Bool = false
}

struct PreviewFileFacts: Equatable, Sendable {
  var exists: Bool
  var byteCount: Int?
  var pixelSize: CGSize?
}

final class PreviewReadPermit: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
}

/// One heavy IO/decode/OCR job at a time. Cancellation is checked before a job starts.
actor PreviewHeavyQueue {
  static let shared = PreviewHeavyQueue()

  func perform<T>(
    metrics: PreviewMetrics?,
    _ body: () throws -> T
  ) async throws -> T {
    try Task.checkCancellation()
    metrics?.enterJob()
    defer { metrics?.leaveJob() }
    try Task.checkCancellation()
    return try body()
  }
}

enum PreviewFileAccess {
  /// Test seam. Product code must use `read` so the main actor does not wait on disk.
  static func readIfCurrent(
    url: URL,
    limit: Int,
    metrics: PreviewMetrics,
    isCurrent: () -> Bool
  ) -> BoundedFileRead? {
    guard isCurrent() else { return nil }
    let policy: PreviewReadPolicy = limit > PreviewLimits.maxTextReadBytes ? .complete : .text
    return readBounded(url: url, limit: limit, policy: policy, metrics: metrics)
  }

  static func read(
    url: URL,
    limit: Int,
    policy: PreviewReadPolicy,
    metrics: PreviewMetrics,
    permit: PreviewReadPermit
  ) async -> BoundedFileRead? {
    if permit.isCancelled || Task.isCancelled { return nil }
    do {
      return try await PreviewHeavyQueue.shared.perform(metrics: metrics) {
        if permit.isCancelled || Task.isCancelled { return nil }
        let value = readBounded(url: url, limit: limit, policy: policy, metrics: metrics)
        if permit.isCancelled || Task.isCancelled { return nil }
        return value
      }
    } catch {
      return nil
    }
  }

  static func facts(
    url: URL,
    includePixelSize: Bool,
    metrics: PreviewMetrics,
    permit: PreviewReadPermit
  ) async -> PreviewFileFacts? {
    if permit.isCancelled || Task.isCancelled { return nil }
    do {
      return try await PreviewHeavyQueue.shared.perform(metrics: metrics) {
        if permit.isCancelled || Task.isCancelled { return nil }
        let exists = FileManager.default.fileExists(atPath: url.path)
        let bytes = exists ? fileSize(url) : nil
        let pixel = exists && includePixelSize ? ImageProbe.pixelSize(url: url) : nil
        return PreviewFileFacts(exists: exists, byteCount: bytes, pixelSize: pixel)
      }
    } catch {
      return nil
    }
  }

  static func readBounded(
    url: URL,
    limit: Int,
    policy: PreviewReadPolicy,
    metrics: PreviewMetrics?
  ) -> BoundedFileRead {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return BoundedFileRead(data: Data(), totalBytes: 0, truncated: false, missing: true)
    }
    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values?.isRegularFile != false else {
      return BoundedFileRead(data: Data(), totalBytes: 0, truncated: false, missing: false, readFailed: true)
    }
    let known = values?.fileSize
    let capped = max(0, limit)
    let willRead: Bool
    if let known, known > capped, policy == .complete {
      willRead = false
    } else if let known {
      willRead = min(known, capped) > 0
    } else {
      willRead = capped > 0
    }
    if !willRead {
      return applyLimit(knownSize: known, limit: capped, policy: policy) { _ in Data() }
    }
    guard let handle = try? FileHandle(forReadingFrom: url) else {
      return BoundedFileRead(data: Data(), totalBytes: known ?? 0, truncated: false, missing: true)
    }
    defer { try? handle.close() }
    var readFailed = false
    var result = applyLimit(knownSize: known, limit: capped, policy: policy, metrics: metrics) { count in
      do { return try handle.read(upToCount: count) ?? Data() }
      catch { readFailed = true; return Data() }
    }
    if readFailed {
      result.readFailed = true
      result.truncated = false
    }
    return result
  }

  /// `read` is invoked only when bytes are required, and never for more than limit+1.
  static func applyLimit(
    knownSize: Int?,
    limit: Int,
    policy: PreviewReadPolicy,
    metrics: PreviewMetrics? = nil,
    read: (Int) -> Data
  ) -> BoundedFileRead {
    let limit = max(0, limit)
    if let knownSize, knownSize > limit, policy == .complete {
      return BoundedFileRead(
        data: Data(),
        totalBytes: knownSize,
        truncated: true,
        missing: false,
        refusedPartial: true
      )
    }
    let request: Int
    if let knownSize {
      request = min(knownSize, limit)
    } else {
      request = limit == Int.max ? limit : limit + 1
    }
    if request > 0 {
      metrics?.recordFileRead()
    }
    let raw = request > 0 ? read(request) : Data()
    if knownSize == nil, raw.count > limit {
      if policy == .complete {
        return BoundedFileRead(
          data: Data(),
          totalBytes: raw.count,
          truncated: true,
          missing: false,
          refusedPartial: true
        )
      }
      return BoundedFileRead(
        data: raw.prefix(limit),
        totalBytes: raw.count,
        truncated: true,
        missing: false
      )
    }
    let total = knownSize ?? raw.count
    return BoundedFileRead(
      data: raw,
      totalBytes: total,
      truncated: total > raw.count,
      missing: false
    )
  }

  static func fileSize(_ url: URL) -> Int? {
    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values?.isRegularFile != false else { return nil }
    return values?.fileSize
  }
}

// MARK: - ImageIO

enum ImageProbe {
  static func pixelSize(data: Data) -> CGSize? {
    guard let source = CGImageSourceCreateWithData(data as CFData, cacheOff) else { return nil }
    return pixelSize(source: source)
  }

  static func pixelSize(url: URL) -> CGSize? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, cacheOff) else { return nil }
    return pixelSize(source: source)
  }

  static func isGIF(data: Data) -> Bool {
    guard let source = CGImageSourceCreateWithData(data as CFData, cacheOff),
          let type = CGImageSourceGetType(source) else { return false }
    return UTTypeEqualsGIF(type as String)
  }

  static func isAnimatedGIF(data: Data) -> Bool {
    guard isGIF(data: data),
          let source = CGImageSourceCreateWithData(data as CFData, cacheOff) else { return false }
    return CGImageSourceGetCount(source) > 1
  }

  static func downsample(data: Data, maxEdge: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, cacheOff) else { return nil }
    return thumbnail(source: source, maxEdge: maxEdge)
  }

  static func downsample(url: URL, maxEdge: Int, metrics: PreviewMetrics?) -> CGImage? {
    metrics?.recordFileRead()
    guard let source = CGImageSourceCreateWithURL(url as CFURL, cacheOff) else { return nil }
    return thumbnail(source: source, maxEdge: maxEdge)
  }

  static func thumbnailFrame(source: CGImageSource, maxEdge: Int, index: Int) -> CGImage? {
    thumbnail(source: source, maxEdge: maxEdge, index: index)
  }

  private static var cacheOff: CFDictionary {
    [kCGImageSourceShouldCache: false] as CFDictionary
  }

  static func pixelSize(source: CGImageSource) -> CGSize? {
    guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
      return nil
    }
    guard let width = number(props[kCGImagePropertyPixelWidth]),
          let height = number(props[kCGImagePropertyPixelHeight]) else { return nil }
    return CGSize(width: width, height: height)
  }

  private static func thumbnail(source: CGImageSource, maxEdge: Int, index: Int = 0) -> CGImage? {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxEdge,
      kCGImageSourceShouldCacheImmediately: true
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
  }

  static func number(_ value: Any?) -> CGFloat? {
    switch value {
    case let number as NSNumber: return CGFloat(number.doubleValue)
    case let double as Double: return CGFloat(double)
    case let int as Int: return CGFloat(int)
    default: return nil
    }
  }

  private static func UTTypeEqualsGIF(_ raw: String) -> Bool {
    raw == "com.compuserve.gif" || raw == "public.gif"
  }
}

// MARK: - GIF timing

struct GIFTimeline: Equatable, Sendable {
  var rawDelays: [Double]
  var playbackDelays: [Double]
  var duration: Double

  static func resolve(unclamped: Double?, delay: Double?) -> Double {
    if let unclamped, unclamped.isFinite, unclamped > 0 { return unclamped }
    if let delay, delay.isFinite, delay > 0 { return delay }
    return PreviewLimits.zeroGIFDelay
  }

  static func read(data: Data) -> GIFTimeline? {
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
      return nil
    }
    let count = CGImageSourceGetCount(source)
    guard count > 0, count <= PreviewLimits.maxGIFFrames else { return nil }
    var raw: [Double] = []
    var playback: [Double] = []
    for index in 0..<count {
      guard !Task.isCancelled else { return nil }
      let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
      let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
      let unclamped = ImageProbe.number(gif?[kCGImagePropertyGIFUnclampedDelayTime]).map(Double.init)
      let delay = ImageProbe.number(gif?[kCGImagePropertyGIFDelayTime]).map(Double.init)
      let resolved = resolve(unclamped: unclamped, delay: delay)
      raw.append(unclamped ?? delay ?? 0)
      playback.append(resolved)
    }
    return GIFTimeline(rawDelays: raw, playbackDelays: playback, duration: playback.reduce(0, +))
  }

  func frameIndex(at elapsed: Double) -> Int {
    guard !playbackDelays.isEmpty else { return 0 }
    guard duration > 0 else { return 0 }
    var time = elapsed.truncatingRemainder(dividingBy: duration)
    if time < 0 { time += duration }
    var accumulated = 0.0
    for (index, delay) in playbackDelays.enumerated() {
      if time < accumulated + delay { return index }
      accumulated += delay
    }
    return 0
  }

  /// Remaining time until the next frame boundary. A positive 0.01 delay is not raised.
  func secondsUntilNextBoundary(after elapsed: Double) -> Double {
    guard !playbackDelays.isEmpty, duration > 0 else { return PreviewLimits.zeroGIFDelay }
    var time = elapsed.truncatingRemainder(dividingBy: duration)
    if time < 0 { time += duration }
    var accumulated = 0.0
    for delay in playbackDelays {
      let end = accumulated + delay
      if time < end {
        let remaining = end - time
        return remaining > 0 ? remaining : delay
      }
      accumulated = end
    }
    return playbackDelays[0]
  }
}

// MARK: - GIF frame provider
//
// Playback decodes the current frame only. A full-frame array is not the product path:
// ImageProbe.frames refuses a set that would exceed the decoded budget instead of
// returning a partial animation.

enum GIFLimitReason: String, Equatable, Sendable {
  case sourceTooLarge
  case tooManyFrames
  case decodedBudget
  case undecodable
}

enum GIFOpenResult {
  case stream(GIFFrameProvider)
  case staticFallback(CGImage, GIFLimitReason)
  case refused(GIFLimitReason)
}

enum GIFPlaybackPlan {
  case stream(GIFFrameProvider)
  case still(CGImage, PreviewNotice)
  case failed(PreviewNotice)
}

enum GIFFrameBudget {
  static func estimatedBytes(width: Int, height: Int, maxEdge: Int) -> Int {
    let longest = max(width, height, 1)
    let edge = max(1, maxEdge)
    let scale = min(1.0, Double(edge) / Double(longest))
    let outW = max(1, Int((Double(max(width, 1)) * scale).rounded(.up)))
    let outH = max(1, Int((Double(max(height, 1)) * scale).rounded(.up)))
    let row = (outW * 4 + 63) & ~63
    return row * outH
  }

  static func fittingEdge(width: Int, height: Int, budget: Int, preferred: Int) -> Int? {
    var edge = max(1, preferred)
    while edge >= 16 {
      if estimatedBytes(width: width, height: height, maxEdge: edge) <= budget {
        return edge
      }
      edge /= 2
    }
    return nil
  }
}

enum GIFPlayback {
  static func plan(
    data: Data,
    maxEdge: Int = PreviewLimits.maxImageEdge,
    metrics: PreviewMetrics? = nil
  ) -> GIFPlaybackPlan {
    switch GIFFrameProvider.open(data: data, maxEdge: maxEdge, metrics: metrics) {
    case .stream(let provider):
      return .stream(provider)
    case .staticFallback(let image, let reason):
      return .still(image, notice(reason))
    case .refused(let reason):
      return .failed(notice(reason))
    }
  }

  private static func notice(_ reason: GIFLimitReason) -> PreviewNotice {
    switch reason {
    case .undecodable: return .cannotDecode
    case .sourceTooLarge, .tooManyFrames, .decodedBudget: return .oversize
    }
  }
}

final class GIFFrameProvider: @unchecked Sendable {
  let frameCount: Int
  let timeline: GIFTimeline
  let fittedEdge: Int
  let fullDecodeFitsBudget: Bool
  private let metrics: PreviewMetrics?
  private let lock = NSLock()
  private var data: Data
  private var source: CGImageSource?
  private var cache: [Int: CGImage] = [:]
  private var order: [Int] = []
  private var cachedBytes = 0
  private var released = false
  private(set) var decodeCount = 0
  private(set) var cacheHits = 0
  private(set) var peakCachedBytes = 0

  var cachedFrameCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return cache.count
  }

  static func open(
    data: Data,
    maxEdge: Int = PreviewLimits.maxImageEdge,
    metrics: PreviewMetrics? = nil
  ) -> GIFOpenResult {
    if data.count > PreviewLimits.maxDocumentBytes {
      return .refused(.sourceTooLarge)
    }
    guard let source = CGImageSourceCreateWithData(
      data as CFData,
      [kCGImageSourceShouldCache: false] as CFDictionary
    ) else {
      return .refused(.undecodable)
    }
    let count = CGImageSourceGetCount(source)
    guard count > 0 else { return .refused(.undecodable) }
    let pixel = ImageProbe.pixelSize(source: source)
    let width = Int(pixel?.width ?? 0)
    let height = Int(pixel?.height ?? 0)
    let sizedWidth = width > 0 ? width : maxEdge
    let sizedHeight = height > 0 ? height : maxEdge
    guard let edge = GIFFrameBudget.fittingEdge(
      width: sizedWidth,
      height: sizedHeight,
      budget: PreviewLimits.maxDecodedFrameBytes,
      preferred: maxEdge
    ) else {
      return .refused(.decodedBudget)
    }
    if count > PreviewLimits.maxGIFFrames {
      if let still = ImageProbe.thumbnailFrame(source: source, maxEdge: edge, index: 0) {
        let cost = still.bytesPerRow * still.height
        if cost <= PreviewLimits.maxDecodedFrameBytes {
          return .staticFallback(still, .tooManyFrames)
        }
      }
      return .refused(.tooManyFrames)
    }
    guard let timeline = GIFTimeline.read(data: data), timeline.playbackDelays.count == count else {
      return .refused(.undecodable)
    }
    let one = GIFFrameBudget.estimatedBytes(width: sizedWidth, height: sizedHeight, maxEdge: edge)
    let oneFits = one > 0 && one <= PreviewLimits.maxDecodedFrameBytes
    let fits = oneFits && one * count <= PreviewLimits.maxDecodedFrameBytes
    let provider = GIFFrameProvider(
      data: data,
      source: source,
      frameCount: count,
      timeline: timeline,
      fittedEdge: edge,
      fullDecodeFitsBudget: fits,
      metrics: metrics
    )
    return .stream(provider)
  }

  private init(
    data: Data,
    source: CGImageSource,
    frameCount: Int,
    timeline: GIFTimeline,
    fittedEdge: Int,
    fullDecodeFitsBudget: Bool,
    metrics: PreviewMetrics?
  ) {
    self.data = data
    self.source = source
    self.frameCount = frameCount
    self.timeline = timeline
    self.fittedEdge = fittedEdge
    self.fullDecodeFitsBudget = fullDecodeFitsBudget
    self.metrics = metrics
  }

  func frame(at index: Int) async -> CGImage? {
    if isReleased { return nil }
    let metrics = self.metrics
    do {
      return try await PreviewHeavyQueue.shared.perform(metrics: metrics) {
        self.decode(index)
      }
    } catch {
      return nil
    }
  }

  /// Drops cached images immediately. Source is dropped on the serial queue after any in-flight decode.
  func release() {
    lock.lock()
    released = true
    cache.removeAll()
    order.removeAll()
    cachedBytes = 0
    lock.unlock()
    Task {
      try? await PreviewHeavyQueue.shared.perform(metrics: nil) {
        self.dropSource()
      }
    }
  }

  private var isReleased: Bool {
    lock.lock()
    defer { lock.unlock() }
    return released
  }

  private func decode(_ index: Int) -> CGImage? {
    guard index >= 0, index < frameCount else { return nil }
    lock.lock()
    if released {
      lock.unlock()
      return nil
    }
    if let hit = cache[index] {
      cacheHits += 1
      lock.unlock()
      return hit
    }
    guard let source else {
      lock.unlock()
      return nil
    }
    let edge = fittedEdge
    lock.unlock()
    guard let image = ImageProbe.thumbnailFrame(source: source, maxEdge: edge, index: index) else {
      return nil
    }
    let cost = image.bytesPerRow * image.height
    guard cost <= PreviewLimits.maxDecodedFrameBytes else { return nil }
    lock.lock()
    defer { lock.unlock() }
    if released { return nil }
    decodeCount += 1
    storeLocked(index, image, cost: cost)
    return cache[index]
  }

  private func storeLocked(_ index: Int, _ image: CGImage, cost: Int) {
    if let old = cache.removeValue(forKey: index) {
      cachedBytes -= old.bytesPerRow * old.height
      order.removeAll { $0 == index }
    }
    cache[index] = image
    order.append(index)
    cachedBytes += cost
    while cache.count > PreviewLimits.maxCachedGIFFrames || cachedBytes > PreviewLimits.maxDecodedFrameBytes,
          let oldest = order.first {
      order.removeFirst()
      if let removed = cache.removeValue(forKey: oldest) {
        cachedBytes -= removed.bytesPerRow * removed.height
      }
    }
    if cache[index] == nil, cost <= PreviewLimits.maxDecodedFrameBytes {
      cache = [index: image]
      order = [index]
      cachedBytes = cost
    }
    peakCachedBytes = max(peakCachedBytes, cachedBytes)
  }

  private func dropSource() {
    lock.lock()
    source = nil
    data = Data()
    cache.removeAll()
    order.removeAll()
    cachedBytes = 0
    lock.unlock()
  }
}

// MARK: - OCR

enum PreviewRecognitionError: Error {
  case undecodable
}

/// Thread-safe Vision cancel holder. Does not retain a SwiftData model.
final class PreviewRecognitionTicket: @unchecked Sendable {
  private let lock = NSLock()
  private var request: VNRecognizeTextRequest?
  private var child: Task<[OCRBlock], Error>?
  private var cancelCount = 0

  func attach(_ request: VNRecognizeTextRequest) {
    lock.lock()
    self.request = request
    lock.unlock()
  }

  func detach() {
    lock.lock()
    request = nil
    lock.unlock()
  }

  func attachChild(_ child: Task<[OCRBlock], Error>) {
    lock.lock()
    self.child = child
    lock.unlock()
  }

  func detachChild() {
    lock.lock()
    child = nil
    lock.unlock()
  }

  func cancellationCount() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return cancelCount
  }

  func cancel() {
    lock.lock()
    cancelCount += 1
    let request = self.request
    let child = self.child
    lock.unlock()
    request?.cancel()
    child?.cancel()
  }
}

enum PreviewRecognizer {
  private static let prewarmLock = NSLock()
  private static var prewarmed = false

  /// 打开图片预览时调用一次。系统识别模型首次使用要先加载（实测冷态可达二十多秒），
  /// 提前在后台用一张带字的小图跑一遍，用户点「识别文字」时就不用再等。
  /// 每个进程只做一次；不读用户内容，不写任何状态，结果丢弃。
  static func prewarm() {
    prewarmLock.lock()
    let first = !prewarmed
    prewarmed = true
    prewarmLock.unlock()
    guard first else { return }
    DispatchQueue.global(qos: .utility).async {
      guard let image = prewarmImage() else { return }
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = true
      request.automaticallyDetectsLanguage = true
      request.recognitionLanguages = recognitionLanguages()
      try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    }
  }

  /// 有文字的小图：空白图可能在检测阶段就结束，触发不到识别模型的加载。
  private static func prewarmImage() -> CGImage? {
    let size = NSSize(width: 160, height: 40)
    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    ("Aa 文字 123" as NSString).draw(at: NSPoint(x: 8, y: 8), withAttributes: [
      .font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black
    ])
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage
  }

  static func recognitionLanguages() -> [String] {
    let probe = VNRecognizeTextRequest()
    let supported = (try? probe.supportedRecognitionLanguages()) ?? ["en-US"]
    let preferred = ["zh-Hans", "zh-Hant", "en-US"]
    let chosen = preferred.filter { supported.contains($0) }
    return chosen.isEmpty ? ["en-US"] : chosen
  }

  /// Real Vision on a value. Does not read titles, filenames, or SwiftData models.
  static func recognize(
    data: Data,
    metrics: PreviewMetrics,
    ticket: PreviewRecognitionTicket? = nil
  ) async throws -> [OCRBlock] {
    let ticket = ticket ?? PreviewRecognitionTicket()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      let child = Task { () throws -> [OCRBlock] in
        try Task.checkCancellation()
        return try await PreviewHeavyQueue.shared.perform(metrics: metrics) {
          try Task.checkCancellation()
          metrics.recordRecognizerStart()
          let languages = recognitionLanguages()
          guard let cgImage = ImageProbe.downsample(data: data, maxEdge: PreviewLimits.ocrMaxEdge) else {
            throw PreviewRecognitionError.undecodable
          }
          try Task.checkCancellation()
          let request = VNRecognizeTextRequest()
          ticket.attach(request)
          defer { ticket.detach() }
          request.recognitionLevel = .accurate
          request.usesLanguageCorrection = true
          request.automaticallyDetectsLanguage = true
          request.recognitionLanguages = languages
          let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
          try handler.perform([request])
          try Task.checkCancellation()
          let observations = (request.results ?? []).compactMap { observation -> OCRObservationBox? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            return OCRObservationBox(
              text: text,
              minX: box.minX,
              minY: box.minY,
              maxX: box.maxX,
              maxY: box.maxY
            )
          }
          return OCRReadingOrder.blocks(from: observations)
        }
      }
      ticket.attachChild(child)
      defer { ticket.detachChild() }
      return try await child.value
    } onCancel: {
      ticket.cancel()
    }
  }
}

// MARK: - DOCX

enum OfficeTextExtractor {
  static func extractDocx(_ data: Data) -> String? {
    guard let xml = ZipArchive.extract(data, named: "word/document.xml"),
          let text = String(data: xml, encoding: .utf8) else { return nil }
    let plain = DocxXML.plainText(text)
    return plain.isEmpty ? nil : plain
  }
}

enum DocxXML {
  static func plainText(_ xml: String) -> String {
    var paragraphs: [String] = []
    var current = ""
    var index = xml.startIndex
    while index < xml.endIndex {
      if xml[index...].hasPrefix("</w:p>") {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { paragraphs.append(trimmed) }
        current = ""
        index = xml.index(index, offsetBy: 6)
        continue
      }
      if xml[index...].hasPrefix("<w:t") {
        guard let open = xml[index...].firstIndex(of: ">") else { break }
        let contentStart = xml.index(after: open)
        guard let close = xml[contentStart...].range(of: "</w:t>") else { break }
        current += decodeEntities(String(xml[contentStart..<close.lowerBound]))
        index = close.upperBound
        continue
      }
      index = xml.index(after: index)
    }
    let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
    if !tail.isEmpty { paragraphs.append(tail) }
    return paragraphs.joined(separator: "\n")
  }

  private static func decodeEntities(_ raw: String) -> String {
    raw
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&apos;", with: "'")
      .replacingOccurrences(of: "&amp;", with: "&")
  }
}

enum ZipArchive {
  static func extract(_ data: Data, named wanted: String) -> Data? {
    guard let eocd = findEOCD(data) else { return nil }
    var offset = eocd.cdOffset
    let end = min(data.count, eocd.cdOffset + eocd.cdSize)
    while offset + 46 <= end {
      guard readU32(data, offset) == 0x02014b50 else { return nil }
      let method = readU16(data, offset + 10)
      let compSize = readU32(data, offset + 20)
      let uncompSize = readU32(data, offset + 24)
      let nameLen = readU16(data, offset + 28)
      let extraLen = readU16(data, offset + 30)
      let commentLen = readU16(data, offset + 32)
      let localOffset = readU32(data, offset + 42)
      let nameStart = offset + 46
      let nameEnd = nameStart + nameLen
      guard nameEnd <= data.count else { return nil }
      let name = String(data: data.subdata(in: nameStart..<nameEnd), encoding: .utf8) ?? ""
      if name == wanted {
        return inflateLocal(
          data,
          localOffset: localOffset,
          method: method,
          compSize: compSize,
          uncompSize: uncompSize
        )
      }
      offset = nameEnd + extraLen + commentLen
    }
    return nil
  }

  private struct EOCD {
    var cdSize: Int
    var cdOffset: Int
  }

  private static func findEOCD(_ data: Data) -> EOCD? {
    let min = max(0, data.count - 22 - 65_535)
    var index = data.count - 22
    while index >= min {
      if readU32(data, index) == 0x06054b50 {
        return EOCD(cdSize: readU32(data, index + 12), cdOffset: readU32(data, index + 16))
      }
      index -= 1
    }
    return nil
  }

  private static func inflateLocal(
    _ data: Data,
    localOffset: Int,
    method: Int,
    compSize: Int,
    uncompSize: Int
  ) -> Data? {
    guard localOffset + 30 <= data.count, readU32(data, localOffset) == 0x04034b50 else { return nil }
    let nameLen = readU16(data, localOffset + 26)
    let extraLen = readU16(data, localOffset + 28)
    let start = localOffset + 30 + nameLen + extraLen
    let end = start + compSize
    guard end <= data.count, uncompSize >= 0 else { return nil }
    let compressed = data.subdata(in: start..<end)
    if method == 0 { return compressed }
    guard method == 8 else { return nil }
    return inflateRaw(compressed, expected: uncompSize)
  }

  private static func inflateRaw(_ compressed: Data, expected: Int) -> Data? {
    guard expected > 0, expected < 8 * 1024 * 1024 else { return nil }
    return compressed.withUnsafeBytes { raw in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
      var stream = z_stream()
      let initStatus = inflateInit2_(
        &stream,
        -MAX_WBITS,
        ZLIB_VERSION,
        Int32(MemoryLayout<z_stream>.size)
      )
      guard initStatus == Z_OK else { return nil }
      defer { inflateEnd(&stream) }
      var output = Data(count: expected)
      let finished = output.withUnsafeMutableBytes { outRaw -> Bool in
        guard let destination = outRaw.bindMemory(to: UInt8.self).baseAddress else { return false }
        stream.next_in = UnsafeMutablePointer(mutating: base)
        stream.avail_in = uInt(compressed.count)
        stream.next_out = destination
        stream.avail_out = uInt(expected)
        return inflate(&stream, Z_FINISH) == Z_STREAM_END
      }
      return finished ? output : nil
    }
  }

  private static func readU16(_ data: Data, _ offset: Int) -> Int {
    guard offset + 2 <= data.count else { return 0 }
    return Int(data[offset]) | (Int(data[offset + 1]) << 8)
  }

  private static func readU32(_ data: Data, _ offset: Int) -> Int {
    guard offset + 4 <= data.count else { return 0 }
    return Int(data[offset])
      | (Int(data[offset + 1]) << 8)
      | (Int(data[offset + 2]) << 16)
      | (Int(data[offset + 3]) << 24)
  }
}

enum HTMLTextStrip {
  static func plainText(_ data: Data) -> String {
    guard let raw = PreviewTextCodec.decodePlain(data) else {
      return ""
    }
    var output = ""
    var inTag = false
    for scalar in raw.unicodeScalars {
      if scalar == "<" { inTag = true; continue }
      if scalar == ">" { inTag = false; continue }
      if !inTag { output.unicodeScalars.append(scalar) }
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
