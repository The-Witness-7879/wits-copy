import SwiftUI

struct ListHeaderView: View {
  @FocusState.Binding var searchFocused: Bool
  @Binding var searchQuery: String

  @Environment(AppState.self) private var appState
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    HStack {
      // 标签筛选不再在搜索框左边生成胶囊：点左栏的标签本身就是切换内容，
      // 当前标签由左栏那个圆圈的高亮表示，不需要第二处提示，也不该挤占搜索框。
      SearchFieldView(placeholder: "search_placeholder", query: $searchQuery)
        .focused($searchFocused)
        .onChange(of: searchFocused) {
          if searchFocused {
            appState.noteTextEntryFocused(in: nil)
          }
        }
        .frame(minWidth: ListToolbarLayout.minimumSearchWidth, maxWidth: .infinity)
        .onChange(of: scenePhase) {
          if scenePhase == .background,
             PanelClosePolicy.clearsSearchOnBackground(
               windowPinned: appState.windowPinned,
               panelPresented: appState.panelPresented
             ),
             !searchQuery.isEmpty {
            searchQuery = ""
          }
        }
        // Only reliable way to disable the cursor. allowsHitTesting() does not work
        .offset(y: appState.searchVisible ? 0 : -Popup.itemHeight)
    }
  }
}
