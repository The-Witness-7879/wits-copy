import AppKit
import Foundation
import SwiftUI

struct PreviewTextStructure: Equatable {
  var headings: [String] = []
  var listItems: [String] = []
  var fencedLanguages: [String] = []
  var fencedBodies: [String] = []
  var tableRows: [[String]] = []
  var links: [String] = []
  var remoteImagesSkipped: [String] = []
  var keywordColored: Bool = false
  var hasDistinctHeading: Bool = false
}

struct PreviewTextRender: Equatable {
  var kind: PreviewRenderKind
  var languageLabel: String
  var monospace: Bool
  var display: String
  var full: String
  var truncated: Bool
  var lineCount: Int
  var attributed: NSAttributedString
  var structure: PreviewTextStructure
  var lineNumbers: String
}

enum PreviewTextRenderer {
  static func render(
    text: String,
    filename: String?,
    mode: PreviewTextMode?
  ) -> PreviewTextRender {
    let routed = PreviewClassifier.kind(filename: filename)
    let effective = effectiveKind(routed: routed, mode: mode, filename: filename)
    let limited = limit(text)
    switch effective {
    case .markdown:
      return markdown(limited.display, full: text, truncated: limited.truncated)
    case .code:
      return code(limited.display, full: text, truncated: limited.truncated, filename: filename, mode: mode)
    default:
      return plain(limited.display, full: text, truncated: limited.truncated)
    }
  }

  static func lineNumberText(lineCount: Int) -> String {
    guard lineCount > 0 else { return "" }
    return (1...lineCount).map(String.init).joined(separator: "\n")
  }

  private static func effectiveKind(
    routed: PreviewRenderKind,
    mode: PreviewTextMode?,
    filename: String?
  ) -> PreviewRenderKind {
    if let mode {
      switch mode {
      case .plain: return .plain
      case .markdown: return .markdown
      case .code: return .code
      }
    }
    switch routed {
    case .markdown, .code, .plain: return routed
    default:
      if PreviewClassifier.codeLanguage(filename: filename) != nil { return .code }
      return .plain
    }
  }

  private static func limit(_ text: String) -> (display: String, truncated: Bool) {
    if text.count <= PreviewLimits.maxDisplayCharacters {
      return (text, false)
    }
    let end = text.index(text.startIndex, offsetBy: PreviewLimits.maxDisplayCharacters)
    return (String(text[..<end]), true)
  }

  private static func plain(_ display: String, full: String, truncated: Bool) -> PreviewTextRender {
    let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    let attributed = NSAttributedString(string: display, attributes: [
      .font: font,
      .foregroundColor: NSColor.labelColor
    ])
    return PreviewTextRender(
      kind: .plain,
      languageLabel: "Plain",
      monospace: false,
      display: display,
      full: full,
      truncated: truncated,
      lineCount: lineCount(display),
      attributed: attributed,
      structure: PreviewTextStructure(),
      lineNumbers: lineNumberText(lineCount: lineCount(display))
    )
  }

  private static func code(
    _ display: String,
    full: String,
    truncated: Bool,
    filename: String?,
    mode: PreviewTextMode?
  ) -> PreviewTextRender {
    let label = PreviewClassifier.languageLabel(filename: filename, mode: mode ?? .code)
    let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    let colored = highlight(display, font: font, language: label)
    var structure = PreviewTextStructure()
    structure.keywordColored = colored.colored
    return PreviewTextRender(
      kind: .code,
      languageLabel: label,
      monospace: true,
      display: display,
      full: full,
      truncated: truncated,
      lineCount: lineCount(display),
      attributed: colored.text,
      structure: structure,
      lineNumbers: lineNumberText(lineCount: lineCount(display))
    )
  }

