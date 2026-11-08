import SwiftUI

struct PinsView: View {

  var items: [HistoryItemDecorator]

  var body: some View {
    MultipleSelectionListView(items: items) { previous, item, next, index in
      HistoryItemView(item: item, previous: previous, next: next, index: index)
    }
    // Align with the scrolling rows, whose scroll view extends 3pt further out.
    .padding(.trailing, WorkspaceInsets.listTrailing - WorkspaceInsets.scrollerFlushOffset)
  }
}
