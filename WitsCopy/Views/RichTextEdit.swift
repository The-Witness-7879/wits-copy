import AppKit
import SwiftUI

// Read-only rich display plus a plain-text draft. This file does not write
// HistoryItem, AppState, or the pasteboard, and it is not mounted by PreviewItemView.
//
// Unedited body, title-only save, and cancel do not change stored bytes.
// A body change that the integrator commits is plain text: apply every
// columnChanges entry together, or apply none. Do not call OriginalTextPayload.sync
// for this save — that updates plain columns and leaves RTF/HTML in place, so copy
// still pastes the old rich text.
//
// Do not call this from list-row layout. Snapshot text stays plain-first.

enum RichTextLimits {
  static var maxEditableCharacters: Int { PreviewLimits.maxDisplayCharacters }
  static var maxEditableBytes: Int { PreviewLimits.maxTextReadBytes }
  static let maxHTMLNodes = 20_000
}

enum RichTextRefusal: Equatable, Sendable {
  case removed
  case fileBacked
  case image
  case media
  case notRich
  case missing
  case undecodable
  case oversized
  case truncatedPreview
  case conflict
  case empty
  case stale
}

enum RichTextPresentation: Equatable, Sendable {
  case richText
  case readableText
}

enum RichTextRisk: Equatable, Sendable {
  case remoteResource
  case executableMarkup
  case unsupportedStructure
  case undecodable
  case oversized
  case truncated
}

struct RichTextRepresentation: Equatable, Hashable, Sendable {
  var type: String
  var value: Data
}

struct RichTextSource: Equatable, Sendable {
  var representations: [RichTextRepresentation] = []
  var title: String = ""
  var removed = false
  var fileBacked = false
  var image = false
  var media = false
  /// Caller only has a display truncation. Save must not replace the complete item.
  var previewTruncated = false
}

enum RichTextColumnAction: Equatable, Sendable {
  case replace(Data)
  case delete
}

struct RichTextColumnChange: Equatable, Sendable {
  var type: String
  var action: RichTextColumnAction
  /// True only for a new public.utf8-plain-text column when the item had no plain text.
  var insertIfMissing: Bool
}

enum RichTextSaveStatus: Equatable, Sendable {
  case ready
  case unchanged
  case titleOnly
  case rejected(RichTextRefusal)
}

struct RichTextSaveTransaction: Equatable, Sendable {
  var identity: String
  var generation: Int
  var status: RichTextSaveStatus
  var bodyChanged: Bool
  var titleChanged: Bool
  /// Integrator writes title only when non-nil. Nil means leave the stored title alone.
  var title: String?
  /// True only when the body changed and the save may be committed.
  /// Title-only, cancel, and rejection are never true.
  var applyColumnChanges: Bool
  var columnChanges: [RichTextColumnChange]
  var risks: [RichTextRisk]
}

struct RichTextCancelResult: Equatable, Sendable {
  var identity: String
  var applyColumnChanges: Bool
  var columnChanges: [RichTextColumnChange]
  var draftRetained: Bool
  var body: String
}

struct RichTextAssessment {
  var presentation: RichTextPresentation
  var display: NSAttributedString
  var editBody: String?
  var refusal: RichTextRefusal?
  var risks: [RichTextRisk]
}

enum RichTextTypes {
  static var plainUTF8: String { NSPasteboard.PasteboardType.string.rawValue }
  static var rtf: String { NSPasteboard.PasteboardType.rtf.rawValue }

  static func isPlain(_ type: String) -> Bool {
    if type == plainUTF8 { return true }
    let lower = type.lowercased()
    if lower == "public.plain-text" || lower == "nsstringpboardtype" { return true }
    if lower.contains("utf-16") || lower.contains("utf16") { return true }
    if lower.contains("utf-8") || lower.contains("utf8") || lower.contains("plain-text") { return true }
    return false
  }

  /// Pasteboard type names that carry rich text. Not an HTML parser and not a safety claim.
  static func isRich(_ type: String) -> Bool {
    if isPlain(type) { return false }
    let lower = type.lowercased()
    let known = [
      "public.rtf", "public.rtfd", "public.html",
      "nsrtfpboardtype", "nsrtfdpboardtype", "nshtmlpboardtype",
      "com.apple.flat-rtfd", "com.apple.notes.richtext",
      "com.apple.webarchive", "apple web archive pasteboard type",
      "com.apple.webkit.custom-pasteboard-data",
      "org.chromium.web-custom-data"
    ]
    if known.contains(lower) { return true }
    return lower.contains("rtf") || lower.contains("html")
  }

  static func plainData(for type: String, body: String) -> Data {
    let lower = type.lowercased()
    if lower.contains("utf-16") || lower.contains("utf16") {
      return body.data(using: .utf16) ?? Data(body.utf8)
    }
    return Data(body.utf8)
  }
}

enum RichTextIdentity {
  /// In-session draft key. Dedup replaces the model, so the integrator must rebind.
  /// Do not use HistoryItemDecorator.id.
  @MainActor
  static func modelKey(_ item: HistoryItem) -> String {
    String(describing: item.persistentModelID)
  }
}

