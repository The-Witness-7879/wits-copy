import CoreGraphics
import Foundation

/// Stable two-column frame. Item count, filters, and preview content are not inputs.
struct PanelSplit: Equatable, Sendable {
  var listWidth: CGFloat
  var previewWidth: CGFloat
  var previewOpen: Bool
  var height: CGFloat

  static let defaultList: CGFloat = 520
  static let defaultPreview: CGFloat = 620
  /// Narrow rail: icons only. Drawn inside `listWidth`; toggling never changes the outer frame.
  static let navigationRailWidth: CGFloat = 36
  /// Expanded rail can be pulled wider for long category names.
  static let navigationRailMinWidth: CGFloat = 88
  static let navigationRailMaxWidth: CGFloat = 240
  /// Sidebar icon hit size. Fits inside `navigationRailWidth` and stays in the 24–28pt range.
  static let railHitSize: CGFloat = 28
  // 行尾 ⋯ 已撤：菜单挂整行右键，不再为按钮预留宽度。
  /// Only the close button stays visible, so this band can match the rail width.
  /// The search box then starts almost exactly above the list content.
  static let trafficLightReserve: CGFloat = navigationRailWidth
  static let defaultHeight: CGFloat = 640
  /// Wide enough for the whole header row; the preview is the compressible column.
  static let minimumList: CGFloat = ListToolbarLayout.minimumContentWidth
  static let preferredPreviewFloor: CGFloat = 480
  static let tightPreviewFloor: CGFloat = 200
  static let layoutMargin: CGFloat = 32
  static let minimumHeight: CGFloat = 320
  static let maximumHeight: CGFloat = 900

  var totalWidth: CGFloat {
    listWidth + (previewOpen ? previewWidth : 0)
  }

  static func finite(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
    value.isFinite && value > 0 ? value : fallback
  }

  /// Room inside a visible frame. Never larger than `available`, and never larger than `available - margin` when that still leaves room.
  static func layoutBudget(_ available: CGFloat, margin: CGFloat = layoutMargin) -> CGFloat {
    guard available.isFinite, available > 0 else { return 0 }
    if available <= margin { return available }
    return available - margin
  }

  /// Lower bound shared by edge resize and `fitted`. Wide screens keep the 480 preview; small screens may be compact.
  static func previewFloor(availableWidth: CGFloat, listWidth: CGFloat) -> CGFloat {
    let budget = layoutBudget(availableWidth)
    if listWidth + preferredPreviewFloor <= budget {
      return preferredPreviewFloor
    }
    return tightPreviewFloor
  }

  func fitted(availableWidth: CGFloat, availableHeight: CGFloat) -> PanelSplit {
    let maxW = Self.layoutBudget(availableWidth)
    let maxH = min(Self.maximumHeight, Self.layoutBudget(availableHeight))
    var list = Self.finite(listWidth, fallback: Self.defaultList).rounded()
    var preview = Self.finite(previewWidth, fallback: Self.defaultPreview).rounded()

    if previewOpen {
      // Even when everything fits, never restore a list too narrow for the header.
      let listFloor = min(Self.minimumList, maxW)
      list = min(max(list, listFloor), maxW)
      let floor = Self.previewFloor(availableWidth: availableWidth, listWidth: list)
      if preview < floor, list + floor <= maxW {
        preview = floor
      }
      if list + preview > maxW {
        let listFloor = min(Self.minimumList, maxW)
        preview = min(preview, max(0, maxW - listFloor))
        list = min(list, max(0, maxW - preview))
        if list + preview > maxW {
          preview = max(0, maxW - list)
        }
      }
    } else if maxW >= Self.minimumList {
      list = min(max(list, Self.minimumList), maxW)
    } else {
      list = min(list, maxW)
    }

    let rawHeight = Self.finite(height, fallback: Self.defaultHeight)
    let heightFloor = min(Self.minimumHeight, maxH)
    let fittedHeight = min(max(rawHeight, heightFloor), maxH)

    return PanelSplit(
      listWidth: list.rounded(),
      previewWidth: preview.rounded(),
      previewOpen: previewOpen,
      height: fittedHeight.rounded()
    )
  }

  /// Move the separator inside a fixed outer width. Does not change `totalWidth`.
  func redistributed(previewDelta: CGFloat, totalWidth: CGFloat) -> PanelSplit {
    guard previewOpen, totalWidth > Self.minimumList + Self.tightPreviewFloor else { return self }
    let floor = (totalWidth - Self.minimumList >= Self.preferredPreviewFloor)
      ? Self.preferredPreviewFloor
      : Self.tightPreviewFloor
    let preview = min(max((previewWidth + previewDelta).rounded(), floor), totalWidth - Self.minimumList)
    return PanelSplit(
      listWidth: (totalWidth - preview).rounded(),
      previewWidth: preview,
      previewOpen: true,
      height: height
    )
  }