  private static func markdown(
    _ display: String,
    full: String,
    truncated: Bool
  ) -> PreviewTextRender {
    let parsed = MarkdownParser.parse(display)
    return PreviewTextRender(
      kind: .markdown,
      languageLabel: "Markdown",
      monospace: false,
      display: parsed.visible,
      full: full,
      truncated: truncated,
      lineCount: lineCount(parsed.visible),
      attributed: parsed.attributed,
      structure: parsed.structure,
      lineNumbers: lineNumberText(lineCount: lineCount(parsed.visible))
    )
  }

  private static func lineCount(_ text: String) -> Int {
    if text.isEmpty { return 0 }
    let extra = text.hasSuffix("\n") ? 1 : 0
    return text.reduce(into: 1) { count, character in
      if character == "\n" { count += 1 }
    } - extra
  }

  private static func highlight(
    _ source: String,
    font: NSFont,
    language: String
  ) -> (text: NSAttributedString, colored: Bool) {
    let colorSource = source.count > PreviewLimits.maxHighlightCharacters
      ? String(source.prefix(PreviewLimits.maxHighlightCharacters))
      : source
    let result = NSMutableAttributedString(string: source, attributes: [
      .font: font,
      .foregroundColor: NSColor.labelColor
    ])
    let keywords = keywordSet(language)
    var colored = false
    let ns = colorSource as NSString
    let full = source as NSString
    var index = 0
    while index < ns.length {
      let char = ns.character(at: index)
      if char == 0x2F, index + 1 < ns.length, ns.character(at: index + 1) == 0x2F {
        let lineEnd = ns.range(of: "\n", options: [], range: NSRange(location: index, length: ns.length - index))
        let end = lineEnd.location == NSNotFound ? ns.length : lineEnd.location
        paint(result, NSRange(location: index, length: end - index), .secondaryLabelColor, &colored)
        index = end
        continue
      }
      if char == 0x23, language == "Python" || language == "Shell" || language == "YAML" {
        let lineEnd = ns.range(of: "\n", options: [], range: NSRange(location: index, length: ns.length - index))
        let end = lineEnd.location == NSNotFound ? ns.length : lineEnd.location
        paint(result, NSRange(location: index, length: end - index), .secondaryLabelColor, &colored)
        index = end
        continue
      }
      if char == 0x22 || char == 0x27 {
        let end = scanString(ns, from: index, quote: char)
        paint(result, NSRange(location: index, length: end - index), .systemRed, &colored)
        index = end
        continue
      }
      if isIdent(char) {
        var end = index + 1
        while end < ns.length, isIdent(ns.character(at: end)) { end += 1 }
        let word = ns.substring(with: NSRange(location: index, length: end - index))
        if keywords.contains(word) {
          paint(result, NSRange(location: index, length: end - index), .systemBlue, &colored)
        }
        index = end
        continue
      }
      index += 1
    }
    if colorSource.count < full.length {
      result.addAttribute(
        .foregroundColor,
        value: NSColor.labelColor,
        range: NSRange(location: colorSource.count, length: full.length - colorSource.count)
      )
    }
    return (result, colored)
  }

  private static func paint(
    _ text: NSMutableAttributedString,
    _ range: NSRange,
    _ color: NSColor,
    _ colored: inout Bool
  ) {
    guard range.location + range.length <= text.length else { return }
    text.addAttribute(.foregroundColor, value: color, range: range)
    colored = true
  }

  private static func scanString(_ text: NSString, from start: Int, quote: unichar) -> Int {
    var index = start + 1
    while index < text.length {
      let char = text.character(at: index)
      if char == 0x5C { index += 2; continue }
      if char == quote { return index + 1 }
      if char == 0x0A { return index }
      index += 1
    }
    return text.length
  }

  private static func isIdent(_ char: unichar) -> Bool {
    (char >= 65 && char <= 90) || (char >= 97 && char <= 122) || (char >= 48 && char <= 57) || char == 0x5F
  }

