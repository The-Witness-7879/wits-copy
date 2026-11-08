import SwiftData
import SwiftUI

struct ContentView: View {
  @State private var appState = AppState.shared
  @State private var modifierFlags = ModifierFlags()
  @State private var scenePhase: ScenePhase = .background

  @FocusState private var searchFocused: Bool

  var body: some View {
    ZStack {
      if #available(macOS 26.0, *) {
        GlassEffectView()
      } else {
        VisualEffectView()
      }

      KeyHandlingView(searchQuery: $appState.history.searchQuery, searchFocused: $searchFocused) {
        // NSPanel.close keeps its hosting view alive. Remove the workspace rather
        // than letting hidden rows retain SwiftData faults or decode thumbnails.
        if appState.panelPresented {
          workspaceContent
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .task {
        try? await appState.history.load()
      }
    }
    .animation(.easeInOut(duration: 0.2), value: appState.searchVisible)
    .environment(appState)
    .environment(modifierFlags)
    .environment(\.scenePhase, scenePhase)
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
      if let window = $0.object as? NSWindow,
         let bundleIdentifier = Bundle.main.bundleIdentifier,
         window.identifier == NSUserInterfaceItemIdentifier(bundleIdentifier) {
        scenePhase = .active
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) {
      if let window = $0.object as? NSWindow,
         let bundleIdentifier = Bundle.main.bundleIdentifier,
         window.identifier == NSUserInterfaceItemIdentifier(bundleIdentifier),
         PanelClosePolicy.treatsResignAsBackground(
           windowPinned: appState.windowPinned,
           panelPresented: appState.panelPresented
         ) {
        scenePhase = .background
      }
    }
  }

  private var workspaceContent: some View {
    // Leading, not the default center. A short content block in a wider window
    // must not float inward and leave a blank strip before the sidebar.
    VStack(alignment: .leading, spacing: 0) {
      // Search and toolbar share the traffic-light row. The rail sits below.
      HeaderView(
        controller: appState.preview,
        searchFocused: $searchFocused
      )
      .frame(
        width: ListToolbarLayout.constrainedWidth(
          // 读 AppState 的可观察宽度，不要读 preview 里那份从 Defaults 现算的：
          // 后者变化不会让这一行重排，切左栏时整排按钮会停在旧位置。
          // 顶栏右缘钉住：窗口向左长多少，左侧留白就长多少，
          // 搜索框和按钮的屏幕位置都不变。
          listWidth: appState.preview.layoutListWidth + appState.railExtraWidth,
          previewColumnVisible: appState.preview.state.isOpen
        ),
        alignment: .leading
      )
      .frame(maxWidth: .infinity, alignment: .leading)
      .transaction { $0.animation = nil }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("lab-list-toolbar")

      SlideoutView(controller: appState.preview) {
        HStack(alignment: .top, spacing: 0) {
          WorkspaceManagementRail()

          VStack(alignment: .leading, spacing: 0) {
            HistoryListView(
              searchQuery: $appState.history.searchQuery,
              searchFocused: $searchFocused
            )
            // 左侧只留 2pt：左栏那 4pt 底色留白已经够了，再叠 5pt
            // 会在两栏之间形成一条多余的竖带。
            .padding(.leading, 2)
            .padding(.trailing, Popup.horizontalPadding)
          }
        }
        .onAppear {
          let resolved = WorkspaceSection.resolvedForOpen(appState.workspaceSection)
          if appState.workspaceSection != resolved {
            appState.workspaceSection = resolved
          }
          searchFocused = false
        }
        .onMouseMove {
          appState.navigator.isKeyboardNavigating = false
        }
      } slideout: {
        if appState.previewAllowed {
          SlideoutContentView()
        } else {
          Color.clear
            .accessibilityIdentifier("lab-preview-withheld")
        }
      }
      .frame(minHeight: 0)
      .layoutPriority(1)

      // Clear-all and quit dialogs stay mounted. The row itself takes no height.
      FooterView(footer: appState.footer)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
  }
}

#Preview {
  ContentView()
    .environment(\.locale, .init(identifier: "en"))
    .modelContainer(Storage.shared.container)
}