enum RichTextReading {
  /// Comparison only. Does not rewrite plain, storage, or the edit string.
  static func agrees(_ rich: String, _ plain: String) -> Bool {
    let left = structural(rich)
    let right = structural(plain)
    if left == right { return true }
    if trimTrailingNewlines(left) == trimTrailingNewlines(right) { return true }
    // HTML block breaks insert LF. Spaces and other characters still have to match.
    return left.replacingOccurrences(of: "\n", with: "") == right.replacingOccurrences(of: "\n", with: "")
  }

  /// Display copy. Existing foreground, size, and weight stay. Missing foreground
  /// becomes the dynamic label color. The caller's string is not mutated.
  static func displayCopy(_ text: NSAttributedString) -> NSAttributedString {
    let copy = NSMutableAttributedString(attributedString: text)
    let full = NSRange(location: 0, length: copy.length)
    guard full.length > 0 else { return copy }
    copy.enumerateAttribute(.foregroundColor, in: full, options: []) { value, range, _ in
      if value == nil {
        copy.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
      }
    }
    return copy
  }

  static func plainDisplay(_ plain: String) -> NSAttributedString {
    NSAttributedString(string: plain, attributes: [
      .font: NSFont.systemFont(ofSize: 13),
      .foregroundColor: NSColor.labelColor
    ])
  }

  private static func structural(_ text: String) -> String {
    text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
  }

  private static func trimTrailingNewlines(_ text: String) -> String {
    var value = text
    while value.hasSuffix("\n") { value.removeLast() }
    return value
  }
}

enum RichTextModel {
  static func assess(_ source: RichTextSource) -> RichTextAssessment {
    if let refusal = structuralRefusal(source) {
      return RichTextAssessment(
        presentation: .readableText,
        display: NSAttributedString(string: ""),
        editBody: nil,
        refusal: refusal,
        risks: []
      )
    }
    let plain = completePlain(source.representations)
    let rtf = source.representations.first { $0.type == RichTextTypes.rtf }?.value
    let html = source.representations.first { RichTextTypes.isRich($0.type) && $0.type.lowercased().contains("html") }?.value
    if let rtf, rtf.count > RichTextLimits.maxEditableBytes {
      return oversized(plain: plain)
    }
    if let html, html.count > RichTextLimits.maxEditableBytes {
      return oversized(plain: plain)
    }
    let imported = rtf.flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) }
    let htmlResult = html.flatMap { RichTextHTML.parse($0) }
    var risks = htmlResult?.risks ?? []
    if rtf != nil && imported == nil { risks.append(.undecodable) }

    let presentation: RichTextPresentation
    let display: NSAttributedString
    let htmlRich: NSAttributedString? = {
      guard let htmlResult, htmlResult.faithful, let attributed = htmlResult.attributed, !attributed.string.isEmpty else {
        return nil
      }
      return attributed
    }()
    if let plain {
      if let imported, !imported.string.isEmpty, RichTextReading.agrees(imported.string, plain) {
        presentation = .richText
        display = RichTextReading.displayCopy(imported)
      } else if let htmlRich, RichTextReading.agrees(htmlRich.string, plain) {
        presentation = .richText
        display = RichTextReading.displayCopy(htmlRich)
      } else {
        presentation = .readableText
        display = RichTextReading.plainDisplay(plain)
      }
    } else if let imported {
      presentation = .richText
      display = RichTextReading.displayCopy(imported)
    } else if let htmlRich {
      presentation = .richText
      display = RichTextReading.displayCopy(htmlRich)
    } else {
      presentation = .readableText
      let text = imported?.string ?? htmlResult?.readable ?? ""
      display = RichTextReading.plainDisplay(text)
    }

    let editBody = editBaseline(plain: plain, imported: imported, html: htmlResult)
    var refusal: RichTextRefusal?
    if editBody == nil {
      if htmlResult?.truncated == true || (plain == nil && (rtf?.count ?? 0) > RichTextLimits.maxEditableBytes) {
        refusal = .oversized
      } else if plain == nil && imported == nil && (htmlResult == nil || htmlResult?.readable.isEmpty == true) {
        refusal = .undecodable
      } else if let body = plain ?? imported?.string ?? htmlResult?.readable, body.count > RichTextLimits.maxEditableCharacters {
        refusal = .oversized
      } else {
        refusal = .undecodable
      }
    }
    return RichTextAssessment(
      presentation: presentation,
      display: display,
      editBody: editBody,
      refusal: refusal,
      risks: risks
    )
  }

  /// Column writes for a committed body change. Empty unless the body actually changed.
  static func columnChanges(
    body: String,
    baselineBody: String,
    representations: [RichTextRepresentation]
  ) -> [RichTextColumnChange] {
    guard body != baselineBody else { return [] }
    var changes: [RichTextColumnChange] = []
    var seenPlain = Set<String>()
    var seenRich = Set<String>()
    for item in representations {
      if RichTextTypes.isPlain(item.type) {
        if seenPlain.insert(item.type).inserted {
          changes.append(RichTextColumnChange(
            type: item.type,
            action: .replace(RichTextTypes.plainData(for: item.type, body: body)),
            insertIfMissing: false
          ))
        }
      } else if RichTextTypes.isRich(item.type) {
        if seenRich.insert(item.type).inserted {
          changes.append(RichTextColumnChange(type: item.type, action: .delete, insertIfMissing: false))
        }
      }
    }
    if seenPlain.isEmpty {
      changes.insert(RichTextColumnChange(
        type: RichTextTypes.plainUTF8,
        action: .replace(Data(body.utf8)),
        insertIfMissing: true
      ), at: 0)
    }
    return changes
  }

  private static func structuralRefusal(_ source: RichTextSource) -> RichTextRefusal? {
    if source.removed { return .removed }
    if source.fileBacked { return .fileBacked }
    if source.image { return .image }
    if source.media { return .media }
    if source.previewTruncated { return .truncatedPreview }
    if !source.representations.contains(where: { RichTextTypes.isRich($0.type) }) { return .notRich }
    return nil
  }

  private static func oversized(plain: String?) -> RichTextAssessment {
    let text = plain.map { String($0.prefix(RichTextLimits.maxEditableCharacters)) } ?? ""
    return RichTextAssessment(
      presentation: .readableText,
      display: RichTextReading.plainDisplay(text),
      editBody: plain.flatMap { $0.count <= RichTextLimits.maxEditableCharacters ? $0 : nil },
      refusal: plain?.count ?? Int.max > RichTextLimits.maxEditableCharacters ? .oversized : nil,
      risks: [.oversized]
    )
  }

  private static func completePlain(_ representations: [RichTextRepresentation]) -> String? {
    let pairs = representations.map { ($0.type, $0.value) }
    guard let data = PreviewTextCodec.reliablePlainData(pairs, isPlain: RichTextTypes.isPlain),
          data.count <= RichTextLimits.maxEditableBytes else { return nil }
    return PreviewTextCodec.decodePlain(data)
  }

  private static func editBaseline(
    plain: String?,
    imported: NSAttributedString?,
    html: RichTextHTML.Result?
  ) -> String? {
    if let plain {
      return plain.count <= RichTextLimits.maxEditableCharacters ? plain : nil
    }
    if let imported, imported.string.count <= RichTextLimits.maxEditableCharacters {
      return imported.string
    }
    if let html, !html.truncated, html.readable.count <= RichTextLimits.maxEditableCharacters {
      return html.readable
    }
    return nil
  }
}

