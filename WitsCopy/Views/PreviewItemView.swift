import AppKit
import Defaults
import PDFKit
import SwiftUI

@MainActor
@Observable
final class PreviewModel {
  var kind: PreviewRenderKind = .fallback
  var notice: PreviewNotice?
  var textRender: PreviewTextRender?
  var staticImage: NSImage?
  var gifFrames: [NSImage] = []
  var gifProvider: GIFFrameProvider?
  var gifTimeline: GIFTimeline?
  var gifToken = 0
  var pdfDocument: PDFDocument?
  var pdfPageIndex = 0
  var pdfPageCount = 0
  var pdfScale: CGFloat = 1
  var officeText: String?
  var systemURL: URL?
  /// Set only from the text that was copied directly, never from the body of
  /// a text file: a path inside a document is content, not a destination.
  var openTarget: PreviewOpenTarget?
  /// Video and audio: nil while the file is being looked at, then whether
  /// AVKit can play it. Unplayable media falls back to Quick Look.
  var mediaPlayable: Bool?
  var mediaHasVideo = false
  var audioInfo = AudioInfo()
  var playback: MediaPlayback?
  var filename: String?
  var application: String?
  var firstCopiedAt: Date?
  var lastCopiedAt: Date?
  var numberOfCopies = 0
  var pixelSize: CGSize?
  var fileURLs: [URL] = []
  var title = ""
  private var imageData: Data?

  func stopMedia() {
    playback?.stop()
    playback = nil
    gifProvider?.release()
    gifProvider = nil
    gifFrames = []
    gifTimeline = nil
    gifToken += 1
    pdfDocument = nil
    staticImage = nil
  }

  func load(
    item: HistoryItemDecorator,
    fileIndex: Int,
    session: PreviewSession,
    mode: PreviewTextMode?
  ) async {
    guard !item.isRemoved, !Task.isCancelled else { return }
    AppState.shared.closeOCR()
    let source = PreviewSnapshotter.capture(
      item.item,
      identity: item.id.uuidString,
      application: item.application
    )
    guard let token = session.begin(allowed: true, identity: source.identity) else { return }
    session.mediaStop = { [weak self] in self?.stopMedia() }
    resetContent()
    applyMetadata(source)
    guard let route = await PreviewClassifier.resolve(
      source: source,
      fileIndex: fileIndex,
      metrics: session.metrics,
      permit: session.currentReadPermit
    ) else { return }
    guard session.isCurrent(token), !Task.isCancelled, !item.isRemoved else { return }
    kind = route.kind
    if let routeNotice = route.notice { notice = routeNotice }
    switch route.kind {
    case .missing:
      notice = .missingReference
    case .plain, .code, .markdown:
      await loadText(source, fileIndex: fileIndex, token: token, session: session, mode: mode)
    case .image:
      await loadStill(source, fileIndex: fileIndex, token: token, session: session)
    case .gif:
      await loadGIF(source, fileIndex: fileIndex, token: token, session: session)
    case .pdf:
      await loadPDF(source, fileIndex: fileIndex, token: token, session: session)
    case .office:
      await loadOffice(source, fileIndex: fileIndex, token: token, session: session)
    case .media:
      systemURL = selectedURL(source, fileIndex)
      if let url = systemURL {
        let result = await MediaInfoLoader.load(url)
        guard session.isCurrent(token), !Task.isCancelled else { return }
        mediaPlayable = result.playable
        mediaHasVideo = result.hasVideo
        audioInfo = result.info
        if result.playable {
          playback?.stop()
          playback = MediaPlayback(url: url, duration: result.info.duration, autoplay: true)
        }
      }
    case .fallback:
      systemURL = selectedURL(source, fileIndex)
    }
  }

  func recognize(item: HistoryItemDecorator, session: PreviewSession) {
    session.cancelRecognition()
    let token = session.currentToken
    guard session.isCurrent(token), !item.isRemoved else { return }
    guard let data = imageData else {
      AppState.shared.beginOCR(for: item)
      AppState.shared.failOCR(
        NSLocalizedString("CannotDecode", tableName: "PreviewItemView", comment: ""),
        generation: AppState.shared.ocrGeneration,
        itemID: item.id
      )
      return
    }
    AppState.shared.beginOCR(for: item)
    let generation = AppState.shared.ocrGeneration
    let itemID = item.id
    session.startRecognition(data: data, token: token) { result in
      guard session.isCurrent(token) else { return }
      switch result {
      case .success(let blocks):
        AppState.shared.commitOCR(blocks, generation: generation, itemID: itemID)
      case .failure(let error):
        AppState.shared.failOCR(error.localizedDescription, generation: generation, itemID: itemID)
      }
    }
  }

  private func resetContent() {
    notice = nil
    textRender = nil
    staticImage = nil
    gifFrames = []
    gifProvider?.release()
    gifProvider = nil
    gifTimeline = nil
    pdfDocument = nil
    pdfPageIndex = 0
    pdfPageCount = 0
    officeText = nil
    systemURL = nil
    openTarget = nil
    mediaPlayable = nil
    mediaHasVideo = false
    audioInfo = AudioInfo()
    playback?.stop()
    playback = nil
    imageData = nil
    pixelSize = nil
  }

  private func applyMetadata(_ source: PreviewSource) {
    title = source.title
    filename = source.filename
    application = source.application
    firstCopiedAt = source.firstCopiedAt
    lastCopiedAt = source.lastCopiedAt
    numberOfCopies = source.numberOfCopies
    fileURLs = source.fileURLs
    pixelSize = source.pixelSize
  }

