import Foundation

enum PreviewToolKind: String, Equatable {
  case wrap
  case lineNumbers
  case recognize
  case pdfZoomOut
  case pdfZoomIn
  case pdfPrevious
  case pdfNext
  case systemPreview
}

enum PreviewToolStrip {
  /// Tools that belong in the strip above the canvas. Empty means no strip,
  /// so the row cannot cover content that has no tools.
  static func tools(kind: String, hasSystemURL: Bool = false) -> [PreviewToolKind] {
    switch kind {
    case "plain", "markdown":
      return [.wrap]
    case "code":
      return [.wrap, .lineNumbers]
    case "image", "gif":
      return [.recognize]
    case "pdf":
      return [.pdfZoomOut, .pdfZoomIn, .pdfPrevious, .pdfNext]
    case "media":
      return []
    case "fallback", "office":
      return hasSystemURL ? [.systemPreview] : []
    default:
      return []
    }
  }
}

enum DeleteItemConfirmation {
  /// Literal name for later unification into Defaults.Keys+Names.
  /// Not `suppressClearAlert` and not `suppressQuitAlert`.
  static let suppressKeyName = "suppressDeleteItemAlert"

  static func shouldPrompt(suppressed: Bool) -> Bool {
    !suppressed
  }
}

enum RichRepresentation {
  /// Identifies the rich representations removed by a body save.
  static func isRich(_ type: String) -> Bool {
    let lower = type.lowercased()
    if lower.contains("plain-text") || lower == "nsstringpboardtype" || lower == "public.utf8-plain-text" {
      return false
    }
    if lower.contains("utf-16") || lower.contains("utf16") || lower.contains("utf-8") || lower.contains("utf8") {
      return false
    }
    return lower.contains("rtf")
      || lower.contains("html")
      || lower.contains("webarchive")
      || lower.contains("richtext")
      || lower.contains("flat-rtfd")
  }
}