enum RichTextHTML {
  struct Result {
    var readable: String
    var attributed: NSAttributedString?
    var faithful: Bool
    var truncated: Bool
    var risks: [RichTextRisk]
  }

  /// In-memory tidy DOM. Does not call NSAttributedString(html:), does not fetch, does not execute.
  /// Style tokenizing is display-only. It is not the safety boundary.
  static func parse(_ data: Data) -> Result {
    if data.count > RichTextLimits.maxEditableBytes {
      return Result(readable: "", attributed: nil, faithful: false, truncated: true, risks: [.oversized])
    }
    guard let bytes = PreviewTextCodec.htmlDocumentData(data),
          let document = try? XMLDocument(data: bytes, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
          let root = document.rootElement() else {
      return Result(readable: "", attributed: nil, faithful: false, truncated: false, risks: [.undecodable])
    }
    var state = Walk()
    walk(root, style: Style(), into: &state)
    let faithful = state.risks.isEmpty && !state.truncated
    let attributed: NSAttributedString? = faithful ? state.attributed : nil
    return Result(
      readable: state.readable,
      attributed: attributed,
      faithful: faithful,
      truncated: state.truncated,
      risks: state.risks
    )
  }

  private struct Style {
    var font = NSFont(name: "Helvetica", size: 13) ?? NSFont.systemFont(ofSize: 13)
    var color: NSColor?
    var underline = false
    var strike = false
    var link: URL?
    var alignment: NSTextAlignment?
    var superscript = 0
  }

  private struct Walk {
    var readable = ""
    var attributed = NSMutableAttributedString()
    var risks: [RichTextRisk] = []
    var nodes = 0
    var truncated = false
  }

  private static let blockingElements: Set<String> = [
    "table", "thead", "tbody", "tfoot", "tr", "td", "th", "caption", "col", "colgroup",
    "img", "picture", "svg", "video", "audio", "canvas", "math", "form", "input",
    "script", "style", "link", "iframe", "object", "embed", "applet", "frame", "frameset",
    "button", "select", "textarea", "source", "track", "base", "noscript"
  ]
  private static let skippedText: Set<String> = [
    "script", "style", "iframe", "object", "embed", "noscript", "applet", "head", "title"
  ]
  private static let blocks: Set<String> = [
    "p", "div", "li", "blockquote", "pre", "h1", "h2", "h3", "h4", "h5", "h6", "tr"
  ]

  private static func walk(_ node: XMLNode, style: Style, into state: inout Walk) {
    guard !state.truncated else { return }
    state.nodes += 1
    if state.nodes > RichTextLimits.maxHTMLNodes {
      state.truncated = true
      state.risks.append(.truncated)
      return
    }
    guard let element = node as? XMLElement else {
      append(node.stringValue ?? "", style: style, into: &state)
      return
    }
    let name = (element.name ?? "").lowercased()
    if name == "head" || name == "title" {
      if name == "head" {
        for child in element.children ?? [] { walk(child, style: style, into: &state) }
      }
      return
    }
    if name == "meta" {
      let equiv = element.attribute(forName: "http-equiv")?.stringValue?.lowercased()
      if equiv == "refresh" { state.risks.append(.executableMarkup) }
      return
    }
    if blockingElements.contains(name) || unsafe(element) {
      noteRisk(name, element, into: &state)
      guard !skippedText.contains(name) else { return }
      var plain = style
      plain.link = nil
      plain.color = nil
      for child in element.children ?? [] {
        if let nested = child as? XMLElement {
          walk(nested, style: plain, into: &state)
        } else {
          append(child.stringValue ?? "", style: plain, into: &state, attributes: false)
        }
      }
      return
    }
    var next = style
    apply(element, to: &next, into: &state)
    for child in element.children ?? [] { walk(child, style: next, into: &state) }
    if blocks.contains(name) { breakLine(into: &state) }
  }

  private static func noteRisk(_ name: String, _ element: XMLElement, into state: inout Walk) {
    if name == "script" || name == "iframe" || name == "object" || name == "embed" || name == "applet" {
      state.risks.append(.executableMarkup)
    } else if name == "img" || name == "picture" || name == "video" || name == "audio" || name == "source" {
      state.risks.append(.remoteResource)
    } else if unsafe(element) {
      state.risks.append(.executableMarkup)
    } else {
      state.risks.append(.unsupportedStructure)
    }
  }

  private static func unsafe(_ element: XMLElement) -> Bool {
    for attribute in element.attributes ?? [] {
      let name = (attribute.name ?? "").lowercased()
      let value = (attribute.stringValue ?? "").lowercased()
      if name.hasPrefix("on") { return true }
      if value.contains("javascript:") || value.contains("vbscript:") { return true }
      if value.contains("expression(") { return true }
      if name == "src" && (value.hasPrefix("http:") || value.hasPrefix("https:") || value.hasPrefix("data:")) {
        return true
      }
      if name == "style" && (value.contains("url(") || value.contains("expression(")) { return true }
    }
    return false
  }

  private static func apply(_ element: XMLElement, to style: inout Style, into state: inout Walk) {
    let name = (element.name ?? "").lowercased()
    switch name {
    case "b", "strong", "h1", "h2", "h3", "h4", "h5", "h6":
      style.font = NSFontManager.shared.convert(style.font, toHaveTrait: .boldFontMask)
    case "i", "em":
      style.font = NSFontManager.shared.convert(style.font, toHaveTrait: .italicFontMask)
    case "u":
      style.underline = true
    case "s", "strike", "del":
      style.strike = true
    case "sub":
      style.superscript = -1
    case "sup":
      style.superscript = 1
    default:
      break
    }
    if name == "a", let href = element.attribute(forName: "href")?.stringValue, let url = URL(string: href),
       let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" || scheme == "mailto" {
      style.link = url
    }
    if let inline = element.attribute(forName: "style")?.stringValue {
      applyStyle(inline, to: &style)
    }
    if let face = element.attribute(forName: "face")?.stringValue,
       let font = NSFont(name: face, size: style.font.pointSize) {
      style.font = font
    }
    if let color = element.attribute(forName: "color")?.stringValue {
      style.color = parseColor(color)
    }
  }