  private static func keywordSet(_ language: String) -> Set<String> {
    switch language {
    case "Swift":
      return ["import", "struct", "class", "enum", "func", "let", "var", "return", "if", "else", "guard", "private"]
    case "Python":
      return ["def", "class", "return", "import", "from", "if", "else", "for", "while", "None", "True", "False"]
    case "JSON":
      return ["true", "false", "null"]
    case "JavaScript", "TypeScript":
      return ["const", "let", "var", "function", "return", "if", "else", "import", "export", "class"]
    default:
      return ["if", "else", "return", "class", "func", "function", "import"]
    }
  }
}

private enum MarkdownParser {
  struct Parsed {
    var visible: String
    var attributed: NSAttributedString
    var structure: PreviewTextStructure
  }

  static func parse(_ source: String) -> Parsed {
    var structure = PreviewTextStructure()
    let result = NSMutableAttributedString()
    let bodyFont = NSFont.systemFont(ofSize: 13)
    let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var index = 0
    while index < lines.count {
      let line = lines[index]
      if line.hasPrefix("```") {
        let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        structure.fencedLanguages.append(language)
        index += 1
        var body: [String] = []
        while index < lines.count, !lines[index].hasPrefix("```") {
          body.append(lines[index])
          index += 1
        }
        if index < lines.count { index += 1 }
        let fence = body.joined(separator: "\n")
        structure.fencedBodies.append(fence)
        append(result, fence + "\n", font: codeFont, color: .labelColor, background: NSColor.quaternaryLabelColor.withAlphaComponent(0.25))
        continue
      }
      if isTableHeader(line), index + 1 < lines.count, isTableDivider(lines[index + 1]) {
        var rows = [tableCells(line)]
        index += 2
        while index < lines.count, lines[index].contains("|") {
          rows.append(tableCells(lines[index]))
          index += 1
        }
        structure.tableRows.append(contentsOf: rows)
        appendTable(result, rows: rows, bodyFont: bodyFont, structure: &structure)
        continue
      }
      if let heading = headingParts(line) {
        structure.headings.append(heading.text)
        structure.hasDistinctHeading = true
        let font = headingFont(level: heading.level)
        let styled = NSMutableAttributedString(
          attributedString: inlineAttributed(heading.text, baseFont: font, structure: &structure)
        )
        styled.append(NSAttributedString(string: "\n", attributes: [
          .font: font,
          .foregroundColor: NSColor.labelColor
        ]))
        result.append(styled)
        index += 1
        continue
      }
      if let item = listItem(line) {
        structure.listItems.append(item)
        let row = NSMutableAttributedString(string: "• ", attributes: [
          .font: bodyFont,
          .foregroundColor: NSColor.labelColor
        ])
        row.append(inlineAttributed(item, baseFont: bodyFont, structure: &structure))
        row.append(NSAttributedString(string: "\n", attributes: [
          .font: bodyFont,
          .foregroundColor: NSColor.labelColor
        ]))
        result.append(row)
        index += 1
        continue
      }
      if line.trimmingCharacters(in: .whitespaces).isEmpty {
        append(result, "\n", font: bodyFont, color: .labelColor, background: nil)
        index += 1
        continue
      }
      let styled = NSMutableAttributedString(
        attributedString: inlineAttributed(line, baseFont: bodyFont, structure: &structure)
      )
      styled.append(NSAttributedString(string: "\n", attributes: [
        .font: bodyFont,
        .foregroundColor: NSColor.labelColor
      ]))
      result.append(styled)
      index += 1
    }
    return Parsed(visible: result.string, attributed: result, structure: structure)
  }

