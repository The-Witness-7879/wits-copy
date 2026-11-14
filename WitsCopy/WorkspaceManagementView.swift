import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceManagementRail: View {
  @Environment(AppState.self) private var appState
  @State private var allDropTargeted = false
  /// 当前被拖拽悬停的栏目。「全部」和「常用」都要能高亮。
  @State private var targetedSection: WorkspaceSection?
  @Default(.workspaceTagDirectory) private var storedTags
  @State private var createController = WorkspaceTagCreateController()
  @State private var scrollTag: String?
  @State private var directoryError: String?
  /// 「新建标签」行的弹窗锚点。SwiftUI 行里塞一个透明 NSView 用来定位。
  @State private var plusAnchor: NSView?
  @State private var allAnchor: NSView?
  @State private var itemCreator = WorkspaceItemCreateController()
  @State private var draggingTag: String?
  @State private var dragTranslation: CGFloat = 0
  @State private var reorderShifts: [String: CGFloat] = [:]

  private var railTags: [String] {
    WorkspaceTagDirectory.ordered(stored: storedTags, itemTags: appState.history.knownTags)
  }

  var body: some View {
    let expanded = appState.managementRailVisible
    let tags = railTags
    let _ = appState.history.items.count
    VStack(alignment: .leading, spacing: 0) {
      ScrollViewReader { proxy in
        // Overlay scroller in the rail covers the hit target. Wheel and trackpad still scroll.
        ScrollView(.vertical, showsIndicators: false) {
          VStack(alignment: .leading, spacing: WorkspaceRailFlow.spacing) {
            ForEach(WorkspaceSection.primaryRail) { section in
              railButton(section, expanded: expanded)
                .background {
                  if section == .all {
                    WorkspaceRailAnchor { allAnchor = $0 }
                  }
                }
                .overlay {
                  if section == .all {
                    RailContextMenuHost(items: allContextItems)
                      .frame(maxWidth: .infinity, maxHeight: .infinity)
                  }
                }
            }
            ForEach(tags, id: \.self) { tag in
              WorkspaceRailTagButton(tag: tag, expanded: expanded)
              .id(tag)
              .offset(y: draggingTag == tag ? dragTranslation : (reorderShifts[tag] ?? 0))
              .animation(draggingTag == tag ? .none : .smooth(duration: 0.22), value: reorderShifts)
              .scaleEffect(draggingTag == tag ? 1.02 : 1)
              .shadow(color: draggingTag == tag ? .black.opacity(0.16) : .clear, radius: 6, y: 2)
              .zIndex(draggingTag == tag ? 1 : 0)
              .highPriorityGesture(reorderGesture(for: tag))
            }
            WorkspaceRailRow(
              systemName: "plus",
              title: WorkspaceTagCopy.text("tag_directory_add"),
              expanded: expanded,
              selected: false,
              help: WorkspaceTagCopy.text("tag_directory_add_help"),
              identifier: "lab-rail-add-tag",
              onTap: {
                guard let view = plusAnchor else { return }
                createController.present(
                  from: view,
                  onCommit: commitNewTag,
                  onCancel: cancelNewTag
                )
              }
            )
            .background(WorkspaceRailAnchor { plusAnchor = $0 })
            .iconHelp(WorkspaceTagCopy.text("tag_directory_add_help"))
            .accessibilityIdentifier("lab-rail-add-tag")
            .accessibilityLabel(Text(WorkspaceTagCopy.text("tag_directory_add")))
          }
          .padding(.vertical, WorkspaceRailFlow.verticalPadding)
          // 整行（选中底色）从距窗体 8pt 起，与关闭按钮左缘对齐；
          // 右侧不留白，条目列自带的 8pt 就是对面那段间距。
          .padding(.leading, WorkspaceRailMetrics.railLeading)
          .padding(.trailing, WorkspaceRailMetrics.railTrailing)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onChange(of: scrollTag) {
          guard let tag = scrollTag else { return }
          proxy.scrollTo(tag, anchor: .bottom)
          scrollTag = nil
        }
      }
      // 设置固定在左栏底部，不随标签滚动；底边与条目列的底部留白一致。
      settingsRow(expanded: expanded)
        .padding(.leading, WorkspaceRailMetrics.railLeading)
        .padding(.trailing, WorkspaceRailMetrics.railTrailing)
        .padding(.top, WorkspaceRailFlow.spacing)
        .padding(.bottom, WorkspaceInsets.columnBottom)
    }
    .frame(width: WorkspaceChrome.railWidth(expanded: expanded))
    .frame(maxHeight: .infinity, alignment: .top)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("lab-management-rail")
    .onAppear(perform: syncDirectory)
    .onChange(of: tags) { syncDirectory() }
    .onDisappear { createController.dismiss(cancelled: true) }
    .alert(
      directoryError ?? "",
      isPresented: Binding(
        get: { directoryError != nil },
        set: { if !$0 { directoryError = nil } }
      )
    ) {
      Button("clear_alert_confirm", role: .cancel) {}
        .help("directory_error_dismiss_help")
    }
  }

  private var reorderPitch: CGFloat { WorkspaceRailMetrics.hit + WorkspaceRailFlow.spacing }

  private func reorderGesture(for tag: String) -> some Gesture {
    DragGesture(minimumDistance: 8)
      .onChanged { value in
        draggingTag = tag
        dragTranslation = value.translation.height
        let slot = WorkspaceTagReorder.slot(
          moving: tag,
          translation: value.translation.height,
          order: railTags,
          pitch: reorderPitch
        )
        reorderShifts = WorkspaceTagReorder.shifts(
          moving: tag,
          slot: slot,
          order: railTags,
          pitch: reorderPitch
        )
      }
      .onEnded { value in
        let slot = WorkspaceTagReorder.slot(
          moving: tag,
          translation: value.translation.height,
          order: railTags,
          pitch: reorderPitch
        )
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
          if let slot,
             let next = WorkspaceTagDirectory.placing(
               tag,
               before: slot.before,
               atEnd: slot.atEnd,
               stored: storedTags,
               itemTags: appState.history.knownTags
             ) {
            storedTags = next
          }
          draggingTag = nil
          dragTranslation = 0
          reorderShifts = [:]
        }
      }
  }

  private var allContextItems: [RailContextItem] {
    [RailContextItem(titleKey: "create_snippet") { presentItemCreate(tag: nil) }]
  }

  private func presentItemCreate(tag: String?) {
    guard let allAnchor else { return }
    itemCreator.present(from: allAnchor) { title, body in
      appState.history.createTextItem(title: title, text: body, tag: tag) == nil
        ? NSLocalizedString("save_failed", comment: "")
        : nil
    }
  }

  private func commitNewTag(_ draft: String) -> String? {
    switch WorkspaceTagDirectory.resolveCreate(draft, in: railTags) {
    case .selectExisting(let name):
      // Typing a name that already exists is not an error to fix here:
      // confirm it and the user lands in that category.
      WorkspaceRailPolicy.selectTag(name, in: appState)
      directoryError = nil
      return nil
    case .invalid:
      return WorkspaceTagDirectoryError.invalidName.message
    case .create:
      break
    }
    switch WorkspaceTagDirectoryActions.create(draft: draft, itemTags: appState.history.knownTags) {
    case .success(let name):
      scrollTag = name
      directoryError = nil
      return nil
    case .failure(let error):
      return error.message
    }
  }

  private func cancelNewTag() {
    _ = WorkspaceTagDirectoryActions.apply(
      .cancel,
      stored: storedTags,
      itemTags: appState.history.knownTags,
      save: { _ in false }
    )
  }

  private func syncDirectory() {
    switch WorkspaceTagDirectoryActions.sync(itemTags: appState.history.knownTags) {
    case .success:
      break
    case .failure(let error):
      if directoryError == nil {
        directoryError = error.message
      }
    }
  }

  private func settingsRow(expanded: Bool) -> some View {
    let title = NSLocalizedString("rail_settings", comment: "")
    let help = NSLocalizedString("rail_settings_help", comment: "")
    return WorkspaceRailRow(
      systemName: "gearshape",
      title: title,
      expanded: expanded,
      selected: false,
      help: help,
      identifier: "lab-rail-settings",
      onTap: { appState.openPreferences() }
    )
    .iconHelp(help)
    .accessibilityIdentifier("lab-rail-settings")
    .accessibilityLabel(Text(title))
  }

  private func railButton(_ section: WorkspaceSection, expanded: Bool) -> some View {
    let selected: Bool
    switch section {
    case .all:
      selected = WorkspaceRailPolicy.isAllSelected(
        section: appState.workspaceSection,
        tagFilter: appState.history.tagFilter
      )
    case .pins:
      selected = WorkspaceRailPolicy.isPinsSelected(
        section: appState.workspaceSection,
        tagFilter: appState.history.tagFilter
      )
    default:
      selected = appState.workspaceSection == section
    }
    let help = NSLocalizedString(railHelpKey(section), comment: "")
    let title = NSLocalizedString(section.titleKey, comment: "")
    let activate = {
      if section == .all {
        WorkspaceRailPolicy.selectAll(appState)
      } else {
        appState.workspaceSection = section
        // 切到「常用」这类聚合视图时必须清掉分类筛选，
        // 否则左栏会同时亮起一个分类和「常用」，两个都不起作用。
        if section != .tags {
          appState.history.tagFilter = nil
        }
      }
    }
    return WorkspaceRailRow(
      systemName: section.symbolName,
      title: title,
      expanded: expanded,
      selected: selected,
      dropTargeted: targetedSection == section,
      help: help,
      identifier: "lab-nav-\(section.rawValue)",
      onTap: activate
    )
    // 丢到「全部」= 从当前分类里拿出来。
    .onDrop(
      of: [UTType(exportedAs: WorkspaceItemDrag.typeIdentifier)],
      isTargeted: Binding(
        get: { targetedSection == section },
        set: { targeted in
          if targeted {
            targetedSection = section
          } else if targetedSection == section {
            targetedSection = nil
          }
        }
      )
    ) { providers in
      guard section == .all, let provider = providers.first else { return false }
      _ = provider.loadDataRepresentation(
        forTypeIdentifier: WorkspaceItemDrag.typeIdentifier
      ) { data, _ in
        guard let data,
              let raw = String(data: data, encoding: .utf8),
              let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }
        DispatchQueue.main.async {
          clearTagsForDroppedItem(id)
        }
      }
      return true
    }
    .overlay {
      if allDropTargeted {
        RoundedRectangle(cornerRadius: WorkspaceRailMetrics.cornerRadius, style: .continuous)
          .strokeBorder(Color.accentColor, lineWidth: 2)
          .allowsHitTesting(false)
      }
    }
    .iconHelp(help)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  /// 丢到「全部」：把这条（多选时整组）的分类清掉。
  private func clearTagsForDroppedItem(_ id: UUID) {
    _ = appState.applyCategoryDrop(itemID: id, name: nil)
  }
}

