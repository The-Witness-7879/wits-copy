import SwiftUI

struct SlideoutContentView: View {
  @Environment(AppState.self) var appState

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      previewColumn
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      if appState.ocrItemID != nil, appState.preview.temporaryOCRWidth > 0 {
        Divider()
        OCRResultColumn()
          .frame(width: appState.preview.temporaryOCRWidth)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("lab-preview-column")
  }

  private var previewColumn: some View {
    Group {
      if appState.previewAllowed {
        previewBody
      } else {
        Color.clear
          .accessibilityIdentifier("lab-preview-inactive")
      }
    }
    .padding(.horizontal, 0)
    .padding(.bottom, WorkspaceInsets.columnBottom)
    .padding(.top, WorkspaceInsets.columnTop)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  @ViewBuilder
  private var previewBody: some View {
    if let item = appState.navigator.leadHistoryItem, !item.isRemoved {
      PreviewItemView(item: item)
        .id(item.id)
    } else if let pasteStack = appState.history.pasteStack,
      appState.navigator.pasteStackSelected {
      PasteStackPreviewView(pasteStack: pasteStack)
    } else {
      Text("preview_empty")
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("lab-preview-empty")
    }
  }
}

struct OCRResultColumn: View {
  @Environment(AppState.self) private var appState

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 4) {
        Text("RecognizeText", tableName: "PreviewItemView")
          .font(.caption)
          .lineLimit(1)
        Spacer(minLength: 4)
        ImmediateIconButton(
          systemName: "doc.on.doc",
          help: NSLocalizedString("CopyRecognizedText", tableName: "PreviewItemView", comment: ""),
          identifier: "lab-ocr-copy",
          label: NSLocalizedString("CopyRecognizedText", tableName: "PreviewItemView", comment: ""),
          action: { appState.copyOCRText() }
        )
        .frame(width: 24, height: 24)
        ImmediateIconButton(
          systemName: "xmark",
          help: NSLocalizedString("close", comment: ""),
          identifier: "lab-ocr-close",
          label: NSLocalizedString("close", comment: ""),
          action: { appState.closeOCR() }
        )
        .frame(width: 24, height: 24)
      }
      Divider()
      ScrollView {
        columnBody
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(8)
    .frame(maxHeight: .infinity, alignment: .topLeading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("lab-ocr-column")
  }

  @ViewBuilder
  private var columnBody: some View {
    switch appState.ocrPhase {
    case .idle, .recognizing:
      ProgressView()
        .accessibilityIdentifier("lab-ocr-recognizing")
    case .empty:
      Text("NoTextFound", tableName: "PreviewItemView")
        .font(.caption)
        .accessibilityIdentifier("lab-ocr-empty")
    case .failed(let message):
      Text(message)
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("lab-ocr-failed")
    case .ready:
      ForEach(appState.ocrBlocks) { block in
        Text(block.lines.joined(separator: "\n"))
          .font(.body)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.bottom, 8)
          .accessibilityIdentifier("lab-ocr-block-\(block.id)")
      }
    }
  }
}
