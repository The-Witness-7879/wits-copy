import Foundation

/// OCR 结果的排版与阅读顺序。
/// 只处理已识别文本块的几何与顺序，不做识别本身。

enum OCRColumnLayout {
  static let width: CGFloat = 220
  static let minimumWidth: CGFloat = 160

  /// Extra width beside the preview. Never taken from the list column.
  /// No remaining room returns 0. Callers must not force `minimumWidth` past the screen.
  static func widthThatFits(availableWidth: CGFloat, occupiedWidth: CGFloat) -> CGFloat {
    guard availableWidth.isFinite, occupiedWidth.isFinite else { return 0 }
    let room = availableWidth - occupiedWidth - PanelSplit.layoutMargin
    if room >= width { return width }
    if room >= minimumWidth { return room.rounded() }
    return max(0, room.rounded())
  }
}


/// Temporary OCR column placed inside a screen frame.
/// Shift inward before shrinking the preview. Never shrink the list, and never
/// keep a width that would push the window past `screen`.
struct OCRFrameFit: Equatable, Sendable {
  var ocrWidth: CGFloat
  var previewWidth: CGFloat
  var listWidth: CGFloat
  var frame: CGRect
}


enum OCRFramePlanner {
  static func fit(
    window: CGRect,
    screen: CGRect,
    listWidth: CGFloat,
    railWidth: CGFloat = 0,
    previewWidth: CGFloat,
    previewOpen: Bool,
    desiredWidth: CGFloat = OCRColumnLayout.width
  ) -> OCRFrameFit {
    let list = listWidth.rounded()
    let rail = max(0, railWidth.rounded())
    let preview = previewWidth.rounded()
    let desired = min(OCRColumnLayout.width, max(0, desiredWidth.rounded()))
    guard previewOpen, screen.width > 0, screen.height > 0 else {
      return OCRFrameFit(ocrWidth: 0, previewWidth: preview, listWidth: list, frame: window)
    }

    // 左栏展开的那几十点也是窗口宽度的一部分。漏掉它，窗口就会比内容窄一截，
    // 右栏被裁、整窗还会被推到屏幕边上。
    let content = rail + list + preview
    let floor = PanelSplit.previewFloor(availableWidth: screen.width, listWidth: list)
    let minPreview = min(preview, max(floor, 0))
    let roomKeepingPreview = screen.width - content
    var fittedPreview = preview
    var ocr = desired

    if roomKeepingPreview >= desired {
      ocr = desired
    } else {
      let shrinkable = max(0, preview - minPreview)
      let roomAfterFloor = roomKeepingPreview + shrinkable
      if roomAfterFloor >= desired {
        fittedPreview = (preview - (desired - max(0, roomKeepingPreview))).rounded()
        ocr = desired
      } else if roomAfterFloor > 0 {
        fittedPreview = minPreview
        ocr = roomAfterFloor.rounded()
      } else {
        fittedPreview = minPreview
        ocr = 0
      }
    }

    var frame = window
    frame.size.width = (rail + list + fittedPreview + ocr).rounded()
    if frame.maxX > screen.maxX {
      frame.origin.x = screen.maxX - frame.width
    }
    if frame.minX < screen.minX {
      frame.origin.x = screen.minX
    }
    frame = PanelSplit.constrainedFrame(proposed: frame, in: screen)
    return OCRFrameFit(
      ocrWidth: ocr,
      previewWidth: fittedPreview,
      listWidth: list,
      frame: frame
    )
  }

  static func restored(base: CGRect, screen: CGRect) -> CGRect {
    guard screen.width > 0, screen.height > 0 else { return base }
    return PanelSplit.constrainedFrame(proposed: base, in: screen)
  }
}


struct OCRObservationBox: Equatable, Sendable {
  var text: String
  var minX: CGFloat
  var minY: CGFloat
  var maxX: CGFloat
  var maxY: CGFloat
}


struct OCRBlock: Equatable, Sendable, Identifiable {
  var id: Int
  var lines: [String]
}


enum OCRReadingOrder {
  /// Vision boxes use a bottom-left origin. Group into columns, then paragraphs.
  static func blocks(from boxes: [OCRObservationBox]) -> [OCRBlock] {
    let usable = boxes.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    guard !usable.isEmpty else { return [] }
    let sorted = usable.sorted {
      if $0.minX != $1.minX { return $0.minX < $1.minX }
      if $0.maxY != $1.maxY { return $0.maxY > $1.maxY }
      return $0.text < $1.text
    }
    var columns: [[OCRObservationBox]] = []
    for box in sorted {
      if var last = columns.last, let anchor = last.first, box.minX - anchor.maxX < 0.12 {
        last.append(box)
        columns[columns.count - 1] = last
      } else {
        columns.append([box])
      }
    }
    var blocks: [OCRBlock] = []
    var nextID = 0
    for column in columns {
      let lines = column.sorted {
        if $0.maxY != $1.maxY { return $0.maxY > $1.maxY }
        if $0.minX != $1.minX { return $0.minX < $1.minX }
        return $0.text < $1.text
      }
      var paragraph: [String] = []
      var previous: OCRObservationBox?
      for line in lines {
        if let previous, previous.minY - line.maxY > 0.045, !paragraph.isEmpty {
          blocks.append(OCRBlock(id: nextID, lines: paragraph))
          nextID += 1
          paragraph = []
        }
        paragraph.append(line.text)
        previous = line
      }
      if !paragraph.isEmpty {
        blocks.append(OCRBlock(id: nextID, lines: paragraph))
        nextID += 1
      }
    }
    return blocks
  }

  static func plainText(_ blocks: [OCRBlock]) -> String {
    blocks.map { $0.lines.joined(separator: "\n") }.joined(separator: "\n")
  }
}