extension WorkspaceSection {
  var symbolName: String {
    switch self {
    case .all: return "tray.full"
    case .tags: return "tag"
    case .pins: return WorkspaceSymbols.pinManagement
    case .ignore: return "nosign"
    }
  }

  var titleKey: String {
    switch self {
    case .all: return "nav_all"
    case .tags: return "nav_tags"
    case .pins: return "nav_pins"
    case .ignore: return "nav_ignore"
    }
  }

}

private func railHelpKey(_ section: WorkspaceSection) -> String {
  switch section {
  case .all: return "nav_all_help"
  case .tags: return "nav_tags_help"
  case .pins: return WorkspaceHelp.pinManagement(selected: false)
  case .ignore: return "nav_ignore_help"
  }
}

private enum RailTagEdit: Equatable {
  case rename
  case merge
  case appearance
}

struct WorkspaceRailTagButton: View {
  var tag: String
  var expanded: Bool = false
  var insertionTargeted: Bool = false
  @Environment(AppState.self) private var appState
  @State private var edit: RailTagEdit?
  @State private var confirmDelete = false
  @State private var editError: String?
  @State private var dropHighlighted = false
  @State private var createAnchor: NSView?
  @State private var itemCreator = WorkspaceItemCreateController()

  private var selected: Bool {
    WorkspaceRailPolicy.isTagSelected(tag, tagFilter: appState.history.tagFilter)
  }

