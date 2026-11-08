import Foundation

/// 指针与拖拽的命中语义。
/// 区分单击、双击和拖拽起手，供行视图与标签栏共用。

enum WorkspacePointerAction: Equatable, Sendable {
  /// Navigator selection only. Does not copy or close.
  case select
  /// Explicit commit. Reuses History.select, including keyboard copy.
  case commit
}


enum WorkspacePointer {
  /// Select on a single click. A double-click pastes even if the row was not
  /// already selected. A click on a different row stays a select when the
  /// system reports it as one click.
  static func bodyAction(clickCount: Int) -> WorkspacePointerAction? {
    guard clickCount > 0 else { return nil }
    return clickCount >= 2 ? .commit : .select
  }

  /// Hover may change appearance. It must not select, preview, or copy.
  static func hoverAction() -> WorkspacePointerAction? { nil }
}


enum ShortcutSlotPointer {
  enum Result: Equatable {
    case select
    case selectAndRecord
  }

  /// Any click on the lane selects the row. Only a pinned double-click records.
  /// No click count copies.
  static func result(pinned: Bool, clickCount: Int) -> Result {
    if pinned && clickCount >= 2 { return .selectAndRecord }
    return .select
  }
}


enum RowPointerDrag {
  static let threshold: Double = 4

  static func exceeded(dx: Double, dy: Double, threshold: Double = threshold) -> Bool {
    (dx * dx + dy * dy) >= threshold * threshold
  }
}