  private static func append(
    _ text: NSMutableAttributedString,
    _ string: String,
    font: NSFont,
    color: NSColor,
    background: NSColor?
  ) {
    var attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: color
    ]
    if let background {
      attributes[.backgroundColor] = background
    }
    text.append(NSAttributedString(string: string, attributes: attributes))
  }

  private static func headingParts(_ line: String) -> (level: Int, text: String)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("#") else { return nil }
    var level = 0
    for scalar in trimmed.unicodeScalars {
      if scalar == "#" { level += 1 } else { break }
    }
    guard level > 0, level <= 6 else { return nil }
    let rest = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
    return rest.isEmpty ? nil : (level, String(rest))
  }

  private static func headingFont(level: Int) -> NSFont {
    let size: CGFloat
    switch level {
    case 1: size = 22
    case 2: size = 18
    case 3: size = 16
    default: size = 13
    }
    return NSFont.boldSystemFont(ofSize: size)
  }

  private static func listItem(_ line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
      return String(trimmed.dropFirst(2))
    }
    if let dot = trimmed.firstIndex(of: "."), trimmed[..<dot].allSatisfy(\.isNumber) {
      let rest = trimmed[trimmed.index(after: dot)...].trimmingCharacters(in: .whitespaces)
      return rest.isEmpty ? nil : rest
    }
    return nil
  }

  private static func isTableHeader(_ line: String) -> Bool {
    line.contains("|") && !line.hasPrefix("```")
  }

  private static func isTableDivider(_ line: String) -> Bool {
    let trimmed = line.replacingOccurrences(of: "|", with: "")
      .replacingOccurrences(of: "-", with: "")
      .replacingOccurrences(of: ":", with: "")
      .trimmingCharacters(in: .whitespaces)
    return line.contains("-") && line.contains("|") && trimmed.isEmpty
  }

  private static func tableCells(_ line: String) -> [String] {
    var cells = line.split(separator: "|", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("|"), cells.first?.isEmpty == true {
      cells.removeFirst()
    }
    if trimmed.hasSuffix("|"), cells.last?.isEmpty == true {
      cells.removeLast()
    }
    return cells
  }

  private static func appendTable(
    _ text: NSMutableAttributedString,
    rows: [[String]],
    bodyFont: NSFont,
    structure: inout PreviewTextStructure
  ) {
    let columns = max(rows.map(\.count).max() ?? 1, 1)
    let table = NSTextTable()
    table.numberOfColumns = columns
    table.collapsesBorders = true
    table.hidesEmptyCells = false
    let headerFont = NSFont.boldSystemFont(ofSize: bodyFont.pointSize)
    for (rowIndex, row) in rows.enumerated() {
      for column in 0..<columns {
        let raw = column < row.count ? row[column] : ""
        let block = NSTextTableBlock(
          table: table,
          startingRow: rowIndex,
          rowSpan: 1,
          startingColumn: column,
          columnSpan: 1
        )
        // The preview sits on the panel's glass: a faint header tint, no
        // opaque cell fills that would read as a white or black slab.
        block.backgroundColor = rowIndex == 0
          ? NSColor.labelColor.withAlphaComponent(0.08)
          : nil
        block.setBorderColor(NSColor.separatorColor)
        block.setWidth(1, type: .absoluteValueType, for: .border)
        block.setWidth(4, type: .absoluteValueType, for: .padding)
        block.verticalAlignment = .middleAlignment
        let style = NSMutableParagraphStyle()
        style.textBlocks = [block]
        let base = rowIndex == 0 ? headerFont : bodyFont
        let content: NSAttributedString
        if raw.isEmpty {
          content = NSAttributedString(string: "\u{00A0}", attributes: [
            .font: base,
            .foregroundColor: NSColor.labelColor
          ])
        } else {
          content = inlineAttributed(raw, baseFont: base, structure: &structure)
        }
        let cell = NSMutableAttributedString(attributedString: content)
        cell.append(NSAttributedString(string: "\n", attributes: [
          .font: base,
          .foregroundColor: NSColor.labelColor
        ]))
        cell.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: cell.length))
        text.append(cell)
      }
    }
  }

  private struct BracketSpan {
    var label: String
    var url: String
    var end: String.Index
  }

  private static func inlineAttributed(
    _ line: String,
    baseFont: NSFont,
    structure: inout PreviewTextStructure
  ) -> NSAttributedString {
    let result = NSMutableAttributedString()
    var markup = ""
    func flush() {
      guard !markup.isEmpty else { return }
      result.append(styledMarkup(markup, baseFont: baseFont))
      markup = ""
    }
    var index = line.startIndex
    while index < line.endIndex {
      if line[index...].hasPrefix("![") {
        if let span = bracketSpan(line, from: index, image: true) {
          flush()
          structure.remoteImagesSkipped.append(span.url)
          let placeholder = span.label.isEmpty ? "[image not loaded]" : "\(span.label) [image not loaded]"
          result.append(NSAttributedString(string: placeholder, attributes: [
            .font: baseFont,
            .foregroundColor: NSColor.secondaryLabelColor
          ]))
          index = span.end
          continue
        }
      }
      if line[index...].hasPrefix("[") {
        if let span = bracketSpan(line, from: index, image: false) {
          structure.links.append(span.url)
          if isSafeWebURL(span.url) {
            markup += String(line[index..<span.end])
          } else {
            markup += span.label
          }
          index = span.end
          continue
        }
      }
      markup.append(line[index])
      index = line.index(after: index)
    }
    flush()
    return result
  }

  private static func styledMarkup(_ source: String, baseFont: NSFont) -> NSAttributedString {
    var options = AttributedString.MarkdownParsingOptions()
    options.interpretedSyntax = .inlineOnlyPreservingWhitespace
    options.failurePolicy = .returnPartiallyParsedIfPossible
    guard let parsed = try? AttributedString(markdown: source, options: options) else {
      return NSAttributedString(string: source, attributes: [
        .font: baseFont,
        .foregroundColor: NSColor.labelColor
      ])
    }
    let result = NSMutableAttributedString()
    for run in parsed.runs {
      let text = String(parsed[run.range].characters)
      if text.isEmpty { continue }
      var font = baseFont
      let intent = run.inlinePresentationIntent ?? []
      if intent.contains(.code) {
        font = NSFont.monospacedSystemFont(
          ofSize: baseFont.pointSize,
          weight: intent.contains(.stronglyEmphasized) ? .bold : .regular
        )
      }
      if intent.contains(.stronglyEmphasized) {
        font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
      }
      if intent.contains(.emphasized) {
        font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
      }
      var attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.labelColor
      ]
      if intent.contains(.strikethrough) {
        attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
      }
      if let url = run.link, isSafeWebURL(url) {
        attributes[.link] = url
        attributes[.foregroundColor] = NSColor.linkColor
        attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
      }
      result.append(NSAttributedString(string: text, attributes: attributes))
    }
    if result.length == 0 {
      return NSAttributedString(string: source, attributes: [
        .font: baseFont,
        .foregroundColor: NSColor.labelColor
      ])
    }
    return result
  }

  private static func bracketSpan(_ line: String, from index: String.Index, image: Bool) -> BracketSpan? {
    let labelStart = image ? line.index(index, offsetBy: 2, limitedBy: line.endIndex) : line.index(after: index)
    guard let labelStart, labelStart <= line.endIndex,
          let close = line[index...].range(of: "]("),
          let endParen = closingDestination(line, from: close.upperBound) else {
      return nil
    }
    return BracketSpan(
      label: String(line[labelStart..<close.lowerBound]),
      url: String(line[close.upperBound..<endParen]),
      end: line.index(after: endParen)
    )
  }

  private static func closingDestination(_ line: String, from start: String.Index) -> String.Index? {
    var depth = 1
    var index = start
    while index < line.endIndex {
      let character = line[index]
      if character == "\\" {
        index = line.index(index, offsetBy: 2, limitedBy: line.endIndex) ?? line.endIndex
        continue
      }
      if character == "(" { depth += 1 }
      if character == ")" {
        depth -= 1
        if depth == 0 { return index }
      }
      index = line.index(after: index)
    }
    return nil
  }

  private static func isSafeWebURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return scheme == "http" || scheme == "https"
  }

  private static func isSafeWebURL(_ string: String) -> Bool {
    guard let url = URL(string: string) else { return false }
    return isSafeWebURL(url)
  }
}