  var body: some View {
    WorkspaceRailRow(
      tag: tag,
      title: tag,
      expanded: expanded,
      selected: selected,
      dropTargeted: dropHighlighted || insertionTargeted,
      help: tag,
      identifier: WorkspaceRailPolicy.accessibilityIdentifier(for: tag),
      onTap: { WorkspaceRailPolicy.selectTag(tag, in: appState) },
      onIconTap: { present(.appearance) }
    )
    .background(WorkspaceRailAnchor { createAnchor = $0 })
    .onDrop(
      of: [UTType(exportedAs: WorkspaceItemDrag.typeIdentifier)],
      isTargeted: $dropHighlighted
    ) { providers in
      guard let provider = providers.first else { return false }
      _ = provider.loadDataRepresentation(
        forTypeIdentifier: WorkspaceItemDrag.typeIdentifier
      ) { data, _ in
        guard let data,
              let raw = String(data: data, encoding: .utf8),
              let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }
        DispatchQueue.main.async { _ = assignDroppedItem(id) }
      }
      return true
    }
    .overlay {
      RailContextMenuHost(items: tagContextItems)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .iconHelp(tag)
    .accessibilityValue(WorkspaceRailFeedback.accessibilityValue(selected: selected, dropTarget: dropHighlighted))
    .popover(isPresented: editPresented, arrowEdge: .trailing) {
      if edit == .appearance {
        WorkspaceTagAppearancePopover(tag: tag)
      } else {
        RailTagNamePopover(tag: tag, merging: edit == .merge)
          .environment(appState)
      }
    }
    .confirmationDialog("tag_delete_name", isPresented: $confirmDelete, titleVisibility: .visible) {
      Button("tag_delete_name", role: .destructive) {
        deleteTag()
      }
      .help("tag_delete_confirm_help")
      Button("clear_alert_cancel", role: .cancel) {}
        .help("tag_delete_cancel_help")
    } message: {
      Text(verbatim: tag) + Text("\n") + Text("tag_delete_keeps_items")
    }
    .alert(
      editError ?? "",
      isPresented: Binding(
        get: { editError != nil && edit == nil },
        set: { if !$0 { editError = nil } }
      )
    ) {
      Button("clear_alert_confirm", role: .cancel) {}
        .help("tag_edit_error_dismiss_help")
    }
  }