  private static func applyStyle(_ inline: String, to style: inout Style) {
    for part in inline.split(separator: ";") {
      let pieces = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      guard pieces.count == 2 else { continue }
      let key = pieces[0].lowercased()
      let value = pieces[1]
      switch key {
      case "color":
        style.color = parseColor(value)
      case "font-family":
        let family = value.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) } ?? ""
        if let font = NSFont(name: family, size: style.font.pointSize) { style.font = font }
      case "font-size":
        if let size = Double(value.replacingOccurrences(of: "px", with: "").replacingOccurrences(of: "pt", with: "")) {
          style.font = NSFont(name: style.font.fontName, size: CGFloat(size)) ?? style.font
        }
      case "font-weight":
        if value == "bold" || (Int(value) ?? 0) >= 600 {
          style.font = NSFontManager.shared.convert(style.font, toHaveTrait: .boldFontMask)
        }
      case "font-style":
        if value == "italic" || value == "oblique" {
          style.font = NSFontManager.shared.convert(style.font, toHaveTrait: .italicFontMask)
        }
      case "text-decoration":
        if value.contains("underline") { style.underline = true }
        if value.contains("line-through") { style.strike = true }
      case "text-align":
        switch value {
        case "center": style.alignment = .center
        case "right": style.alignment = .right
        case "justify": style.alignment = .justified
        default: style.alignment = .left
        }
      default:
        break
      }
    }
  }

  private static func parseColor(_ raw: String) -> NSColor? {
    let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
    guard value.hasPrefix("#") else { return nil }
    let hex = value.dropFirst()
    guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
    let chars = Array(hex)
    func channel(_ index: Int) -> CGFloat {
      let text = String(chars[index * 2...index * 2 + 1])
      return CGFloat(Int(text, radix: 16) ?? 0) / 255
    }
    return NSColor(srgbRed: channel(0), green: channel(1), blue: channel(2), alpha: 1)
  }

  private static func append(_ text: String, style: Style, into state: inout Walk, attributes: Bool = true) {
    guard !text.isEmpty else { return }
    state.readable += text
    guard attributes, state.risks.isEmpty else { return }
    var attrs: [NSAttributedString.Key: Any] = [.font: style.font]
    if let color = style.color { attrs[.foregroundColor] = color }
    if style.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
    if style.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
    if let link = style.link { attrs[.link] = link }
    if style.superscript != 0 { attrs[.superscript] = style.superscript }
    if let alignment = style.alignment {
      let paragraph = NSMutableParagraphStyle()
      paragraph.alignment = alignment
      attrs[.paragraphStyle] = paragraph
    }
    state.attributed.append(NSAttributedString(string: text, attributes: attrs))
  }

  private static func breakLine(into state: inout Walk) {
    guard !state.readable.hasSuffix("\n") else { return }
    state.readable += "\n"
    if state.risks.isEmpty {
      state.attributed.append(NSAttributedString(string: "\n"))
    }
  }
}

