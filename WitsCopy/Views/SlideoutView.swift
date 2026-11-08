import SwiftUI

private struct ConditionalWidthModifier: ViewModifier {
  var width: CGFloat
  var condition: Bool

  func body(content: Content) -> some View {
    if condition {
      content
        .frame(width: width)
    } else {
      content
    }
  }
}

extension View {
  fileprivate func conditionalWidth(_ width: CGFloat, condition: Bool)
    -> some View {
    self.modifier(
      ConditionalWidthModifier(width: width, condition: condition)
    )
  }
}

struct SlideoutView<Content, Slideout>: View
where Content: View, Slideout: View {
  @Environment(AppState.self) private var appState

  let controller: SlideoutController

  @ViewBuilder var content: () -> Content
  @ViewBuilder var slideout: () -> Slideout

  var isAnimating: Bool {
    return controller.state.isAnimating
  }

  var isContentResizing: Bool {
    return controller.resizingMode == .content
  }
  var isSlideoutResizing: Bool {
    return controller.resizingMode == .slideout
  }

  @ViewBuilder
  private func resizeDivider() -> some View {
    Divider()
      .padding(.vertical)
      .padding(.horizontal, Popup.horizontalPadding)
      // macOS 26 broke gestures if no background is present.
      // The slight opcaity white background is a workaround
      .background(Color.white.opacity(0.001))
      .onHover(perform: { inside in
        // Divider hover used to set this back to true on exit. That reopened
        // background drags for the rows underneath.
        PanelWindowDrag.lock(appState.appDelegate?.panel)
        if inside {
          if #available(macOS 15.0, *) {
            NSCursor.columnResize.push()
          } else {
            NSCursor.resizeLeftRight.push()
          }
        } else {
          NSCursor.pop()
        }
      })
      .gesture(
        DragGesture()
          .onChanged({ value in
            if let window = controller.nswindow {
              let translation = -value.translation.width
              controller.applyDividerDrag(
                translation: translation,
                windowWidth: window.frame.width,
                visualSlideoutWidth: controller.slideoutResizeWidth
              )
            }
          })
          .onEnded({ _ in
            controller.commitWidths()
          })
      )
      .disabled(controller.state != .open)
      .frame(maxWidth: 0)
      .opacity(controller.state != .closed ? 1 : 0)
      .accessibilityIdentifier("lab-split-divider")
      .accessibilityValue(Text("\(Int(controller.layoutListWidth))/\(Int(controller.layoutPreviewWidth))"))
      .accessibilityAdjustableAction { direction in
        let delta: CGFloat = direction == .increment ? -24 : 24
        controller.nudgeDivider(previewDelta: delta)
      }
  }

  @ViewBuilder
  var body: some View {
    splitBody
  }

  private var splitBody: some View {
    let listSpan = controller.listSpan(
      railVisible: appState.managementRailVisible,
      railWidth: appState.effectiveRailWidth
    ).rounded()
    return HStack(spacing: 0) {
      VStack(spacing: 0) {
        content()
      }
      .environment(\.layoutDirection, .leftToRight)
      .frame(
        minWidth: controller.minimumContentWidth,
        idealWidth: !isContentResizing ? listSpan : nil,
        alignment: .leading
      )
      .frame(
        width: !isContentResizing ? listSpan : nil,
        alignment: .leading
      )
      .fixedSize(
        horizontal: isAnimating || isSlideoutResizing,
        vertical: false
      )
      .readWidth(controller, into: \.contentResizeWidth)

      if controller.state.isOpen {
        resizeDivider()

        VStack(spacing: 0) {
          slideout()
            .frame(
              minWidth: controller.minimumSlideoutWidth,
              idealWidth: !isSlideoutResizing ? controller.visualSlideoutWidth : nil,
              maxWidth: !isSlideoutResizing ? controller.visualSlideoutWidth : nil,
              alignment: .leading
            )
            .conditionalWidth(
              controller.visualSlideoutWidth,
              condition: isAnimating
            )
            .transition(.identity)
        }
        .environment(\.layoutDirection, .leftToRight)
        .fixedSize(
          horizontal: isAnimating || isContentResizing,
          vertical: false
        )
        .readWidth(controller, into: \.slideoutResizeWidth)
      }
    }
    .environment(\.layoutDirection, .leftToRight)
  }
}