  private func loadText(
    _ source: PreviewSource,
    fileIndex: Int,
    token: UInt64,
    session: PreviewSession,
    mode: PreviewTextMode?
  ) async {
    // Only the copied text counts. What a text file contains is the item's
    // body, so a path inside it must not become a jump target.
    openTarget = PreviewOpenTarget.resolve(source.text)
    var text = source.text ?? ""
    var truncated = false
    if text.isEmpty, let url = selectedURL(source, fileIndex) {
      let read = await PreviewFileAccess.read(
        url: url,
        limit: PreviewLimits.maxTextReadBytes,
        policy: .text,
        metrics: session.metrics,
        permit: session.currentReadPermit
      )
      guard session.isCurrent(token), !Task.isCancelled, !readWasCancelled(read) else { return }
      if read?.missing == true {
        kind = .missing
        notice = .missingReference
        return
      }
      guard read?.readFailed != true,
            let decoded = PreviewClassifier.decodeUTF8(read?.data ?? Data(), truncated: read?.truncated == true) else {
        notice = .cannotDecode
        return
      }
      text = decoded
      truncated = read?.truncated == true
    }
    guard session.isCurrent(token) else { return }
    let filename = selectedURL(source, fileIndex)?.lastPathComponent ?? source.filename
    let render = PreviewTextRenderer.render(text: text, filename: filename, mode: mode)
    textRender = render
    if truncated || render.truncated { notice = .truncated }
  }

  private func loadStill(
    _ source: PreviewSource,
    fileIndex: Int,
    token: UInt64,
    session: PreviewSession
  ) async {
    guard let prepared = await preparedImage(source, fileIndex: fileIndex, token: token, session: session) else { return }
    guard session.isCurrent(token), !Task.isCancelled else { return }
    // APNG and animated WebP/HEICS play like GIF.
    if let data = prepared.data, GraphicFormats.isAnimated(data: data) {
      kind = .gif
      await playAnimated(data, pixelSize: prepared.pixelSize, token: token, session: session)
      return
    }
    imageData = prepared.data
    pixelSize = prepared.pixelSize ?? pixelSize
    if prepared.data != nil { PreviewRecognizer.prewarm() }
    if let cg = prepared.image {
      staticImage = NSImage(cgImage: cg, size: pointSize(prepared.pixelSize))
    } else {
      notice = .cannotDecode
    }
  }

  private func loadGIF(
    _ source: PreviewSource,
    fileIndex: Int,
    token: UInt64,
    session: PreviewSession
  ) async {
    guard let prepared = await preparedImage(source, fileIndex: fileIndex, token: token, session: session) else { return }
    guard var data = prepared.data, session.isCurrent(token), !Task.isCancelled else { return }
    var size = prepared.pixelSize
    if GraphicFormats.isAnimatedCursor(data) {
      let cursor = data
      let converted = try? await PreviewHeavyQueue.shared.perform(metrics: session.metrics) {
        GraphicFormats.animatedCursorAsPNG(cursor)
      }
      guard session.isCurrent(token), !Task.isCancelled else { return }
      guard let png = converted ?? nil else {
        notice = .cannotDecode
        return
      }
      data = png
      size = ImageProbe.pixelSize(data: png)
    }
    await playAnimated(data, pixelSize: size, token: token, session: session)
  }

  private func playAnimated(
    _ data: Data,
    pixelSize framePixels: CGSize?,
    token: UInt64,
    session: PreviewSession
  ) async {
    imageData = data
    pixelSize = framePixels ?? pixelSize
    PreviewRecognizer.prewarm()
    let metrics = session.metrics
    let plan: GIFPlaybackPlan
    do {
      plan = try await PreviewHeavyQueue.shared.perform(metrics: metrics) {
        GIFPlayback.plan(data: data, maxEdge: PreviewLimits.maxImageEdge, metrics: metrics)
      }
    } catch {
      return
    }
    guard session.isCurrent(token), !Task.isCancelled else {
      if case .stream(let provider) = plan { provider.release() }
      return
    }
    switch plan {
    case .stream(let provider):
      gifProvider?.release()
      gifProvider = provider
      gifTimeline = provider.timeline
      gifFrames = []
      gifToken += 1
    case .still(let image, let reason):
      staticImage = NSImage(
        cgImage: image,
        size: pointSize(CGSize(width: image.width, height: image.height))
      )
      notice = reason
    case .failed(let reason):
      notice = reason
    }
  }

  private func loadPDF(
    _ source: PreviewSource,
    fileIndex: Int,
    token: UInt64,
    session: PreviewSession
  ) async {
    guard let url = selectedURL(source, fileIndex) else { return }
    let read = await PreviewFileAccess.read(
      url: url,
      limit: PreviewLimits.maxDocumentBytes,
      policy: .complete,
      metrics: session.metrics,
      permit: session.currentReadPermit
    )
    guard session.isCurrent(token), !Task.isCancelled else { return }
    if read?.missing == true {
      kind = .missing
      notice = .missingReference
      return
    }
    if read?.refusedPartial == true || read?.truncated == true {
      notice = .oversize
      return
    }
    guard let data = read?.data, !data.isEmpty, let document = PDFDocument(data: data) else {
      notice = .cannotDecode
      return
    }
    pdfDocument = document
    pdfPageCount = document.pageCount
    pdfPageIndex = 0
    pdfScale = 1
  }

  private func loadOffice(
    _ source: PreviewSource,
    fileIndex: Int,
    token: UInt64,
    session: PreviewSession
  ) async {
    guard let url = selectedURL(source, fileIndex) else { return }
    systemURL = url
    let read = await PreviewFileAccess.read(
      url: url,
      limit: PreviewLimits.maxDocumentBytes,
      policy: .complete,
      metrics: session.metrics,
      permit: session.currentReadPermit
    )
    guard session.isCurrent(token), !Task.isCancelled else { return }
    if read?.missing == true {
      notice = .missingReference
      systemURL = nil
      return
    }
    if read?.readFailed == true {
      notice = .cannotDecode
      systemURL = nil
      return
    }
    if read?.refusedPartial == true || read?.truncated == true {
      notice = .oversize
      return
    }
    guard let data = read?.data, !data.isEmpty else { return }
    let text: String?
    do {
      text = try await PreviewHeavyQueue.shared.perform(metrics: session.metrics) {
        OfficeTextExtractor.extractDocx(data)
      }
    } catch {
      return
    }
    guard session.isCurrent(token), !Task.isCancelled else { return }
    if let text {
      officeText = text
      notice = .officeExtracted
    }
  }