struct RichTextDraft: Equatable {
  var identity: String
  var generation: Int
  var body: String
  var title: String
  var baselineBody: String
  var baselineTitle: String
  var baselineRepresentations: [RichTextRepresentation]
  var error: String?
}

final class RichTextDraftStore {
  static let shared = RichTextDraftStore()
  private var drafts: [String: RichTextDraft] = [:]
  private var retired: [String: Int] = [:]

  func draft(for identity: String) -> RichTextDraft? { drafts[identity] }

  func retain(_ draft: RichTextDraft) {
    if let retiredGeneration = retired[draft.identity], draft.generation <= retiredGeneration { return }
    drafts[draft.identity] = draft
  }

  @discardableResult
  func discard(identity: String) -> RichTextDraft? {
    let draft = drafts.removeValue(forKey: identity)
    retired[identity] = max(retired[identity] ?? 0, (draft?.generation ?? 0) + 1)
    return draft
  }

  /// Moves a draft when dedup replaces the model. Does not overwrite a live destination.
  @discardableResult
  func rebind(from old: String, to new: String) -> Bool {
    guard old != new else { return true }
    guard drafts[new] == nil, retired[new] == nil else { return false }
    guard var draft = drafts.removeValue(forKey: old) else { return false }
    retired[old] = draft.generation
    draft.identity = new
    drafts[new] = draft
    return true
  }

  func noteCommitted(identity: String, generation: Int) {
    if let retiredGeneration = retired[identity], generation <= retiredGeneration { return }
    guard let draft = drafts[identity], draft.generation == generation else { return }
    drafts[identity] = nil
  }

  func noteSaveFailed(identity: String, generation: Int, message: String) {
    guard var draft = drafts[identity], draft.generation == generation else { return }
    draft.error = message
    drafts[identity] = draft
  }
}

final class RichTextSession {
  let store: RichTextDraftStore
  private(set) var identity = ""
  private(set) var source = RichTextSource()
  private(set) var assessment = RichTextAssessment(
    presentation: .readableText,
    display: NSAttributedString(string: ""),
    editBody: nil,
    refusal: .missing,
    risks: []
  )
  private(set) var generation = 0
  private var body = ""
  private var title = ""

  var editedBody: String { body }

  init(store: RichTextDraftStore = RichTextDraftStore()) {
    self.store = store
  }

  @discardableResult
  func load(identity: String, source: RichTextSource) -> RichTextAssessment {
    self.identity = identity
    self.source = source
    assessment = RichTextModel.assess(source)
    let baselineBody = assessment.editBody ?? ""
    let baselineTitle = source.title
    if let draft = store.draft(for: identity) {
      body = draft.body
      title = draft.title
      generation = draft.generation
    } else {
      body = baselineBody
      title = baselineTitle
      generation = 0
    }
    return assessment
  }

  func noteBody(_ value: String) {
    guard assessment.refusal == nil else { return }
    body = value
    generation += 1
    retain()
  }

  /// Esc abandons the visible edit. Does not write columns.
  func abandon() {
    store.discard(identity: identity)
    body = assessment.editBody ?? ""
    title = source.title
  }

