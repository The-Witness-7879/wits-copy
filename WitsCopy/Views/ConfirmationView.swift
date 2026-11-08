import SwiftUI

struct ConfirmationView<Content: View>: View {
  @Bindable var item: FooterItem
  @ViewBuilder let content: () -> Content

  var body: some View {
    if item.confirmation != nil, item.suppressConfirmation != nil {
      content()
        .onTapGesture {
          AppState.shared.presentFooterConfirmation(item)
        }
    } else {
      content()
        .onTapGesture {
          item.action()
        }
    }
  }
}