  private var editPresented: Binding<Bool> {
    Binding(
      get: { edit != nil },
      set: { if !$0 { edit = nil } }
    )
  }

  private var tagContextItems: [RailContextItem] {
    [
      RailContextItem(titleKey: "create_snippet", action: presentItemCreate),
      RailContextItem(titleKey: "tag_rename_menu", separatorBefore: true) { present(.rename) },
      RailContextItem(titleKey: "tag_merge_menu") { present(.merge) },
      RailContextItem(titleKey: "tag_delete_menu", separatorBefore: true, action: presentDelete)
    ]
  }

  private func presentItemCreate() {
    guard let createAnchor else { return }
    itemCreator.present(from: createAnchor) { title, body in
      appState.history.createTextItem(title: title, text: body, tag: tag) == nil
        ? NSLocalizedString("save_failed", comment: "")
        : nil
    }
  }

  private func present(_ next: RailTagEdit) {
    DispatchQueue.main.async {
      editError = nil
      edit = next
    }
  }

  private func presentDelete() {
    DispatchQueue.main.async {
      confirmDelete = true
    }
  }

  private func deleteTag() {
    switch WorkspaceTagDirectoryActions.delete(
      named: tag,
      itemTags: appState.history.knownTags,
      deleteHistory: { WorkspaceRailPolicy.delete(tag, in: appState) }
    ) {
    case .success:
      editError = nil
    case .failure(.historyFailed):
      editError = WorkspaceRailPolicy.editFailureMessage(storageError: appState.storageError)
    case .failure(let error):
      editError = error.message
    }
  }

  private func assignDroppedItem(_ itemID: UUID) -> Bool {
    let live = appState.history.all.map { WorkspaceItemDropLiveItem(id: $0.id, removed: $0.isRemoved) }
    let result = WorkspaceItemDrop.set(token: itemID, tag: tag, live: live) { id, name in
      return appState.applyCategoryDrop(itemID: id, name: name)
    }
    switch result {
    case .success:
      editError = nil
      return true
    case .failure(let error):
      editError = appState.storageError ?? error.message
      return false
    }
  }
}

struct RailTagNamePopover: View {
  var tag: String
  var merging: Bool
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @Default(.workspaceTagDirectory) private var storedTags
  @State private var draft = ""
  @State private var editError: String?
  @State private var holdingPanelKeys = false