  func save(current: RichTextSource) -> RichTextSaveTransaction {
    if current.removed || assessment.refusal == .removed {
      return rejected(.removed)
    }
    if let refusal = assessment.refusal {
      return rejected(refusal)
    }
    let baseline = store.draft(for: identity)
    let baselineRepresentations = baseline?.baselineRepresentations ?? source.representations
    if !sameBytes(current.representations, baselineRepresentations) {
      return rejected(.conflict)
    }
    let baselineBody = baseline?.baselineBody ?? assessment.editBody ?? ""
    let baselineTitle = baseline?.baselineTitle ?? source.title
    let bodyChanged = body != baselineBody
    let titleChanged = title != baselineTitle
    if bodyChanged && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return rejected(.empty)
    }
    if !bodyChanged && !titleChanged {
      return RichTextSaveTransaction(
        identity: identity,
        generation: generation,
        status: .unchanged,
        bodyChanged: false,
        titleChanged: false,
        title: nil,
        applyColumnChanges: false,
        columnChanges: [],
        risks: assessment.risks
      )
    }
    if !bodyChanged {
      return RichTextSaveTransaction(
        identity: identity,
        generation: generation,
        status: .titleOnly,
        bodyChanged: false,
        titleChanged: true,
        title: title,
        applyColumnChanges: false,
        columnChanges: [],
        risks: assessment.risks
      )
    }
    let changes = RichTextModel.columnChanges(
      body: body,
      baselineBody: baselineBody,
      representations: baselineRepresentations
    )
    return RichTextSaveTransaction(
      identity: identity,
      generation: generation,
      status: .ready,
      bodyChanged: true,
      titleChanged: titleChanged,
      title: titleChanged ? title : nil,
      applyColumnChanges: true,
      columnChanges: changes,
      risks: assessment.risks
    )
  }

  private func rejected(_ refusal: RichTextRefusal) -> RichTextSaveTransaction {
    RichTextSaveTransaction(
      identity: identity,
      generation: generation,
      status: .rejected(refusal),
      bodyChanged: body != (assessment.editBody ?? ""),
      titleChanged: false,
      title: nil,
      applyColumnChanges: false,
      columnChanges: [],
      risks: assessment.risks
    )
  }

  private func retain() {
    let baselineBody = assessment.editBody ?? ""
    let baselineTitle = source.title
    let existing = store.draft(for: identity)
    store.retain(RichTextDraft(
      identity: identity,
      generation: generation,
      body: body,
      title: title,
      baselineBody: existing?.baselineBody ?? baselineBody,
      baselineTitle: existing?.baselineTitle ?? baselineTitle,
      baselineRepresentations: existing?.baselineRepresentations ?? source.representations,
      error: nil
    ))
  }

  private func sameBytes(_ lhs: [RichTextRepresentation], _ rhs: [RichTextRepresentation]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return sorted(lhs) == sorted(rhs)
  }

  private func sorted(_ items: [RichTextRepresentation]) -> [RichTextRepresentation] {
    items.sorted {
      if $0.type != $1.type { return $0.type < $1.type }
      return $0.value.base64EncodedString() < $1.value.base64EncodedString()
    }
  }
}

@MainActor
final class RichTextBodyView: NSTextView {
  var onText: ((String) -> Void)?
  var onBegin: (() -> Void)?
  var onSave: (() -> Bool)?
  var onCancel: (() -> Void)?
  var allowsEdit = true
  var linkAttempts = 0
  private var applyingAccessibilityValue = false

  override var acceptsFirstResponder: Bool { isEditable }

  override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
    super.init(frame: frameRect, textContainer: container)
    usesAdaptiveColorMappingForDarkAppearance = true
    textColor = .labelColor
  }

  /// `NSTextView.init(usingTextLayoutManager:)` is an uninherited convenience.
  /// `false` must be TextKit 1: the frame initializer on this SDK is TextKit 2.
  convenience init(usingTextLayoutManager useTextKit2: Bool) {
    precondition(!useTextKit2, "call sites request TextKit 1")
    let storage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    storage.addLayoutManager(layoutManager)
    let container = NSTextContainer(size: NSSize(width: 0, height: 10_000_000))
    container.widthTracksTextView = true
    container.heightTracksTextView = false
    layoutManager.addTextContainer(container)
    self.init(frame: .zero, textContainer: container)
    minSize = .zero
    maxSize = NSSize(width: 0, height: 10_000_000)
    isVerticallyResizable = true
    isHorizontallyResizable = false
  }

  override convenience init(frame frameRect: NSRect) {
    self.init(usingTextLayoutManager: false)
    frame = frameRect
    if let container = textContainer {
      container.containerSize = NSSize(width: frameRect.width, height: container.containerSize.height)
    }
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    usesAdaptiveColorMappingForDarkAppearance = true
    textColor = .labelColor
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func becomeFirstResponder() -> Bool {
    AppState.shared.noteTextEntryFocused(in: window)
    return super.becomeFirstResponder()
  }

  override func didChangeText() {
    super.didChangeText()
    guard isEditable else { return }
    onText?(string)
  }

  override func mouseDown(with event: NSEvent) {
    if !isEditable, allowsEdit {
      isEditable = true
      onBegin?()
      window?.makeFirstResponder(self)
      return
    }
    guard window?.isVisible == true else { return }
    super.mouseDown(with: event)
  }

  /// AX value writes replace the string without `didChangeText`. Same draft path as typing.
  override func setAccessibilityValue(_ accessibilityValue: Any?) {
    guard !applyingAccessibilityValue else { return }
    applyingAccessibilityValue = true
    defer { applyingAccessibilityValue = false }
    super.setAccessibilityValue(accessibilityValue)
    guard isEditable, let next = accessibilityValue as? String, next != string else { return }
    string = next
    onText?(string)
  }

  override func accessibilitySetValue(_ value: Any?, forAttribute attribute: NSAccessibility.Attribute) {
    if attribute == .value {
      setAccessibilityValue(value)
      return
    }
    super.accessibilitySetValue(value, forAttribute: attribute)
  }

  override func keyDown(with event: NSEvent) {
    guard isEditable, window?.firstResponder === self else {
      super.keyDown(with: event)
      return
    }
    let marked = hasMarkedText()
    if marked, event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 53 {
      // Give the input method the key. A true return means the context consumed
      // it (IME confirm, or the text system's insertNewline:/cancelOperation:).
      // False, or a nil context, must not fall through to super.keyDown: that
      // replaces a synthetic marked range with LF. insertNewline below refuses
      // that replacement while the range is still marked.
      let consumed = inputContext?.handleEvent(event) == true
      if consumed {
        return
      }
      return
    }
    switch PreviewEditKeys.command(keyCode: event.keyCode, flags: event.modifierFlags, markedText: marked) {
    case .submit:
      if onSave?() != false {
        endEditSession()
      }
    case .newline:
      super.insertNewline(nil)
    case .cancel:
      onCancel?()
      endEditSession()
    case .ignore:
      super.keyDown(with: event)
    }
  }

  override func insertNewline(_ sender: Any?) {
    // handleEvent(true) on a stock NSTextView reaches here and replaces the
    // marked range with LF. Refuse that while a candidate is still marked.
    // A real IME confirms through insertText, which clears the mark first.
    if hasMarkedText() {
      return
    }
    if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
      super.insertNewline(sender)
      return
    }
    if onSave?() != false {
      endEditSession()
    }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard isEditable, window?.firstResponder === self else { return false }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags == .command, event.keyCode == 36 || event.keyCode == 76 {
      if onSave?() != false {
        endEditSession()
      }
      return true
    }
    return false
  }

  private func endEditSession() {
    isEditable = false
    window?.makeFirstResponder(nil)
  }

  func consumeLink(_ link: Any) -> Bool {
    linkAttempts += 1
    _ = link
    return true
  }
}