  private func preparedImage(
    _ source: PreviewSource,
    fileIndex: Int,
    token: UInt64,
    session: PreviewSession
  ) async -> (data: Data?, image: CGImage?, pixelSize: CGSize?)? {
    if case .data(let data) = source.image, source.fileURLs.isEmpty {
      let decoded: (CGImage?, CGSize?)
      do {
        decoded = try await PreviewHeavyQueue.shared.perform(metrics: session.metrics) {
          (
            ImageProbe.downsample(data: data, maxEdge: PreviewLimits.maxImageEdge),
            ImageProbe.pixelSize(data: data)
          )
        }
      } catch {
        return nil
      }
      guard session.isCurrent(token), !Task.isCancelled else { return nil }
      return (data, decoded.0, decoded.1)
    }
    guard let url = selectedURL(source, fileIndex) else { return nil }
    let read = await PreviewFileAccess.read(
      url: url,
      limit: PreviewLimits.maxDocumentBytes,
      policy: .complete,
      metrics: session.metrics,
      permit: session.currentReadPermit
    )
    guard session.isCurrent(token), !Task.isCancelled else { return nil }
    if read?.missing == true {
      notice = .missingReference
      return nil
    }
    if read?.readFailed == true {
      notice = .cannotDecode
      return nil
    }
    if read?.refusedPartial == true || read?.truncated == true {
      notice = .oversize
      return nil
    }
    guard let data = read?.data, !data.isEmpty else { return nil }
    let decoded: (CGImage?, CGSize?)
    do {
      decoded = try await PreviewHeavyQueue.shared.perform(metrics: session.metrics) {
        (
          ImageProbe.downsample(data: data, maxEdge: PreviewLimits.maxImageEdge),
          ImageProbe.pixelSize(data: data)
        )
      }
    } catch {
      return nil
    }
    guard session.isCurrent(token), !Task.isCancelled else { return nil }
    if decoded.0 == nil, GraphicFormats.isSVG(data) {
      let vector = try? await PreviewHeavyQueue.shared.perform(metrics: session.metrics) {
        GraphicFormats.rasterizeSVG(data, maxEdge: PreviewLimits.maxImageEdge)
      }
      guard session.isCurrent(token), !Task.isCancelled else { return nil }
      if let vector = vector ?? nil {
        return (data, vector.image, vector.size)
      }
    }
    return (data, decoded.0, decoded.1)
  }

  private func readWasCancelled(_ read: BoundedFileRead?) -> Bool {
    read == nil
  }

  private func selectedURL(_ source: PreviewSource, _ index: Int) -> URL? {
    source.fileURLs.indices.contains(index) ? source.fileURLs[index] : source.fileURLs.first
  }

  private func pointSize(_ pixels: CGSize?) -> NSSize {
    guard let pixels else { return NSSize(width: 320, height: 180) }
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    return NSSize(width: pixels.width / scale, height: pixels.height / scale)
  }
}

struct PreviewItemView: View {
  var item: HistoryItemDecorator
  @Environment(AppState.self) private var appState

  @State private var session = PreviewSession()
  @State private var model = PreviewModel()
  /// Prose wraps by default; code does not, like an editor, because its long
  /// lines (minified CSS/JS above all) read better scrolled than folded. Each
  /// remembers its own toggle while the app runs.
  @State private var textWraps = true
  @State private var codeWraps = false
  private var wraps: Bool { model.kind == .code ? codeWraps : textWraps }
  private func toggleWraps() {
    if model.kind == .code { codeWraps.toggle() } else { textWraps.toggle() }
  }
  @State private var showLineNumbers = true
  @State private var fileIndex = 0
  @State private var showSystemPreview = false
  @State private var richEditing = false
  @State private var categoryMenu = false
  @Default(.workspaceTagDirectory) private var storedTags

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if model.fileURLs.count > 1 {
        Picker(selection: $fileIndex) {
          ForEach(model.fileURLs.indices, id: \.self) { index in
            Text(model.fileURLs[index].lastPathComponent).tag(index)
          }
        } label: {
          Text("kind_file")
        }
        .labelsHidden()
        .accessibilityIdentifier("lab-file-picker")
        .iconHelp(NSLocalizedString("kind_file", comment: ""))
      }

      previewTools
      previewCanvas
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      if let notice = model.notice, !noticeRepeatsBody(notice) {
        Text(noticeText(notice))
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("lab-preview-notice")
      }