final class PreviewNSTextView: NSTextView {
}

struct SelectableTextPreview: NSViewRepresentable {
  var render: PreviewTextRender
  var wraps: Bool
  var showsLineNumbers: Bool

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = !wraps
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    let textView = PreviewNSTextView(usingTextLayoutManager: false)
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = true
    textView.drawsBackground = false
    textView.textContainerInset = NSSize(width: 4, height: 4)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = !wraps
    textView.textContainer?.widthTracksTextView = wraps
    textView.minSize = .zero
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    scroll.documentView = textView
    scroll.setAccessibilityIdentifier("lab-text-preview")
    apply(render, wraps: wraps, to: textView, coordinator: context.coordinator)
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard !context.coordinator.disposed, let textView = scroll.documentView as? PreviewNSTextView else { return }
    textView.textContainer?.widthTracksTextView = wraps
    textView.isHorizontallyResizable = !wraps
    scroll.hasHorizontalScroller = !wraps
    apply(render, wraps: wraps, to: textView, coordinator: context.coordinator)
  }

  static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
    coordinator.disposed = true
    coordinator.applied = nil
    (scroll.documentView as? NSTextView)?.textStorage?.setAttributedString(NSAttributedString())
    scroll.documentView = nil
  }

  final class Coordinator {
    var disposed = false
    /// Last attributed string actually written. Compared with isEqual so a same
    /// string with new font, color, or paragraph style still replaces storage,
    /// while an unchanged render does not. NSTextView may normalize attributes
    /// after the write; comparing storage itself would reset on every update.
    var applied: NSAttributedString?
  }

  private func apply(
    _ render: PreviewTextRender,
    wraps: Bool,
    to textView: NSTextView,
    coordinator: Coordinator
  ) {
    let display = NSAttributedString(
      attributedString: showsLineNumbers ? numbered(render) : render.attributed
    )
    let selected = textView.selectedRange()
    let scroll = textView.enclosingScrollView
    let origin = scroll?.contentView.bounds.origin
    let alreadyApplied = coordinator.applied?.isEqual(to: display) == true
      && textView.string == display.string
    if !alreadyApplied {
      textView.textStorage?.setAttributedString(display)
      if textView.textStorage != nil {
        coordinator.applied = display
      }
    }
    let viewport = scroll?.contentSize.width ?? 0
    let tracked = viewport > 1 ? viewport : max(textView.bounds.width, 1)
    textView.textContainer?.widthTracksTextView = wraps
    textView.isHorizontallyResizable = !wraps
    textView.textContainer?.containerSize = NSSize(
      width: wraps ? tracked : CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    scroll?.hasHorizontalScroller = !wraps
    if let container = textView.textContainer {
      textView.layoutManager?.ensureLayout(for: container)
    }
    let length = (textView.string as NSString).length
    if selected.location != NSNotFound, NSMaxRange(selected) <= length {
      textView.setSelectedRange(selected)
    }
    if let scroll, var origin {
      // Wrap hides the horizontal scroller. Restoring a leftover origin scrolls
      // the line-number prefix out of the viewport with no way back.
      if wraps {
        origin.x = 0
      }
      scroll.contentView.scroll(to: origin)
      scroll.reflectScrolledClipView(scroll.contentView)
    }
  }

  private func numbered(_ render: PreviewTextRender) -> NSAttributedString {
    let gutter = render.lineNumbers.split(separator: "\n", omittingEmptySubsequences: false)
    let lines = render.attributed.string.split(separator: "\n", omittingEmptySubsequences: false)
    let result = NSMutableAttributedString()
    let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    let count = max(gutter.count, lines.count)
    for index in 0..<count {
      let number = index < gutter.count ? String(gutter[index]) : ""
      result.append(NSAttributedString(string: number.padding(toLength: 4, withPad: " ", startingAt: 0), attributes: [
        .font: font,
        .foregroundColor: NSColor.tertiaryLabelColor
      ]))
      if index < lines.count {
        let line = String(lines[index])
        let range = (render.attributed.string as NSString).range(of: line)
        if range.location != NSNotFound {
          result.append(render.attributed.attributedSubstring(from: range))
        } else {
          result.append(NSAttributedString(string: line))
        }
      }
      result.append(NSAttributedString(string: "\n"))
    }
    return result
  }
}