struct RichTextEditBox: NSViewRepresentable {
  var display: NSAttributedString
  var draft: String
  var editing: Bool
  var rich: Bool
  var token: Int
  var wraps = true
  var allowsEdit: Bool = true
  var onBegin: () -> Void = {}
  var onText: (String) -> Void
  var onSave: () -> Void
  var shouldExit: () -> Bool = { true }
  var onCancel: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = !wraps
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.setAccessibilityIdentifier("lab-rich-text-scroll")
    let textView = RichTextBodyView(usingTextLayoutManager: false)
    textView.usesAdaptiveColorMappingForDarkAppearance = true
    textView.drawsBackground = false
    textView.textContainerInset = NSSize(width: 0, height: 0)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = !wraps
    textView.textContainer?.widthTracksTextView = wraps
    textView.minSize = .zero
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticDataDetectionEnabled = false
    textView.isAutomaticLinkDetectionEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.delegate = context.coordinator
    textView.setAccessibilityIdentifier("lab-rich-text-body")
    scroll.documentView = textView
    context.coordinator.textView = textView
    applyWrap(textView, scroll: scroll)
    apply(to: textView, context: context)
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let textView = scroll.documentView as? RichTextBodyView else { return }
    context.coordinator.textView = textView
    applyWrap(textView, scroll: scroll)
    apply(to: textView, context: context)
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    weak var textView: RichTextBodyView?
    var token = -1
    var editing = false
    var onText: ((String) -> Void)?
    var onSave: (() -> Void)?
    var shouldExit: (() -> Bool)?
    var onCancel: (() -> Void)?

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
      (textView as? RichTextBodyView)?.consumeLink(link) ?? true
    }
  }

  private func applyWrap(_ textView: RichTextBodyView, scroll: NSScrollView) {
    textView.textContainer?.widthTracksTextView = wraps
    textView.isHorizontallyResizable = !wraps
    let viewport = scroll.contentSize.width
    let tracked = viewport > 1 ? viewport : max(textView.bounds.width, 1)
    textView.textContainer?.containerSize = NSSize(
      width: wraps ? tracked : CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    scroll.hasHorizontalScroller = !wraps
  }

  private func apply(to textView: RichTextBodyView, context: Context) {
    let coordinator = context.coordinator
    textView.allowsEdit = allowsEdit
    textView.onBegin = onBegin
    textView.onText = onText
    textView.onSave = {
      onSave()
      return shouldExit()
    }
    textView.onCancel = onCancel
    coordinator.onText = onText
    coordinator.onSave = onSave
    coordinator.shouldExit = shouldExit
    coordinator.onCancel = onCancel
    textView.isSelectable = true
    textView.isRichText = rich && !editing
    if !editing || !allowsEdit {
      textView.isEditable = false
    }
    textView.toolTip = nil
    textView.setAccessibilityHelp(nil)
    let modeChanged = coordinator.editing != editing || coordinator.token != token
    coordinator.editing = editing
    coordinator.token = token
    guard modeChanged else { return }
    if textView.window?.firstResponder === textView, editing, textView.string == draft {
      return
    }
    if editing {
      textView.string = draft
      textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    } else if textView.window?.firstResponder !== textView {
      textView.textStorage?.setAttributedString(RichTextReading.displayCopy(display))
    }
  }
}

