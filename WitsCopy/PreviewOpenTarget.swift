import Foundation

/// What the whole of a clipboard entry points at: one web page or one path
/// on disk.
///
/// Detection is deliberately strict. The entire trimmed text has to be the
/// target, so prose that merely mentions a link stays prose, and a path is
/// only offered once it is really on disk.
enum PreviewOpenTarget: Equatable {
  case web(URL)
  case file(URL, isDirectory: Bool)

  /// Disk check seam. Tests resolve paths without touching the file system.
  struct FileProbe: Sendable {
    var exists: @Sendable (URL) -> Bool
    var isDirectory: @Sendable (URL) -> Bool

    static let live = FileProbe(
      exists: { FileManager.default.fileExists(atPath: $0.path) },
      isDirectory: { url in
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
          return false
        }
        return isDirectory.boolValue
      }
    )
  }

  static func resolve(_ text: String?, probe: FileProbe = .live) -> PreviewOpenTarget? {
    guard let text else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let web = webTarget(trimmed) { return web }
    guard let url = fileCandidate(trimmed), probe.exists(url) else { return nil }
    return .file(url, isDirectory: probe.isDirectory(url))
  }

  private static func webTarget(_ text: String) -> PreviewOpenTarget? {
    let lower = text.lowercased()
    guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
    // A link is one token: whitespace or a newline ends it, which keeps
    // "see https://example.com for details" from becoming a button.
    guard !text.contains(where: { $0.isWhitespace }) else { return nil }
    guard let url = URL(string: text),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = url.host,
          !host.isEmpty else { return nil }
    return .web(url)
  }

  private static func fileCandidate(_ text: String) -> URL? {
    // A path is one line. Spaces inside a name are legal, newlines are not.
    guard !text.contains(where: { $0.isNewline }) else { return nil }
    if text.lowercased().hasPrefix("file://") {
      guard let url = URL(string: text), url.isFileURL, url.path.hasPrefix("/"),
            url.query == nil, url.fragment == nil else { return nil }
      return url
    }
    if text.hasPrefix("~/") {
      return URL(fileURLWithPath: (text as NSString).expandingTildeInPath)
    }
    if text.hasPrefix("/") {
      return URL(fileURLWithPath: text)
    }
    return nil
  }
}