/// Clipboard and HTML bytes are not a charset guess. UTF-8 (with or without BOM)
/// and UTF-16 only when a BOM is present. A type name that merely contains
/// "utf16" is not an endianness. Little-endian and big-endian can both round-trip
/// the same bytes to different strings, so that guess is refused.
enum PreviewTextCodec {
  static func isGenericUTF16(_ type: String) -> Bool {
    let lower = type.lowercased()
    return lower.contains("utf-16") || lower.contains("utf16")
  }

  static func decodePlain(_ data: Data) -> String? {
    if data.isEmpty { return "" }
    if data.starts(with: [0xEF, 0xBB, 0xBF]) {
      let body = Data(data.dropFirst(3))
      guard let text = String(data: body, encoding: .utf8), Data(text.utf8) == body else { return nil }
      return text
    }
    if let text = String(data: data, encoding: .utf8),
       Data(text.utf8) == data,
       !text.unicodeScalars.contains(where: { $0.value == 0 }) {
      return text
    }
    if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
      return String(data: data, encoding: .utf16)
    }
    return nil
  }

  /// Canonical `public.utf8-plain-text` wins even when it sits after another plain.
  /// A present UTF-8 column that does not decode stays nil; it is not replaced by
  /// a sibling. Generic UTF-16 without a BOM does not decode. No endian guess.
  static func reliablePlain(
    _ items: [(type: String, value: Data)],
    isPlain: (String) -> Bool
  ) -> String? {
    guard let data = reliablePlainData(items, isPlain: isPlain) else { return nil }
    return decodePlain(data)
  }

  static func reliablePlainData(
    _ items: [(type: String, value: Data)],
    isPlain: (String) -> Bool
  ) -> Data? {
    let plains = items.filter { isPlain($0.type) }
    let utf8Type = NSPasteboard.PasteboardType.string.rawValue
    if let utf8 = plains.first(where: { $0.type == utf8Type }) {
      return utf8.value
    }
    let decoded = plains.compactMap { item -> (String, Data)? in
      if isGenericUTF16(item.type),
         !item.value.starts(with: [0xFF, 0xFE]), !item.value.starts(with: [0xFE, 0xFF]) {
        return nil
      }
      guard decodePlain(item.value) != nil else { return nil }
      return (item.type, item.value)
    }
    let preferred = decoded.filter { !isGenericUTF16($0.0) }
    let pool = preferred.isEmpty ? decoded : preferred
    return pool.sorted { lhs, rhs in
      if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
      if lhs.1.count != rhs.1.count { return lhs.1.count < rhs.1.count }
      return lhs.1.base64EncodedString() < rhs.1.base64EncodedString()
    }.first?.1
  }

  /// XMLDocument tidy-HTML reads UTF-8 without a BOM as Latin-1 when a charset
  /// meta is present (`中文` → `ä¸­æ–‡`) and drops non-ASCII when it is absent.
  /// A leading UTF-8 BOM makes the same bytes decode correctly. UTF-16 with a
  /// BOM is left intact. Acceptance matches `decodePlain`, including the explicit
  /// U+0000 refusal. NUL is legal UTF-8, so that refusal is policy, not proof that
  /// a missing check already drew Western text. Stored bytes are not rewritten.
  static func htmlDocumentData(_ data: Data) -> Data? {
    if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
      return data
    }
    if data.starts(with: [0xEF, 0xBB, 0xBF]) {
      return decodePlain(data) == nil ? nil : data
    }
    guard decodePlain(data) != nil else { return nil }
    return Data([0xEF, 0xBB, 0xBF]) + data
  }
}
