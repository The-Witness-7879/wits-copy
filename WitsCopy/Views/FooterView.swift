import SwiftUI

/// Confirmation hosts only. The options menu lives on the rail and this row takes no height.
struct FooterView: View {
  @Bindable var footer: Footer

  @Environment(AppState.self) private var appState

  var body: some View {
    ZStack {
      ForEach(footer.items) { item in
        ConfirmationView(item: item) {
          Color.clear.frame(width: 1, height: 1)
        }
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
      }
    }
    .frame(width: 0, height: 0)
    .onAppear {
      appState.popup.footerHeight = 0
    }
    .accessibilityIdentifier("lab-confirmation-host")
  }
}