      HStack(alignment: .bottom, spacing: 8) {
        metadata
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier("lab-preview-metadata")
        PreviewCornerActions(item: item, onCategoryTap: toggleCategoryMenu)
      }
      .padding(.horizontal, 16)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .overlay(alignment: .bottomTrailing) {
      previewAuxiliary
        .padding(.trailing, 8)
        .padding(.bottom, 8)
    }
    .overlayPreferenceValue(PreviewCategoryBadgeAnchor.self) { anchor in
      categorySelector(anchor: anchor)
    }
    .task(id: "\(item.id.uuidString)#\(item.contentRevision)#\(fileIndex)") {
      showSystemPreview = false
      await model.load(item: item, fileIndex: fileIndex, session: session, mode: nil)
      if model.systemURL != nil, model.kind == .office || model.kind == .media {
        showSystemPreview = true
      }
    }
    .onAppear {
      appState.cancelPreviewRecognition = { session.cancelRecognition() }
    }
    .onChange(of: fileIndex) { _, _ in
      appState.closeOCR()
    }
    .onChange(of: item.id) { _, _ in
      dismissCategoryMenu()
      session.cancel()
      model.stopMedia()
      showSystemPreview = false
      appState.closeOCR()
    }
    .onChange(of: item.item.tags.first) { _, _ in
      dismissCategoryMenu()
    }
    .onChange(of: appState.previewAllowed) { _, allowed in
      if !allowed { dismissCategoryMenu() }
    }
    .onDisappear {
      dismissCategoryMenu()
      session.cancel()
      model.stopMedia()
      showSystemPreview = false
      appState.cancelPreviewRecognition = nil
      appState.closeOCR()
    }
  }

  @ViewBuilder
  private func categorySelector(anchor: Anchor<CGRect>?) -> some View {
    if categoryMenu, let anchor, let current = item.item.tags.first {
      GeometryReader { geometry in
        let badge = geometry[anchor]
        let categories = WorkspaceTagDirectory.ordered(stored: storedTags, itemTags: appState.history.knownTags)
        let frame = PreviewCategorySelectorPlacement.frame(in: geometry.size, badge: badge, categories: categories)
        ZStack(alignment: .topLeading) {
          PreviewCategorySelectorInput(listFrame: frame, onDismiss: dismissCategoryMenu)
            .allowsHitTesting(false)
          if !frame.isEmpty {
            PreviewCategoryChoices(categories: categories, current: current) { name in
              if name.caseInsensitiveCompare(current) != .orderedSame {
                appState.moveToCategory(item, name: name)
              }
              dismissCategoryMenu()
            }
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
          }
        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        .onChange(of: frame.isEmpty, initial: true) { _, empty in
          if empty { dismissCategoryMenu() }
        }
      }
      .clipped()
    }
  }

  private func toggleCategoryMenu() {
    if categoryMenu {
      dismissCategoryMenu()
    } else {
      guard !appState.menuTracking else { return }
      appState.cancelForegroundInputSession()
      // 复用现有菜单输入生命周期：浏览 Esc / 窗外点击不得同时关闭主面板。
      appState.menuTracking = true
      categoryMenu = true
    }
  }

  private func dismissCategoryMenu() {
    guard categoryMenu else { return }
    categoryMenu = false
    appState.menuTracking = false
  }

  @ViewBuilder
  private var previewTools: some View {
    let tools = PreviewToolStrip.tools(
      kind: model.kind.rawValue,
      hasSystemURL: model.systemURL != nil,
      hasOpenTarget: model.openTarget != nil
    )
    if !tools.isEmpty {
      HStack(spacing: 8) {
        if tools.contains(.wrap) {
          toolButton(
            systemName: "arrow.turn.down.left",
            help: NSLocalizedString("WrapLines", tableName: "PreviewItemView", comment: ""),
            identifier: "lab-wrap-toggle",
            label: NSLocalizedString("WrapLines", tableName: "PreviewItemView", comment: ""),
            tint: wraps ? .controlAccentColor : .secondaryLabelColor,
            action: { toggleWraps() }
          )
        }
        if tools.contains(.open), let target = model.openTarget {
          let help = openHelp(target)
          toolButton(
            systemName: openSymbolName(target),
            help: help,
            identifier: "lab-open-target",
            label: help,
            action: { openTarget(target) }
          )
        }
        if tools.contains(.lineNumbers) {
          toolButton(
            systemName: "list.number",
            help: NSLocalizedString("LineNumbers", tableName: "PreviewItemView", comment: ""),
            identifier: "lab-line-numbers",
            label: NSLocalizedString("LineNumbers", tableName: "PreviewItemView", comment: ""),
            tint: showLineNumbers ? .controlAccentColor : .secondaryLabelColor,
            action: { showLineNumbers.toggle() }
          )
        }
        if let label = model.textRender?.languageLabel, model.kind == .code {
          Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .accessibilityIdentifier("lab-language-badge")
        }
        if tools.contains(.pdfZoomOut) {
          toolButton(
            systemName: "minus.magnifyingglass",
            help: NSLocalizedString("ZoomOut", tableName: "PreviewItemView", comment: ""),
            identifier: "lab-pdf-zoom-out",
            label: NSLocalizedString("ZoomOut", tableName: "PreviewItemView", comment: ""),
            action: { model.pdfScale = max(0.5, model.pdfScale - 0.25) }
          )
          toolButton(
            systemName: "plus.magnifyingglass",
            help: NSLocalizedString("ZoomIn", tableName: "PreviewItemView", comment: ""),
            identifier: "lab-pdf-zoom-in",
            label: NSLocalizedString("ZoomIn", tableName: "PreviewItemView", comment: ""),
            action: { model.pdfScale = min(3, model.pdfScale + 0.25) }
          )
          toolButton(
            systemName: "chevron.left",
            help: NSLocalizedString("pdf_previous_page", comment: ""),
            identifier: "lab-pdf-prev",
            label: NSLocalizedString("pdf_previous_page", comment: ""),
            enabled: model.pdfPageIndex > 0,
            action: { if model.pdfPageIndex > 0 { model.pdfPageIndex -= 1 } }
          )
          Text("\(model.pdfPageIndex + 1)/\(max(model.pdfPageCount, 1))")
            .accessibilityIdentifier("lab-pdf-page")
          toolButton(
            systemName: "chevron.right",
            help: NSLocalizedString("pdf_next_page", comment: ""),
            identifier: "lab-pdf-next",
            label: NSLocalizedString("pdf_next_page", comment: ""),
            enabled: model.pdfPageIndex + 1 < model.pdfPageCount,
            action: { if model.pdfPageIndex + 1 < model.pdfPageCount { model.pdfPageIndex += 1 } }
          )
        }
        if tools.contains(.systemPreview) {
          Button {
            showSystemPreview.toggle()
          } label: {
            Text(showSystemPreview ? "SourceMode" : "OpenSystemPreview", tableName: "PreviewItemView")
          }
          .accessibilityIdentifier("lab-system-preview-toggle")
          .iconHelp(NSLocalizedString(
            showSystemPreview ? "SourceMode" : "OpenSystemPreview",
            tableName: "PreviewItemView",
            comment: ""
          ))
        }
        if tools.contains(.recognize) {
          ocrButton
        }
      }
      .controlSize(.small)
      .padding(.horizontal, 16)
      .padding(.top, 6)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("lab-preview-tools")
    }
  }

  private func toolButton(
    systemName: String,
    help: String,
    identifier: String,
    label: String,
    tint: NSColor = .secondaryLabelColor,
    enabled: Bool = true,
    action: @escaping () -> Void
  ) -> some View {
    ImmediateIconButton(
      systemName: systemName,
      help: help,
      identifier: identifier,
      label: label,
      tint: tint,
      enabled: enabled,
      action: action
    )
    .frame(width: 28, height: 24)
    .modifier(LabToolbarChrome(nativePassthrough: true))
  }

  private func openSymbolName(_ target: PreviewOpenTarget) -> String {
    switch target {
    case .web: return "link"
    case .file: return "folder"
    }
  }

  private func openHelp(_ target: PreviewOpenTarget) -> String {
    let key: String
    switch target {
    case .web: key = "OpenInBrowser"
    case .file(_, isDirectory: true): key = "OpenInFinder"
    case .file: key = "RevealInFinder"
    }
    return NSLocalizedString(key, tableName: "PreviewItemView", comment: "")
  }

  /// A page and a folder both belong to their default app. A file inside a
  /// folder is better shown than launched, so Finder selects it.
  /// An unpinned panel hides before the other app comes forward. A pinned
  /// panel is the user's explicit exception and stays.
  /// This runs on mouse-down. Hiding while the button is held leaves the
  /// window on screen with its content gone, so the panel defers the hide to
  /// the release, and the other app is brought forward only after that.
  private func openTarget(_ target: PreviewOpenTarget) {
    let shouldClose = PanelClosePolicy.decide(.externalHandoff, context: appState.focusContext) == .close
    if shouldClose {
      appState.popup.close()
    }
    let handOff = {
      DispatchQueue.main.async {
        self.handOff(target)
      }
    }
    if let panel = appState.appDelegate?.panel {
      panel.afterPointerRelease(handOff)
    } else {
      handOff()
    }
  }

  private func handOff(_ target: PreviewOpenTarget) {
    switch target {
    case .web(let url):
      _ = NSWorkspace.shared.open(url)
    case .file(let url, let isDirectory):
      if isDirectory {
        _ = NSWorkspace.shared.open(url)
      } else {
        NSWorkspace.shared.activateFileViewerSelecting([url])
      }
    }
  }

  private var centersInCanvas: Bool {
    switch model.kind {
    case .image, .gif, .pdf:
      return true
    case .media, .fallback:
      return showSystemPreview
    default:
      return false
    }
  }

  private var previewCanvas: some View {
    PreviewCanvasBox()
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .overlay {
        previewBody
          .padding(PreviewCanvasMetrics.inset)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: centersInCanvas ? .center : .topLeading)
          .clipped()
      }
      .overlay(alignment: .topLeading) {
        if LabRuntime.isRichSmoke {
          RichColumnMark(
            columns: RichColumnReadout.summary(item.item.contents.compactMap { content in
              guard let value = content.value else { return nil }
              return (content.type, value)
            }),
            traits: RichColumnReadout.traits(uneditedRich ?? NSAttributedString(string: ""))
          )
          .frame(width: 1, height: 1)
        }
      }
  }

  @ViewBuilder
  private var previewBody: some View {
    switch model.kind {
    case .missing:
      Text("FileUnavailable", tableName: "PreviewItemView")
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("lab-file-missing")
    case .plain, .code, .markdown:
      if richBacked {
        RichTextEditSection(
          identity: RichTextIdentity.modelKey(item.item),
          source: richSource,
          editing: $richEditing,
          wraps: wraps,
          onTransaction: { appState.commitRichTransaction($0, decoratorID: item.id) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      } else if OriginalTextEdit.refusal(for: item.item) == nil {
        OriginalTextEditSection(item: item, wraps: wraps)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      } else if let render = model.textRender {
        SelectableTextPreview(render: render, wraps: wraps, showsLineNumbers: showLineNumbers && render.monospace)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .accessibilityIdentifier("lab-text-preview")
      }
    case .image:
      imageBody
    case .gif:
      if let provider = model.gifProvider, let timeline = model.gifTimeline {
        gifInCanvas(provider: provider, timeline: timeline)
          .accessibilityIdentifier("lab-gif-preview")
      } else {
        imageBody
      }
    case .pdf:
      if let document = model.pdfDocument {
        PDFKitPreview(document: document, pageIndex: model.pdfPageIndex, scale: model.pdfScale)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityIdentifier("lab-pdf-preview")
      }
    case .office:
      officeBody
    case .media, .fallback:
      systemBody
    }
  }

  private var ocrButton: some View {
    ImmediateIconButton(
      systemName: "text.viewfinder",
      help: NSLocalizedString("RecognizeText", tableName: "PreviewItemView", comment: ""),
      identifier: "lab-ocr-button",
      label: NSLocalizedString("RecognizeText", tableName: "PreviewItemView", comment: ""),
      action: { model.recognize(item: item, session: session) }
    )
    .frame(width: 28, height: 24)
    .modifier(LabToolbarChrome(nativePassthrough: true))
    .accessibilityIdentifier("lab-ocr-button")
  }

  private func noticeRepeatsBody(_ notice: PreviewNotice) -> Bool {
    if notice == .officeExtracted { return true }
    return model.kind == .missing && notice == .missingReference
  }

  private var richBacked: Bool {
    item.item.contents.contains { RichTextTypes.isRich($0.type) }
  }

  private var richSource: RichTextSource {
    RichTextSource(
      representations: item.item.contents.compactMap { content in
        guard let value = content.value else { return nil }
        return RichTextRepresentation(type: content.type, value: value)
      },
      title: item.item.title,
      removed: item.isRemoved,
      fileBacked: !item.item.fileURLs.isEmpty,
      image: item.item.hasImagePayload
    )
  }

  private var uneditedRich: NSAttributedString? {
    let display = RichTextModel.assess(richSource).display
    return display.length > 0 ? display : nil
  }

  @ViewBuilder
  private var previewAuxiliary: some View {
    if appState.presentsTagEditor(item, at: .preview) {
      TagEditorPopover(item: item, compact: true)
        .environment(appState)
        .accessibilityIdentifier("lab-preview-aux")
    } else if appState.previewShortcutItemID == item.id, item.isPinned {
      PreviewPinShortcutHost(
        itemID: item.id,
        beginToken: appState.previewShortcutBeginToken,
        message: appState.pinShortcutMessage(for: item.id),
        error: appState.pinShortcutError(for: item.id)
      )
      .frame(width: 140, height: 44)
      .accessibilityIdentifier("lab-preview-aux")
    }
  }

  @ViewBuilder
  private var imageBody: some View {
    if let image = model.staticImage {
      FittedImageCanvas(image: image)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if model.notice == nil {
      ProgressView()
    }
  }

  @ViewBuilder
  private func gifInCanvas(provider: GIFFrameProvider, timeline: GIFTimeline) -> some View {
    let pixels = model.pixelSize ?? .zero
    if pixels.width > 1, pixels.height > 1 {
      GeometryReader { geo in
        let fitted = PreviewCanvasFit.size(pixels, in: geo.size)
        GIFPreviewView(provider: provider, timeline: timeline, playToken: model.gifToken)
          .frame(width: max(fitted.width, 1), height: max(fitted.height, 1))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    } else {
      GIFPreviewView(provider: provider, timeline: timeline, playToken: model.gifToken)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @ViewBuilder
  private var officeBody: some View {
    VStack(alignment: .leading, spacing: 6) {
      if showSystemPreview, let url = model.systemURL {
        QuickLookFileView(url: url, sessionID: "\(item.id.uuidString)-\(url.path)")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityIdentifier("lab-quicklook")
      }
      if let officeText = model.officeText {
        ScrollView {
          Text(officeText)
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("lab-office-text")
        }
        .frame(maxHeight: showSystemPreview ? 140 : .infinity)
      }
    }
  }

  @ViewBuilder
  private var systemBody: some View {
    if model.kind == .media, model.mediaPlayable == true, let url = model.systemURL, let playback = model.playback {
      mediaBody(url, playback: playback)
    } else if model.kind == .media, model.mediaPlayable == nil, model.systemURL != nil {
      ProgressView()
    } else if showSystemPreview, let url = model.systemURL {
      QuickLookFileView(
        url: url,
        sessionID: "\(item.id.uuidString)-\(url.path)-manual",
        autostarts: model.kind == .media
      )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("lab-quicklook")
    } else {
      Text(model.filename ?? "")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  /// Video fills the canvas; audio shows cover art (or a music glyph) with
  /// title and artist. Both use the same app-styled control bar below.
  @ViewBuilder
  private func mediaBody(_ url: URL, playback: MediaPlayback) -> some View {
    if model.mediaHasVideo {
      VStack(spacing: 8) {
        VideoSurface(player: playback.player)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        MediaControlBar(playback: playback)
          .padding(.horizontal, 8)
      }
      .accessibilityIdentifier("lab-video-preview")
    } else {
      VStack(spacing: 12) {
        Spacer(minLength: 0)
        Group {
          if let art = model.audioInfo.artwork {
            Image(nsImage: art)
              .resizable()
              .aspectRatio(contentMode: .fit)
              .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
          } else {
            Image(systemName: "music.note")
              .font(.system(size: 56, weight: .light))
              .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: 200, maxHeight: 200)
        VStack(spacing: 3) {
          Text(model.audioInfo.title ?? model.filename ?? url.lastPathComponent)
            .font(.headline)
            .lineLimit(2)
            .multilineTextAlignment(.center)
          let byline = [model.audioInfo.artist, model.audioInfo.album].compactMap { $0 }.joined(separator: " · ")
          if !byline.isEmpty {
            Text(byline)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        Spacer(minLength: 0)
        MediaControlBar(playback: playback)
          .frame(maxWidth: 480)
      }
      .padding(.horizontal, 16)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityIdentifier("lab-audio-preview")
    }
  }

  @ViewBuilder
  private var metadata: some View {
    VStack(alignment: .leading, spacing: 8) {
      Divider()
      if let application = model.application {
        labeled("Application", application)
      }
      if let size = model.pixelSize {
        labeled("Dimensions", "\(Int(size.width))×\(Int(size.height))")
          .accessibilityIdentifier("lab-image-dimensions")
      }
      if let filename = model.filename {
        labeled("File", filename)
      }
      if model.kind == .media, let duration = model.audioInfo.duration, duration > 0 {
        labeled("Duration", MediaInfoLoader.durationText(duration))
      }
      if let first = model.firstCopiedAt {
        labeled("FirstCopyTime", first.formatted(date: .abbreviated, time: .standard))
      }
      if let last = model.lastCopiedAt {
        labeled("LastCopyTime", last.formatted(date: .abbreviated, time: .standard))
      }
      labeled("NumberOfCopies", String(model.numberOfCopies))
    }
  }

  private func labeled(_ key: String, _ value: String) -> some View {
    HStack(spacing: 3) {
      Text(LocalizedStringKey(key), tableName: "PreviewItemView")
      Text(value)
    }
    .font(.caption)
  }

  private func noticeText(_ notice: PreviewNotice) -> String {
    switch notice {
    case .truncated:
      return NSLocalizedString("PreviewTruncated", tableName: "PreviewItemView", comment: "")
    case .oversize:
      return NSLocalizedString("OversizeSkipped", tableName: "PreviewItemView", comment: "")
    case .missingReference:
      return NSLocalizedString("FileUnavailable", tableName: "PreviewItemView", comment: "")
    case .remoteImagesSkipped:
      return NSLocalizedString("RemoteImageSkipped", tableName: "PreviewItemView", comment: "")
    case .officeExtracted:
      return NSLocalizedString("OfficeExtractedBody", tableName: "PreviewItemView", comment: "")
    case .cannotDecode:
      return NSLocalizedString("CannotDecode", tableName: "PreviewItemView", comment: "")
    case .systemPreviewUnavailable:
      return NSLocalizedString("SystemPreviewUnavailable", tableName: "PreviewItemView", comment: "")
    }
  }
}

private struct PreviewCategoryBadgeAnchor: PreferenceKey {
  static let defaultValue: Anchor<CGRect>? = nil

  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    value = nextValue() ?? value
  }
}

/// 坐标以预览列左上角为原点；底边与胶囊上沿留一道缝，空间不足时只缩短列表。
enum PreviewCategorySelectorPlacement {
  static let badgeGap: CGFloat = 4
  static let rowHeight: CGFloat = 24
  static let rowSpacing: CGFloat = 2
  static let contentInset: CGFloat = 4

  static func frame(in size: CGSize, badge: CGRect, categories: [String]) -> CGRect {
    let edge: CGFloat = 8
    let availableWidth = max(0, size.width - edge * 2)
    let bottom = min(badge.minY - badgeGap, size.height - edge)
    let count = categories.count
    let contentHeight = CGFloat(count) * rowHeight + CGFloat(max(0, count - 1)) * rowSpacing + contentInset * 2
    let height = min(240, contentHeight, max(0, bottom - edge))
    let titleWidth = categories.map {
      ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
    }.max() ?? 0
    // 为图形、勾选和两侧内边距留位，短名称不再撑成表单宽度。
    let preferredWidth = min(240, max(120, ceil(titleWidth) + 64, badge.width))
    let width = min(preferredWidth, availableWidth)
    guard count > 0, width > 0, height > 0 else { return .zero }
    let x = min(max(edge, badge.maxX - width), size.width - edge - width)
    return CGRect(x: x, y: bottom - height, width: width, height: height)
  }
}

private struct PreviewCategoryChoices: View {
  var categories: [String]
  var current: String
  var onChoose: (String) -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: PreviewCategorySelectorPlacement.rowSpacing) {
        ForEach(categories, id: \.self) { name in
          PreviewCategoryChoiceRow(
            name: name,
            current: name.caseInsensitiveCompare(current) == .orderedSame,
            action: { onChoose(name) }
          )
        }
      }
    }
    .padding(PreviewCategorySelectorPlacement.contentInset)
    .background {
      if #available(macOS 26.0, *) {
        GlassEffectView()
          .allowsHitTesting(false)
      } else {
        VisualEffectView()
          .allowsHitTesting(false)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: Popup.cornerRadius, style: .continuous))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("lab-preview-category-selector")
  }
}

private struct PreviewCategoryChoiceRow: View {
  var name: String
  var current: Bool
  var action: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      WorkspaceTagGlyph(tag: name, size: 12)
      Text(verbatim: name)
        .foregroundStyle(Color.primary)
        .lineLimit(1)
      Spacer(minLength: 0)
      if current {
        Image(systemName: "checkmark")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color.secondary)
      }
    }
    .font(.system(size: 12))
    .padding(.horizontal, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(height: PreviewCategorySelectorPlacement.rowHeight)
    .accessibilityHidden(true)
    .overlay {
      PreviewCategoryRowButton(name: name, current: current, action: action)
        .help(name)
    }
  }
}

/// 复用原生整行点击/悬停，避免 FloatingPanel 的立即按钮路由误点叠层下方的工具。
private struct PreviewCategoryRowButton: NSViewRepresentable {
  var name: String
  var current: Bool
  var action: () -> Void

  func makeNSView(context: Context) -> ImmediateActionButton {
    let button = ImmediateActionButton()
    button.title = ""
    button.isBordered = false
    button.setButtonType(.momentaryChange)
    updateNSView(button, context: context)
    return button
  }

  func updateNSView(_ button: ImmediateActionButton, context: Context) {
    button.onMouseDown = action
    button.setAccessibilityElement(true)
    button.setAccessibilityRole(.button)
    button.setAccessibilityIdentifier("lab-preview-tag-choice")
    button.setAccessibilityLabel(name)
    button.setAccessibilityValue(current)
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    nsView: ImmediateActionButton,
    context: Context
  ) -> CGSize? {
    CGSize(width: proposal.width ?? 120, height: proposal.height ?? PreviewCategorySelectorPlacement.rowHeight)
  }
}

/// 仅在列表展开时挂载。非命中视图只承载列坐标和临时事件路由，列表仍由 SwiftUI 命中。
private struct PreviewCategorySelectorInput: NSViewRepresentable {
  var listFrame: CGRect
  var onDismiss: () -> Void

  func makeNSView(context: Context) -> PreviewCategorySelectorInputView {
    let view = PreviewCategorySelectorInputView()
    view.listFrame = listFrame
    view.onDismiss = onDismiss
    return view
  }

  func updateNSView(_ view: PreviewCategorySelectorInputView, context: Context) {
    view.listFrame = listFrame
    view.onDismiss = onDismiss
  }

  static func dismantleNSView(_ view: PreviewCategorySelectorInputView, coordinator: ()) {
    view.stop()
  }
}

private final class PreviewCategorySelectorInputView: NSView {
  var listFrame = CGRect.zero
  var onDismiss: (() -> Void)?
  private var localMonitor: Any?
  private var outsideMonitor: Any?
  private var dismissing = false
  private weak var borrowedKeyWindow: NSWindow?

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window else {
      stop()
      return
    }
    guard localMonitor == nil else { return }
    dismissing = false
    let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      MainActor.assumeIsolated {
        guard let self else { return event }
        return self.route(event)
      }
    }
    outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
      MainActor.assumeIsolated {
        if event.type != .keyDown || event.keyCode == 53 { self?.dismissAfterEvent() }
      }
    }
    // 显式点胶囊才借用现有本窗 key 许可；不换 firstResponder，因此不会保存正文草稿。
    if !window.canBecomeKey, let localWindow = window as? LocalRecordingKeyWindow {
      borrowedKeyWindow = window
      localWindow.requestLocalRecordingKey()
    }
    window.makeKey()
  }

  func stop() {
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
    localMonitor = nil
    outsideMonitor = nil
    (borrowedKeyWindow as? LocalRecordingKeyWindow)?.releaseLocalRecordingKey()
    borrowedKeyWindow = nil
  }

  private func route(_ event: NSEvent) -> NSEvent? {
    guard let window else { return event }
    if event.type == .keyDown {
      guard event.window == nil || event.window === window else { return event }
      if event.keyCode == 53 { dismissAfterEvent() }
      // Return / ⌘Return 等不能漏给正文保存、列表粘贴或主窗快捷键。
      return nil
    }
    if !dismissing, event.window === window,
       listFrame.contains(convert(event.locationInWindow, from: nil)) {
      return event
    }
    dismissAfterEvent()
    return nil
  }

  private func dismissAfterEvent() {
    guard !dismissing else { return }
    dismissing = true
    // 保持 menuTracking 到本次事件分发结束，避免已有浏览监视器把同一次 Esc / 窗外点击关窗。
    DispatchQueue.main.async { [weak self] in
      guard let self, self.localMonitor != nil else { return }
      self.onDismiss?()
    }
  }
}