  private var mergeTargets: [String] {
    WorkspaceTagDirectory.ordered(stored: storedTags, itemTags: appState.history.knownTags)
      .filter { $0.caseInsensitiveCompare(tag) != .orderedSame }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: WorkspaceTagCreatePlacement.titleToField) {
      Text(merging ? String(format: NSLocalizedString("tag_merge_heading", comment: ""), tag) : NSLocalizedString("tag_rename", comment: ""))
        .font(.system(size: 13, weight: .semibold))
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: WorkspaceTagCreatePlacement.titleHeight, alignment: .leading)
      if merging {
        mergeList
      } else {
        renameField
      }
      if let editError {
        Text(editError)
          .font(.system(size: 11))
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("lab-rail-tag-error")
      }
    }
    .padding(WorkspaceTagCreatePlacement.contentInset)
    .frame(width: WorkspaceTagCreatePlacement.formWidth)
    .onAppear {
      draft = tag
      editError = nil
      if !holdingPanelKeys {
        holdingPanelKeys = true
        appState.beginDirectoryForm()
      }
    }
    .onDisappear {
      if holdingPanelKeys {
        holdingPanelKeys = false
        appState.endDirectoryForm()
      }
    }
  }

  private var renameField: some View {
    VStack(alignment: .leading, spacing: WorkspaceTagCreatePlacement.fieldToButtons) {
      TagDraftField(
        text: $draft, onSubmit: commitRename, identifier: "lab-rail-rename-field",
        placeholderKey: "tag_rename", onCancel: { dismiss() }
      )
      .frame(height: GlassField.height)
      FormActions(
        primaryTitleKey: "edit_save", primaryHelpKey: "tag_rename_help",
        cancelIdentifier: "lab-rail-rename-cancel", primaryIdentifier: "lab-rail-rename-confirm",
        primaryEnabled: HistoryItem.normalizedTag(draft) != nil,
        onCancel: { dismiss() }, onConfirm: commitRename
      )
    }
  }

  private var mergeList: some View {
    Group {
      if mergeTargets.isEmpty {
        Text("tag_merge_empty")
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("lab-rail-merge-empty")
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(mergeTargets, id: \.self) { name in
              MergeTargetRow(name: name) { merge(into: name) }
            }
          }
        }
        .frame(maxHeight: 180)
      }
    }
  }

  private func commitRename() {
    guard HistoryItem.normalizedTag(draft) != nil else {
      editError = WorkspaceTagDirectoryError.invalidName.message
      return
    }
    switch WorkspaceTagDirectoryActions.rename(
      from: tag,
      to: draft,
      merging: mergeTargets.contains { $0.caseInsensitiveCompare(draft.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame },
      itemTagsAfter: { appState.history.knownTags },
      renameHistory: { WorkspaceRailPolicy.rename(tag, to: draft, in: appState) },
      rollbackHistory: { restored in
        guard let current = HistoryItem.normalizedTag(draft) else { return false }
        return WorkspaceRailPolicy.rename(current, to: restored, in: appState)
      }
    ) {
    case .success:
      editError = nil
      dismiss()
    case .failure(.historyFailed):
      editError = WorkspaceRailPolicy.editFailureMessage(storageError: appState.storageError)
    case .failure(let error):
      editError = error.message
    }
  }

  private func merge(into target: String) {
    switch WorkspaceTagDirectoryActions.rename(
      from: tag,
      to: target,
      merging: true,
      itemTagsAfter: { appState.history.knownTags },
      renameHistory: { WorkspaceRailPolicy.merge(tag, into: target, in: appState) },
      rollbackHistory: { restored in
        WorkspaceRailPolicy.rename(target, to: restored, in: appState)
      }
    ) {
    case .success:
      editError = nil
      dismiss()
    case .failure(.historyFailed):
      editError = WorkspaceRailPolicy.editFailureMessage(storageError: appState.storageError)
    case .failure(let error):
      editError = error.message
    }
  }
}

/// 合并目标行。plain 按钮没有悬停底色，单独记 hover。
private struct MergeTargetRow: View {
  var name: String
  var action: () -> Void
  @State private var hovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        WorkspaceTagGlyph(tag: name, size: 12)
        Text(name)
          .foregroundStyle(Color.primary)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(hovered ? Color.primary.opacity(0.1) : Color.clear)
    )
    .onHover { hovered = $0 }
    .iconHelp(NSLocalizedString("tag_merge_help", comment: ""))
    .accessibilityIdentifier("lab-rail-merge-confirm")
    .accessibilityLabel(Text(name))
  }
}

struct WorkspaceOptionsButton: View {
  var arrowEdge: Edge = .trailing
  var hit = CGSize(width: PanelSplit.railHitSize, height: PanelSplit.railHitSize)
  @Environment(AppState.self) private var appState
  @State private var createAnchor: NSView?
  @State private var itemCreator = WorkspaceItemCreateController()

