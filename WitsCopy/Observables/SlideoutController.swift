import Defaults
import Logging
import Observation
import SwiftUI

enum SlideoutState {
  case opening
  case closing
  case open
  case closed

  var isAnimating: Bool { false }

  var isOpen: Bool {
    switch self {
    case .open, .opening:
      return true
    case .closed, .closing:
      return false
    }
  }
}

enum ResizingMode {
  case none
  case content
  case slideout
}

@Observable
class SlideoutController {

  let minimumContentWidth: CGFloat = PanelSplit.minimumList
  var contentResizeWidth: CGFloat = 0
  var contentAnimationWidth: CGFloat?

  var minimumSlideoutWidth: CGFloat {
    guard let width = nswindow?.screen?.visibleFrame.width else {
      return PanelSplit.tightPreviewFloor
    }
    return PanelSplit.previewFloor(availableWidth: width, listWidth: layoutListWidth)
  }
  var slideoutResizeWidth: CGFloat = 0

  var layoutListWidth: CGFloat = PanelSplit.defaultList
  var layoutPreviewWidth: CGFloat = PanelSplit.defaultPreview
  var currentHeight: CGFloat = PanelSplit.defaultHeight

  /// 左栏展开时多出来的视觉宽度，只用于左栏自身。
  /// 窗口宽度不再包含它：左栏在窗口内开合，条目列让出这部分宽度。
  /// 视图层不要读这个：UserDefaults 变化不会触发 SwiftUI 重算，
  /// 顶部那排会停在旧宽度上。视图读 `AppState.railExtraWidth`。
  var railExtraWidth: CGFloat {
    guard Defaults[.managementRailVisible] else { return 0 }
    let width = min(
      max(Defaults[.managementRailWidth], PanelSplit.navigationRailMinWidth),
      PanelSplit.navigationRailMaxWidth
    )
    return max(0, width - PanelSplit.navigationRailWidth)
  }

  /// 窗口里左侧那一整块（左栏 + 条目列）。frame 宽度以它为准。
  /// 左栏向外展开时窗口向左长 railExtraWidth，条目列宽度不变。
  var totalListWidth: CGFloat {
    layoutListWidth + railExtraWidth
  }

  /// Width the slideout content frame must use. Read the observed rail flag,
  /// not a stale narrow width: a center-aligned parent then leaves half the
  /// extra as a blank strip between the window edge and the sidebar.
  func listSpan(railVisible: Bool, railWidth: CGFloat) -> CGFloat {
    let extra = railVisible ? max(0, railWidth - PanelSplit.navigationRailWidth) : 0
    return layoutListWidth + extra
  }

  /// Visual width of the slideout content column: rail plus list.
  /// The setter still writes the stored list width. Callers that assign it
  /// (divider drag, narrow smoke) already pass a list-only value.
  var contentWidth: CGFloat {
    get { totalListWidth }
    set { layoutListWidth = max(minimumContentWidth, newValue).rounded() }
  }
  var slideoutWidth: CGFloat {
    get { layoutPreviewWidth }
    set { layoutPreviewWidth = max(minimumSlideoutWidth, newValue).rounded() }
  }

  var state: SlideoutState = .open {
    didSet {
      guard notifiesPreviewClose, oldValue.isOpen, !state.isOpen else { return }
      AppState.shared.notePreviewClosed()
    }
  }
  /// Set after AppState finishes init so the first layout does not clear editors.
  var notifiesPreviewClose = false
  /// Temporary OCR strip. Not part of the saved split.
  var temporaryOCRWidth: CGFloat = 0
  /// Preview points lent to the OCR column so a screen-wide window can fit.
  /// Not written to `layoutPreviewWidth` or Defaults.
  var temporaryPreviewBorrow: CGFloat = 0
  /// Frame before the temporary column. Position saves use this, not the shifted frame.
  var ocrBaseFrame: CGRect?
  var suppressesFramePersistence = false
  var resizingMode: ResizingMode = .none

  var nswindow: NSWindow? {
    AppState.shared.appDelegate?.panel
  }

  var currentSplit: PanelSplit {
    PanelSplit(
      listWidth: layoutListWidth,
      previewWidth: layoutPreviewWidth,
      previewOpen: state.isOpen,
      height: currentHeight
    )
  }

  func savedSplit() -> PanelSplit {
    PanelSplit(
      listWidth: PanelSplit.finite(Defaults[.listColumnWidth], fallback: PanelSplit.defaultList),
      previewWidth: PanelSplit.finite(Defaults[.previewColumnWidth], fallback: PanelSplit.defaultPreview),
      previewOpen: Defaults[.openPreviewAutomatically],
      height: PanelSplit.finite(Defaults[.windowSize].height, fallback: PanelSplit.defaultHeight)
    )
  }

  func applyLayout(split: PanelSplit) {
    layoutListWidth = split.listWidth
    layoutPreviewWidth = split.previewWidth
    currentHeight = split.height
    state = split.previewOpen ? .open : .closed
  }

  func applyLayout(screen: NSScreen?) {
    let availableWidth = screen?.visibleFrame.width ?? 1440
    let availableHeight = screen?.visibleFrame.height ?? 900
    applyLayout(split: savedSplit().fitted(availableWidth: availableWidth, availableHeight: availableHeight))
  }

