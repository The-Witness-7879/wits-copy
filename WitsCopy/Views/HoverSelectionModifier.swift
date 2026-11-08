import SwiftUI

private struct HoverSelectionModifier: ViewModifier {
  @State private var hovered = false

  func body(content: Content) -> some View {
    content
      .background(hovered ? Color.primary.opacity(0.05) : Color.clear)
      .onHover { inside in
        hovered = inside
        _ = WorkspacePointer.hoverAction()
      }
  }
}

extension View {
  func hoverSelectionId(_ id: UUID) -> some View {
    _ = id
    return modifier(HoverSelectionModifier())
  }
}