  var body: some View {
    ImmediateMenuButton(
      systemName: "ellipsis.circle",
      help: NSLocalizedString("options_help", comment: ""),
      identifier: "lab-options-button",
      label: NSLocalizedString("options", comment: ""),
      entries: optionEntries
    )
    .frame(width: hit.width, height: hit.height)
    .background(WorkspaceRailAnchor { createAnchor = $0 })
    .accessibilityIdentifier("lab-options-button")
  }

  private var optionEntries: [ImmediateMenuEntry] {
    var entries: [ImmediateMenuEntry] = []
    // 设置已固定在左栏底部，菜单里不再重复。
    for item in appState.footer.items where item.title != "clear" && item.title != "preferences" {
      entries.append(ImmediateMenuEntry(
        title: NSLocalizedString(item.title, comment: ""),
        identifier: "lab-option-\(item.title)",
        action: { appState.runFooterItem(item) }
      ))
    }
    entries.append(ImmediateMenuEntry(separator: true))
    entries.append(ImmediateMenuEntry(
      title: NSLocalizedString("create_snippet", comment: ""),
      identifier: "lab-option-create-snippet",
      action: { presentItemCreate() }
    ))
    return entries
  }

  private func presentItemCreate() {
    guard let createAnchor else { return }
    itemCreator.present(from: createAnchor) { title, body in
      appState.history.createTextItem(title: title, text: body, tag: appState.history.tagFilter) == nil
        ? NSLocalizedString("save_failed", comment: "")
        : nil
    }
  }
}

/// 左栏一行的统一形状：图标或圆点在固定的 16pt 槽里居中，名称从同一个 x 起。
/// 用 SwiftUI 画而不是 NSButton：无边框 NSButton 的 `alignment` 不生效，
/// 内容会自己居中，三行的图标和文字因此永远对不齐。
struct WorkspaceRailRow: View {
  var systemName: String?
  var tag: String?
  var title: String
  var expanded: Bool
  var selected: Bool
  var dropTargeted: Bool = false
  var help: String
  var identifier: String
  var onTap: () -> Void
  /// 只在展开档生效：点图标改外观，点名称或空白仍是切换分类。
  /// 收起档只剩图标，整行仍只负责切换。
  var onIconTap: (() -> Void)? = nil

  @State private var hovered = false
  @State private var iconHovered = false

  private var iconIsSeparate: Bool { expanded && onIconTap != nil }

  private var rowWidth: CGFloat {
    let rail = AppState.shared.effectiveRailWidth
    // 行宽就是栏宽减掉左侧 8pt（右侧不留，条目列自带间距）。
    return max(16, rail - WorkspaceRailMetrics.railLeading - WorkspaceRailMetrics.railTrailing)
  }