  func commitWidths() {
    Defaults[.listColumnWidth] = layoutListWidth
    Defaults[.previewColumnWidth] = layoutPreviewWidth
    var size = Defaults[.windowSize]
    size.height = currentHeight
    Defaults[.windowSize] = size
  }

  var visualPreviewWidth: CGFloat {
    max(0, layoutPreviewWidth - temporaryPreviewBorrow)
  }

  var visualSlideoutWidth: CGFloat {
    (visualPreviewWidth + temporaryOCRWidth).rounded()
  }

  /// Frame that may be written to Defaults. The shifted OCR frame is not one of these.
  func persistedFrame(fallback: CGRect) -> CGRect {
    ocrBaseFrame ?? fallback
  }

  func absorbWidth(_ total: CGFloat) {
    let floor = nswindow?.screen.map {
      PanelSplit.previewFloor(availableWidth: $0.visibleFrame.width, listWidth: layoutListWidth)
    } ?? minimumSlideoutWidth
    let base = total - temporaryOCRWidth + temporaryPreviewBorrow - railExtraWidth
    let next = currentSplit.absorbing(totalWidth: base, previewFloor: floor)
    layoutListWidth = next.listWidth
    layoutPreviewWidth = next.previewWidth
  }

  /// Divider drag. `visualSlideoutWidth` includes the temporary column; the saved split must not.
  func applyDividerDrag(translation: CGFloat, windowWidth: CGFloat, visualSlideoutWidth: CGFloat) {
    let baseWindow = windowWidth - temporaryOCRWidth + temporaryPreviewBorrow - railExtraWidth
    let startPreview = visualSlideoutWidth - temporaryOCRWidth + temporaryPreviewBorrow
    slideoutWidth = min(
      max(minimumSlideoutWidth, startPreview + translation),
      baseWindow - minimumContentWidth
    )
    contentWidth = baseWindow - slideoutWidth
  }

  func setTemporaryOCRWidth(_ width: CGFloat) {
    if width <= 0 {
      clearTemporaryOCR()
      return
    }
    presentTemporaryOCR(desired: width)
  }

  func presentTemporaryOCR(desired: CGFloat = OCRColumnLayout.width) {
    guard let window = nswindow, let screen = window.screen?.visibleFrame, screen.width > 0 else {
      temporaryOCRWidth = OCRColumnLayout.widthThatFits(
        availableWidth: nswindow?.screen?.visibleFrame.width ?? 1440,
        occupiedWidth: layoutListWidth + (state.isOpen ? layoutPreviewWidth : 0)
      )
      temporaryPreviewBorrow = 0
      return
    }
    if ocrBaseFrame == nil {
      ocrBaseFrame = window.frame
    }
    let fit = OCRFramePlanner.fit(
      window: ocrBaseFrame ?? window.frame,
      screen: screen,
      listWidth: layoutListWidth,
      railWidth: railExtraWidth,
      previewWidth: layoutPreviewWidth,
      previewOpen: state.isOpen,
      desiredWidth: desired
    )
    temporaryOCRWidth = fit.ocrWidth
    temporaryPreviewBorrow = max(0, layoutPreviewWidth - fit.previewWidth)
    setFrameSuppressingPersistence(fit.frame)
  }

  func clearTemporaryOCR() {
    let base = ocrBaseFrame
    temporaryOCRWidth = 0
    temporaryPreviewBorrow = 0
    ocrBaseFrame = nil
    guard let window = nswindow, let base else { return }
    var frame = base
    frame.size.width = totalListWidth + (state.isOpen ? layoutPreviewWidth : 0)
    frame.size.height = currentHeight
    if let screen = window.screen?.visibleFrame {
      frame = OCRFramePlanner.restored(base: frame, screen: screen)
    }
    setFrameSuppressingPersistence(frame)
  }

  private func setFrameSuppressingPersistence(_ frame: CGRect) {
    suppressesFramePersistence = true
    defer { suppressesFramePersistence = false }
    nswindow?.setFrame(frame, display: false)
  }

  func nudgeDivider(previewDelta: CGFloat) {
    guard state.isOpen, let window = nswindow else { return }
    let total = window.frame.width - temporaryOCRWidth + temporaryPreviewBorrow
    let next = currentSplit.redistributed(previewDelta: previewDelta, totalWidth: total)
    layoutListWidth = next.listWidth
    layoutPreviewWidth = next.previewWidth
    commitWidths()
  }

  /// Explicit toggle or the settings switch. Auto-open must not widen the window later.
  func togglePreview() {
    let opening = !state.isOpen
    Defaults[.openPreviewAutomatically] = opening
    guard let window = nswindow, let visible = window.screen?.visibleFrame else {
      state = opening ? .open : .closed
      return
    }
    let next = currentSplit.frameAfterSettingPreview(
      open: opening,
      from: window.frame,
      in: visible,
      railExtra: railExtraWidth
    )
    layoutListWidth = next.split.listWidth
    layoutPreviewWidth = next.split.previewWidth
    currentHeight = next.split.height
    state = next.split.previewOpen ? .open : .closed
    window.setFrame(next.frame, display: true)
  }

  func endResize() {
    resizingMode = .none
    commitWidths()
  }

  func startAutoOpen() {}

  func cancelAutoOpen() {}

  func enableAutoOpen() {}

  func disableAutoOpen() {}

  func resetAutoOpenSuppression() {}
}