struct RichTextEditSection: View {
  var identity: String
  var source: RichTextSource
  @Binding var editing: Bool
  var wraps = true
  var store: RichTextDraftStore = .shared
  var onTransaction: (RichTextSaveTransaction) -> Void = { _ in }
  var onCancel: (RichTextCancelResult) -> Void = { _ in }
  @State private var session = RichTextSession()
  @State private var display = NSAttributedString(string: "")
  @State private var draft = ""
  @State private var rich = false
  @State private var canEdit = false
  @State private var token = 0
  @State private var errorText = ""
  @State private var exitGate = PreviewEditExit()

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      RichTextEditBox(
        display: display,
        draft: draft,
        editing: editing && canEdit,
        rich: rich && !editing,
        token: token,
        wraps: wraps,
        allowsEdit: canEdit,
        onBegin: {
          editing = true
          draft = session.store.draft(for: identity)?.body ?? session.assessment.editBody ?? draft
        },
        onText: { value in
          draft = value
          session.noteBody(value)
        },
        onSave: { exitGate.value = commit() },
        shouldExit: { exitGate.value },
        onCancel: abandonEdit
      )
      .accessibilityIdentifier("lab-rich-text-host")
      if !errorText.isEmpty {
        RefusalNote(text: errorText, identifier: "lab-preview-edit-error")
      }
    }
    .onAppear(perform: reload)
    .onChange(of: identity) { _, _ in reload() }
    .onChange(of: source) { _, _ in
      guard !editing else { return }
      reload()
    }
  }

  private func reload() {
    session = RichTextSession(store: store)
    let assessment = session.load(identity: identity, source: source)
    display = assessment.display
    draft = session.editedBody
    rich = assessment.presentation == .richText
    canEdit = assessment.refusal == nil
    errorText = store.draft(for: identity)?.error ?? ""
    token += 1
  }

  /// True when the edit should exit. Failure stays in place with the draft.
  private func commit() -> Bool {
    let transaction = session.save(current: source)
    switch transaction.status {
    case .unchanged:
      editing = false
      errorText = ""
      return true
    case .rejected(let refusal):
      errorText = refusalMessage(refusal)
      return false
    case .titleOnly, .ready:
      onTransaction(transaction)
      if let error = store.draft(for: identity)?.error, !error.isEmpty {
        errorText = error
        return false
      }
      editing = false
      errorText = ""
      reload()
      return true
    }
  }

  private func refusalMessage(_ refusal: RichTextRefusal) -> String {
    switch refusal {
    case .empty:
      return NSLocalizedString("edit_blank", value: "Text cannot be empty.", comment: "")
    case .removed, .stale:
      return NSLocalizedString("edit_stale", value: "This item was deleted. Nothing was written.", comment: "")
    case .fileBacked:
      return NSLocalizedString("edit_refused_file", value: "File items stay read-only and are not written back.", comment: "")
    case .conflict:
      return NSLocalizedString("edit_conflict", value: "The original changed. Nothing was overwritten.", comment: "")
    default:
      return NSLocalizedString("edit_conflict", value: "The original changed. Nothing was overwritten.", comment: "")
    }
  }

  private func abandonEdit() {
    session.abandon()
    editing = false
    errorText = ""
    let result = RichTextCancelResult(
      identity: identity,
      applyColumnChanges: false,
      columnChanges: [],
      draftRetained: false,
      body: session.editedBody
    )
    onCancel(result)
    reload()
  }
}

/// Type, byte count, and a short hash. No payload text. Smoke AX readout only.
enum RichColumnReadout {
  static func summary(_ pairs: [(String, Data)]) -> String {
    pairs.map { type, data in
      "\(type)#\(data.count)#\(fnv(data))"
    }.sorted().joined(separator: ",")
  }

  static func traits(_ text: NSAttributedString) -> String {
    guard text.length > 0 else { return "empty" }
    let end = min(2, text.length)
    var parts: [String] = []
    text.enumerateAttribute(.font, in: NSRange(location: 0, length: end)) { value, range, _ in
      let bold = (value as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true
      parts.append("\(range.location)-\(range.length):\(bold ? "bold" : "regular")")
    }
    return parts.joined(separator: ",")
  }

  static func fnv(_ data: Data) -> String {
    var hash: UInt64 = 1469598103934665603
    for byte in data {
      hash ^= UInt64(byte)
      hash &*= 1099511628211
    }
    return String(format: "%016llx", hash)
  }
}

struct RichColumnMark: NSViewRepresentable {
  var columns: String
  var traits: String

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    view.setAccessibilityElement(true)
    apply(view)
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    apply(view)
  }

  private func apply(_ view: NSView) {
    view.setAccessibilityIdentifier("lab-rich-columns")
    view.setAccessibilityValue("\(columns)|\(traits)")
    view.setAccessibilityLabel(traits)
  }
}