  var body: some View {
    HStack(spacing: 0) {
      if iconIsSeparate, let onIconTap {
        Button(action: onIconTap) { iconButtonLabel }
          .help(NSLocalizedString("tag_appearance_help", comment: ""))
          .buttonStyle(.plain)
          .onHover { iconHovered = $0 }
        .accessibilityIdentifier("\(identifier)-appearance")
        .accessibilityLabel(Text("tag_appearance_title"))
      }
      Button(action: onTap) {
        HStack(spacing: 3) {
          if !iconIsSeparate { iconSlot }
          if expanded {
            Text(title)
              .font(.system(size: 12))
              .foregroundStyle(selected ? Color.primary : Color.secondary)
              .lineLimit(1)
              .help(help)
            Spacer(minLength: 0)
          }
        }
        .padding(.leading, iconIsSeparate ? 3 : WorkspaceRailMetrics.leadingInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        // 空区域也要接点击：名称和空白都属于切换按钮。
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier(identifier)
      .accessibilityLabel(Text(title))
      .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
    .frame(width: rowWidth, height: WorkspaceRailMetrics.hit, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: WorkspaceRailMetrics.cornerRadius, style: .continuous)
        .fill(
          selected
            ? Color.accentColor.opacity(0.16)
            : (hovered ? Color.primary.opacity(0.07) : Color.clear)
        )
    )
    .onHover { hovered = $0 }
    .overlay(
      RoundedRectangle(cornerRadius: WorkspaceRailMetrics.cornerRadius, style: .continuous)
        .strokeBorder(Color.accentColor.opacity(dropTargeted ? 0.9 : 0), lineWidth: 1.5)
    )
    .help(help)
    .accessibilityElement(children: .contain)
  }

  private var iconButtonLabel: some View {
    iconSlot
      .background(
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(Color.primary.opacity(iconHovered ? 0.12 : 0))
          .padding(-3)
      )
      // 左侧留白也算图标按钮，指针不会落进死区。
      .padding(.leading, WorkspaceRailMetrics.leadingInset)
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
  }

  /// 两种图标共用一个 16pt 槽，中心对齐；圆点 10pt 与 12pt 的 SF Symbol 视觉重量相当。
  @ViewBuilder private var iconSlot: some View {
    ZStack {
      if let systemName {
        Image(systemName: systemName)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(selected ? Color.accentColor : Color.secondary)
      } else if let tag {
        WorkspaceTagGlyph(tag: tag, size: 15)
      }
    }
    .frame(width: 16, height: 16)
  }
}

struct WorkspaceRailAnchor: NSViewRepresentable {
  var onResolve: (NSView) -> Void

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async { onResolve(view) }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    DispatchQueue.main.async { onResolve(nsView) }
  }
}

/// 分类右键菜单共用同一宽度。不能按当前可见项收缩，否则「全部」只有「新建」时会缩成说明浮窗。
struct RailContextItem {
  var titleKey: String
  var separatorBefore = false
  var action: () -> Void
}

enum WorkspaceCategoryMenu {
  static let familyTitleKeys = [
    "create_snippet",
    "tag_rename_menu",
    "tag_merge_menu",
    "tag_delete_menu"
  ]

  static func minimumWidth(titleKeys: [String] = familyTitleKeys) -> CGFloat {
    let cell = NSMenuItemCell()
    let width = titleKeys.map { key -> CGFloat in
      let item = NSMenuItem(
        title: NSLocalizedString(key, comment: ""),
        action: nil,
        keyEquivalent: ""
      )
      cell.menuItem = item
      return cell.cellSize.width
    }.max() ?? 0
    return ceil(width)
  }

  static func menu(items: [RailContextItem]) -> (NSMenu, [MenuActionTarget]) {
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.minimumWidth = minimumWidth()
    var targets: [MenuActionTarget] = []
    for item in items {
      if item.separatorBefore {
        menu.addItem(.separator())
      }
      let entry = NSMenuItem(
        title: NSLocalizedString(item.titleKey, comment: ""),
        action: #selector(MenuActionTarget.fire(_:)),
        keyEquivalent: ""
      )
      let target = MenuActionTarget(item.action)
      entry.target = target
      entry.isEnabled = true
      targets.append(target)
      menu.addItem(entry)
    }
    return (menu, targets)
  }
}

struct RailContextMenuHost: NSViewRepresentable {
  var items: [RailContextItem]

  func makeNSView(context: Context) -> RailContextMenuView {
    let view = RailContextMenuView()
    view.items = items
    return view
  }

  func updateNSView(_ view: RailContextMenuView, context: Context) {
    view.items = items
  }
}

final class RailContextMenuView: NSView {
  var items: [RailContextItem] = []
  private var retainedTargets: [MenuActionTarget] = []

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
  }

  /// 左键、拖拽、放下仍交给原来的行。只接右键和按住 Control 的点击。
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard bounds.contains(point), let event = NSApp.currentEvent, claims(event) else { return nil }
    return self
  }

  override func rightMouseDown(with event: NSEvent) {
    present(event)
  }

  override func mouseDown(with event: NSEvent) {
    guard event.modifierFlags.contains(.control) else {
      super.mouseDown(with: event)
      return
    }
    present(event)
  }

  private func claims(_ event: NSEvent) -> Bool {
    switch event.type {
    case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
      return true
    case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
      return event.modifierFlags.contains(.control)
    default:
      return false
    }
  }

  private func present(_ event: NSEvent) {
    guard window != nil, !AppState.shared.menuTracking, !items.isEmpty else { return }
    let (menu, targets) = WorkspaceCategoryMenu.menu(items: items)
    retainedTargets = targets
    AppState.shared.menuTracking = true
    defer {
      AppState.shared.menuTracking = false
      retainedTargets = []
    }
    NSMenu.popUpContextMenu(menu, with: event, for: self)
  }
}