/// Delete, plus the category chip. The chip opens an in-window list; it does not edit the name.
struct PreviewCornerActions: View {
  var item: HistoryItemDecorator
  var onCategoryTap: () -> Void = {}
  @Environment(AppState.self) private var appState

  var body: some View {
    HStack(spacing: 6) {
      tagBadge
      actionButton(
        systemName: "trash",
        help: NSLocalizedString("row_delete_help", comment: ""),
        identifier: "lab-preview-delete",
        label: NSLocalizedString("row_delete", comment: ""),
        action: { appState.requestDelete([item]) }
      )
    }
    .fixedSize()
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private var tagBadge: some View {
    if let category = item.item.tags.first {
      Button(action: onCategoryTap) {
        WorkspaceTagBadge(tag: category)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("lab-preview-tag-badge")
      .accessibilityLabel(Text(verbatim: category))
      .help(NSLocalizedString("tag_switch_help", comment: ""))
      .anchorPreference(key: PreviewCategoryBadgeAnchor.self, value: .bounds) { anchor in
        anchor
      }
    }
  }

  private func actionButton(
    systemName: String,
    help: String,
    identifier: String,
    label: String,
    tint: NSColor = .secondaryLabelColor,
    enabled: Bool = true,
    action: @escaping () -> Void
  ) -> some View {
    ImmediateIconButton(
      systemName: systemName,
      help: help,
      identifier: identifier,
      label: label,
      tint: tint,
      enabled: enabled,
      action: action
    )
    .frame(width: 28, height: 24)
    .modifier(LabToolbarChrome(nativePassthrough: true))
  }
}

struct PreviewPinShortcutHost: NSViewRepresentable {
  var itemID: UUID
  var beginToken: Int
  var message: String?
  var error: String?

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> PinnedShortcutRecorder {
    let recorder = PinnedShortcutRecorder()
    recorder.setAccessibilityElement(true)
    recorder.setAccessibilityRole(.group)
    recorder.setAccessibilityIdentifier("lab-preview-pin-recorder")
    recorder.onBegin = { AppState.shared.beginPinRecording(itemID: $0) }
    recorder.onCancel = { AppState.shared.cancelPinRecording(itemID: $0) }
    recorder.onCommit = { AppState.shared.commitPinLetter($1, itemID: $0) }
    recorder.onPrompt = { AppState.shared.notePinRecordingPrompt($1, itemID: $0) }
    recorder.sessionActive = { AppState.shared.pinRecordingItemID == $0 }
    recorder.onSelect = { _ in }
    return recorder
  }

  func updateNSView(_ recorder: PinnedShortcutRecorder, context: Context) {
    recorder.setAccessibilityElement(true)
    recorder.setAccessibilityIdentifier("lab-preview-pin-recorder")
    let recording = AppState.shared.pinRecordingItemID == itemID
    recorder.configure(
      itemID: itemID,
      pinned: true,
      recording: recording,
      message: message,
      error: error
    )
    if context.coordinator.appliedToken != beginToken {
      context.coordinator.appliedToken = beginToken
      if beginToken > 0 {
        _ = recorder.accessibilityPerformPress()
      }
    }
  }

  final class Coordinator {
    var appliedToken = 0
  }
}

extension PreviewInlineField {
  /// Without an ideal height, SwiftUI gives this field half the canvas. The
  /// glyphs stay at the top of that slot, so the body starts a blank line below.
  /// A scrolling body must take the finite slot it is offered. Returning nil
  /// adopts the document height, and that viewport then crosses the footer.
  func sizeThatFits(
    _ proposal: ProposedViewSize,
    nsView: NSView,
    context: Context
  ) -> CGSize? {
    let width = proposal.width ?? nsView.bounds.width
    if scrolling {
      guard let height = proposal.height, height.isFinite, height > 1, width.isFinite, width > 1 else {
        return nil
      }
      return CGSize(width: width, height: height)
    }
    let resolved = (nsView as? NSTextView)?.font ?? font
    let line = max(1, ceil(resolved.ascender - resolved.descender + resolved.leading))
    let sample = (nsView as? NSTextView)?.string ?? text
    return CGSize(
      width: max(width, 1),
      height: huggedTitleHeight(sample, font: resolved, width: width, minimum: line)
    )
  }
}

private func huggedTitleHeight(_ text: String, font: NSFont, width: CGFloat, minimum: CGFloat) -> CGFloat {
  guard width > 1, !text.isEmpty else { return minimum }
  let storage = NSTextStorage(string: text)
  storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: storage.length))
  let container = NSTextContainer(containerSize: NSSize(width: width, height: .greatestFiniteMagnitude))
  container.lineFragmentPadding = 0
  let manager = NSLayoutManager()
  manager.addTextContainer(container)
  storage.addLayoutManager(manager)
  manager.ensureLayout(for: container)
  return max(minimum, ceil(manager.usedRect(for: container).height))
}
