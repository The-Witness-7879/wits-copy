import SwiftUI

@main
struct WitsCopyApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  // SwiftUI apps need a scene; a menu bar extra that is never inserted
  // keeps this a status-item app without a visible SwiftUI window.
  @State private var hiddenMenu: Bool = false

  var body: some Scene {
    MenuBarExtra("", isInserted: $hiddenMenu) {
      EmptyView()
    }
  }
}
