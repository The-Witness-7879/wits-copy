import Defaults
import SwiftUI

struct HistoryListView: View {
  @Binding var searchQuery: String
  @FocusState.Binding var searchFocused: Bool

  @Environment(AppState.self) private var appState
  @Environment(ModifierFlags.self) private var modifierFlags
  @Environment(\.scenePhase) private var scenePhase
  @Default(.pinTo) private var pinTo

  private var pinnedItems: [HistoryItemDecorator] {
    appState.history.pinnedItems.filter(\.isVisible)
  }
  private var unpinnedItems: [HistoryItemDecorator] {
    appState.history.unpinnedItems.filter(\.isVisible)
  }

  private var pinsVisible: Bool {
    return !pinnedItems.isEmpty
  }

  /// 切换栏目、分类或类型时，可见条目集合是整套换掉的。
  /// 给滚动视图一个随这三者变化的身份，旧的滚动偏移和懒加载布局随之丢弃，
  /// 避免从长列表直接切到短分类时，行被排到可视区之外（看上去就是「条目全不见了」）。
  private var listIdentity: String {
    "\(appState.workspaceSection.rawValue)|\(appState.history.tagFilter ?? "")|\(String(describing: appState.history.typeFilter))"
  }

  private var pasteStackVisible: Bool {
    if let stack = appState.history.pasteStack,
       !stack.items.isEmpty {
      return true
    }
    return false
  }

  private var topPadding: CGFloat {
    return WorkspaceInsets.columnTop
  }

  private var bottomPadding: CGFloat {
    return WorkspaceInsets.listBottom
  }

  private func topSeparator() -> some View {
    Divider()
      .padding(.horizontal, Popup.horizontalSeparatorPadding)
      .padding(.top, Popup.verticalSeparatorPadding)
  }

  @ViewBuilder
  private func bottomSeparator() -> some View {
    Divider()
      .padding(.horizontal, Popup.horizontalSeparatorPadding)
      .padding(.bottom, Popup.verticalSeparatorPadding)
  }

  @ViewBuilder
  private func separator() -> some View {
    Divider()
      .padding(.horizontal, Popup.horizontalSeparatorPadding)
      .padding(.vertical, Popup.verticalSeparatorPadding)
  }

  var body: some View {
    let topPinsVisible = pinTo == .top && pinsVisible
    let bottomPinsVisible = pinTo == .bottom && pinsVisible
    let historyEmpty = unpinnedItems.isEmpty
    let topSeparatorVisible = !historyEmpty && (topPinsVisible || pasteStackVisible)
    let bottomSeparatorVisible = !historyEmpty && bottomPinsVisible
    let scrollTopPadding = topSeparatorVisible ? Popup.verticalSeparatorPadding : topPadding
    let scrollBottomPadding = bottomPadding

    VStack(spacing: 0) {
      if let stack = appState.history.pasteStack,
         !stack.items.isEmpty {
        PasteStackView(stack: stack)

        if topPinsVisible {
          separator()
        }
      }

      if topPinsVisible {
        PinsView(items: pinnedItems)
      }

      if topSeparatorVisible {
        topSeparator()
      }
    }
    .padding(.top, topSeparatorVisible ? topPadding : 0)
    .padding(.leading, WorkspaceInsets.listOuter)
    .readHeight(appState, into: \.popup.extraTopHeight)

    ScrollView {
        ScrollViewReader { proxy in
          MultipleSelectionListView(items: unpinnedItems) { previous, item, next, index in
            HistoryItemView(item: item, previous: previous, next: next, index: index)
          }
          .padding(.top, scrollTopPadding)
          .padding(.bottom, scrollBottomPadding)
          .padding(.trailing, WorkspaceInsets.listTrailing)
          .task(id: appState.navigator.scrollTarget) {
            guard appState.navigator.scrollTarget != nil else { return }

            try? await Task.sleep(for: .milliseconds(10))
            guard !Task.isCancelled else { return }

            if let selection = appState.navigator.scrollTarget {
              proxy.scrollTo(selection)
              appState.navigator.scrollTarget = nil
            }
          }
          .onChange(of: scenePhase) {
            if scenePhase == .active {
              appState.navigator.isKeyboardNavigating = true
              appState.selectOnPanelOpen()
              appState.preview.enableAutoOpen()
              appState.preview.resetAutoOpenSuppression()
              appState.preview.startAutoOpen()
            } else {
              modifierFlags.flags = []
              appState.navigator.isKeyboardNavigating = true
              appState.preview.cancelAutoOpen()
            }
          }
          // Calculate the total height inside a scroll view.
          .background {
            GeometryReader { geo in
              Color.clear
                .task(id: appState.popup.needsResize) {
                  try? await Task.sleep(for: .milliseconds(10))
                  guard !Task.isCancelled else { return }

                  if appState.popup.needsResize {
                    appState.popup.resize(height: geo.size.height)
                  }
                }
            }
          }
        }
        .contentMargins(.leading, 10, for: .scrollIndicators)
        .contentMargins(.top, scrollTopPadding, for: .scrollIndicators)
        .contentMargins(.bottom, scrollBottomPadding, for: .scrollIndicators)
      }
      .accessibilityIdentifier("history-scroll-view")
      .id(listIdentity)
      .padding(.leading, WorkspaceInsets.listOuter)
      .padding(.trailing, -WorkspaceInsets.scrollerFlushOffset)

    VStack(spacing: 0) {
      if bottomSeparatorVisible {
        bottomSeparator()
      }

      if bottomPinsVisible {
        PinsView(items: pinnedItems)
      }
    }
    .padding(.bottom, bottomPinsVisible ? bottomPadding : 0)
    .padding(.leading, WorkspaceInsets.listOuter)
    .padding(.bottom, WorkspaceInsets.listOuter)
    .readHeight(appState, into: \.popup.extraBottomHeight)
  }
}
