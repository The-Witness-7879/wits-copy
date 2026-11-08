import Foundation
import AppKit

@Observable
class PasteStack: Identifiable, Hashable {
  private static var listener: Any?

  static func initializeIfNeeded() {
    guard listener == nil else { return }
    // 启动时不请求辅助功能权限，避免每次开机都打断；
    // 用户真正粘贴失败时再由面板询问并跳转设置。

    var pasteDown: Bool = false
    listener = NSEvent.addGlobalMonitorForEvents(matching: [.keyUp, .keyDown]) { event in
      switch event.type {
      case .keyDown:
        if event.keyCode == KeyChord.pasteKey.QWERTYKeyCode
           && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command] {
          pasteDown = true
        }
      case .keyUp:
        if pasteDown && event.keyCode == KeyChord.pasteKey.QWERTYKeyCode {
          pasteDown = false
          AppState.shared.history.handlePasteStack()
        }
      default:
        break
      }
    }
  }

  var id: UUID = UUID()
  var items: [HistoryItemDecorator] = []
  var modifierFlags: NSEvent.ModifierFlags

  init(items: [HistoryItemDecorator], modifierFlags: NSEvent.ModifierFlags) {
    self.items = items
    self.modifierFlags = modifierFlags
  }

  static func == (lhs: PasteStack, rhs: PasteStack) -> Bool {
    return lhs.id == rhs.id
      && lhs.items == rhs.items
      && lhs.modifierFlags.rawValue == rhs.modifierFlags.rawValue
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
    hasher.combine(items)
    hasher.combine(modifierFlags.rawValue)
  }

}