  /// Give or take width from the preview edge. List width stays unless the total cannot hold it.
  func absorbing(totalWidth: CGFloat, previewFloor: CGFloat) -> PanelSplit {
    let budget = max(0, totalWidth.rounded())
    guard previewOpen else {
      let list = budget == 0 ? 0 : min(max(listWidth, min(Self.minimumList, budget)), budget)
      return PanelSplit(
        listWidth: list.rounded(),
        previewWidth: previewWidth,
        previewOpen: false,
        height: height
      )
    }
    let listFloor = min(Self.minimumList, budget)
    let usableFloor = min(max(0, previewFloor), max(0, budget - listFloor))
    var preview = budget - listWidth
    if preview < usableFloor {
      preview = usableFloor
    }
    preview = min(max(0, preview), max(0, budget - listFloor))
    return PanelSplit(
      listWidth: (budget - preview).rounded(),
      previewWidth: preview.rounded(),
      previewOpen: true,
      height: height
    )
  }

  /// Right-edge preview toggle. Height and list width stay; extra width is the preview plus any expanded rail. Both size and origin stay inside `screenFrame`.
  func frameAfterSettingPreview(
    open: Bool,
    from frame: CGRect,
    in screenFrame: CGRect,
    railExtra: CGFloat = 0
  ) -> (split: PanelSplit, frame: CGRect) {
    let extra = max(0, railExtra).rounded()
    let rememberedPreview = Self.finite(previewWidth, fallback: Self.defaultPreview)
    if !open {
      let width = min((listWidth + extra).rounded(), max(screenFrame.width, 0))
      let proposed = CGRect(x: frame.minX, y: frame.minY, width: width, height: frame.height)
      let placed = Self.constrainedFrame(proposed: proposed, in: screenFrame)
      return (
        PanelSplit(
          listWidth: max(0, placed.width - extra).rounded(),
          previewWidth: rememberedPreview,
          previewOpen: false,
          height: placed.height
        ),
        placed
      )
    }

    var list = listWidth.rounded()
    var preview = rememberedPreview.rounded()
    let floor = Self.previewFloor(availableWidth: screenFrame.width, listWidth: list)
    if preview < floor, list + extra + floor <= screenFrame.width {
      preview = floor
    }
    if list + extra + preview > screenFrame.width {
      preview = max(0, screenFrame.width - min(list + extra, screenFrame.width))
      if list + extra > screenFrame.width {
        list = max(0, screenFrame.width - extra)
      }
    }
    let proposed = CGRect(x: frame.minX, y: frame.minY, width: list + extra + preview, height: frame.height)
    let placed = Self.constrainedFrame(proposed: proposed, in: screenFrame)
    return (
      PanelSplit(
        listWidth: list,
        previewWidth: preview,
        previewOpen: true,
        height: placed.height
      ),
      placed
    )
  }

  /// Top-center of the list column, as fractions of `screenFrame`. Restore must use the same point or the window walks left by preview/2.
  static func relativeAnchor(of frame: CGRect, listWidth: CGFloat, in screenFrame: CGRect) -> CGPoint {
    guard screenFrame.width > 0, screenFrame.height > 0 else {
      return CGPoint(x: 0.5, y: 0.8)
    }
    let anchorX = frame.minX + min(max(listWidth, 0), frame.width) / 2
    return CGPoint(
      x: (anchorX - screenFrame.minX) / screenFrame.width,
      y: (frame.maxY - screenFrame.minY) / screenFrame.height
    )
  }

  static func constrainedFrame(
    size: CGSize,
    listWidth: CGFloat,
    relativeAnchor: CGPoint,
    in screenFrame: CGRect
  ) -> CGRect {
    let fitted = sizeClamped(size, to: screenFrame)
    let anchorX = screenFrame.minX + screenFrame.width * relativeAnchor.x
    let anchorY = screenFrame.minY + screenFrame.height * relativeAnchor.y
    let inset = min(max(listWidth, 0), fitted.width) / 2
    let origin = CGPoint(x: anchorX - inset, y: anchorY - fitted.height)
    return constrainedFrame(proposed: CGRect(origin: origin, size: fitted), in: screenFrame)
  }

  static func constrainedFrame(proposed: CGRect, in screenFrame: CGRect) -> CGRect {
    guard screenFrame.width > 0, screenFrame.height > 0 else {
      return CGRect(origin: screenFrame.origin, size: .zero)
    }
    let size = sizeClamped(proposed.size, to: screenFrame)
    let origin = CGPoint(
      x: min(max(proposed.minX, screenFrame.minX), screenFrame.maxX - size.width),
      y: min(max(proposed.minY, screenFrame.minY), screenFrame.maxY - size.height)
    )
    return CGRect(origin: origin, size: size)
  }

  static func centeredOrigin(of size: CGSize, in frame: CGRect) -> CGPoint {
    CGPoint(
      x: (frame.width - size.width) / 2 + frame.minX + 1,
      y: (frame.height - size.height) / 2 + frame.minY + 1
    )
  }

  static func sizeClamped(_ size: CGSize, to screenFrame: CGRect) -> CGSize {
    CGSize(
      width: min(max(size.width, 0), max(screenFrame.width, 0)),
      height: min(max(size.height, 0), max(screenFrame.height, 0))
    )
  }
}
