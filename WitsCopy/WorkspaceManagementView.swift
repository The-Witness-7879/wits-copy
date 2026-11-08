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

  private var railTags: [String] {
    WorkspaceTagDirectory.ordered(stored: storedTags, itemTags: appState.history.knownTags)
  }

  var body: some View {
    let expanded = appState.managementRailVisible
    let tags = railTags
    let _ = appState.history.items.count
    ScrollViewReader { proxy in
      // Overlay scroller in the rail covers the hit target. Wheel and trackpad still scroll.
      ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: WorkspaceRailFlow.spacing) {
          ForEach(WorkspaceSection.primaryRail) { section in
            railButton(section, expanded: expanded)
          }
          ForEach(tags, id: \.self) { tag in
            WorkspaceRailTagButton(tag: tag, expanded: expanded)
              .id(tag)
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
        // 整行（选中底色）从距窗体 4pt 起，行内再缩 2pt 放图标，
        // 图标中心落在 14pt，和标题栏那个圆点在同一条竖线上。
        .padding(.horizontal, WorkspaceRailMetrics.railGutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
      .onChange(of: scrollTag) {
        guard let tag = scrollTag else { return }
        proxy.scrollTo(tag, anchor: .bottom)
        scrollTag = nil
      }
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
}

struct WorkspaceRailTagButton: View {
  var tag: String
  var expanded: Bool = false
  @Environment(AppState.self) private var appState
  @State private var edit: RailTagEdit?
  @State private var confirmDelete = false
  @State private var editError: String?
  @State private var dropHighlighted = false

  private var selected: Bool {
    WorkspaceRailPolicy.isTagSelected(tag, tagFilter: appState.history.tagFilter)
  }

  var body: some View {
    WorkspaceRailRow(
      dotColor: WorkspaceTagDot.color(for: tag),
      title: tag,
      expanded: expanded,
      selected: selected,
      dropTargeted: dropHighlighted,
      help: tag,
      identifier: WorkspaceRailPolicy.accessibilityIdentifier(for: tag),
      onTap: { WorkspaceRailPolicy.selectTag(tag, in: appState) }
    )
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
    .contextMenu {
      Button(NSLocalizedString("tag_rename_menu", comment: "")) { present(.rename) }
      Button(NSLocalizedString("tag_merge_menu", comment: "")) { present(.merge) }
      Divider()
      Button(NSLocalizedString("tag_delete_menu", comment: "")) { presentDelete() }
    }
    .iconHelp(tag)
    .accessibilityValue(WorkspaceRailFeedback.accessibilityValue(selected: selected, dropTarget: dropHighlighted))
    .popover(isPresented: editPresented, arrowEdge: .trailing) {
      RailTagNamePopover(tag: tag, merging: edit == .merge)
        .environment(appState)
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

private struct RailTagNamePopover: View {
  var tag: String
  var merging: Bool
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @Default(.workspaceTagDirectory) private var storedTags
  @State private var draft = ""
  @State private var editError: String?
  @FocusState private var draftFocused: Bool

  private var mergeTargets: [String] {
    WorkspaceTagDirectory.ordered(stored: storedTags, itemTags: appState.history.knownTags)
      .filter { $0.caseInsensitiveCompare(tag) != .orderedSame }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(merging ? String(format: NSLocalizedString("tag_merge_heading", comment: ""), tag) : NSLocalizedString("tag_rename", comment: ""))
        .font(.headline)
        .fixedSize(horizontal: false, vertical: true)
      if !merging {
        Text(verbatim: tag)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      if merging {
        mergeList
      } else {
        renameField
      }
      if let editError {
        Text(editError)
          .font(.caption)
          .foregroundStyle(.red)
          .accessibilityIdentifier("lab-rail-tag-error")
      }
    }
    .padding(12)
    .frame(width: 220)
    .onAppear {
      draft = tag
      editError = nil
      if !merging {
        DispatchQueue.main.async { draftFocused = true }
      }
    }
  }

  private var renameField: some View {
    VStack(alignment: .leading, spacing: 6) {
      TextField("tag_rename", text: $draft)
        .glassTextField()
        .focused($draftFocused)
        .accessibilityIdentifier("lab-rail-rename-field")
        .onSubmit(commitRename)
      Button("tag_rename", action: commitRename)
        .iconHelp(NSLocalizedString("tag_rename_help", comment: ""))
        .accessibilityIdentifier("lab-rail-rename-confirm")
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
    switch WorkspaceTagDirectoryActions.rename(
      from: tag,
      to: draft,
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
        Circle()
          .fill(Color(nsColor: WorkspaceTagDot.color(for: name)))
          .frame(width: 7, height: 7)
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
  @State private var snippetPresented = false

  var body: some View {
    ImmediateMenuButton(
      systemName: "ellipsis.circle",
      help: NSLocalizedString("options_help", comment: ""),
      identifier: "lab-options-button",
      label: NSLocalizedString("options", comment: ""),
      entries: optionEntries
    )
    .frame(width: hit.width, height: hit.height)
    .popover(isPresented: $snippetPresented, arrowEdge: arrowEdge) {
      SnippetComposer()
        .environment(appState)
    }
    .accessibilityIdentifier("lab-options-button")
  }

  private var optionEntries: [ImmediateMenuEntry] {
    var entries: [ImmediateMenuEntry] = []
    for item in appState.footer.items where item.title != "clear" {
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
      action: { snippetPresented = true }
    ))
    return entries
  }
}

struct SnippetComposer: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @State private var title = ""
  @State private var text = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("create_snippet")
        .font(.headline)
      TextField(NSLocalizedString("snippet_title_field", comment: ""), text: $title)
        .glassTextField()
        .accessibilityIdentifier("lab-snippet-title")
      TextField(NSLocalizedString("snippet_body_field", comment: ""), text: $text)
        .glassTextField()
        .accessibilityIdentifier("lab-snippet-body")
      Button(NSLocalizedString("snippet_add", comment: ""), action: addSnippet)
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .iconHelp(NSLocalizedString(
          "snippet_add_help",
          value: "Add this snippet",
          comment: "Hover help for adding a pinned snippet"
        ))
        .accessibilityIdentifier("lab-snippet-add")
      if let message = appState.storageError {
        Text(message)
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
    .padding(12)
    .frame(width: 260)
  }

  private func addSnippet() {
    guard appState.history.createSnippet(title: title, text: text) != nil else { return }
    title = ""
    text = ""
    dismiss()
  }
}

/// 左栏一行的统一形状：图标或圆点在固定的 16pt 槽里居中，名称从同一个 x 起。
/// 用 SwiftUI 画而不是 NSButton：无边框 NSButton 的 `alignment` 不生效，
/// 内容会自己居中，三行的图标和文字因此永远对不齐。
struct WorkspaceRailRow: View {
  var systemName: String?
  var dotColor: NSColor?
  var title: String
  var expanded: Bool
  var selected: Bool
  var dropTargeted: Bool = false
  var help: String
  var identifier: String
  var onTap: () -> Void

  @State private var hovered = false

  private var rowWidth: CGFloat {
    let rail = AppState.shared.effectiveRailWidth
    // 选中底色离窗体左右各 4pt，行宽就是栏宽减掉这两段。
    return max(16, rail - WorkspaceRailMetrics.railGutter * 2)
  }

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: 3) {
        iconSlot
        if expanded {
          Text(title)
            .font(.system(size: 12))
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .lineLimit(1)
            .help(help)
          Spacer(minLength: 0)
        }
      }
      .padding(.leading, WorkspaceRailMetrics.leadingInset)
      .frame(width: rowWidth, height: WorkspaceRailMetrics.hit, alignment: .leading)
      // 空区域也要接点击：整行是一个按钮，不是只有图标。
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
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
    .accessibilityIdentifier(identifier)
    .accessibilityLabel(Text(title))
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
  }

  /// 两种图标共用一个 16pt 槽，中心对齐；圆点 10pt 与 12pt 的 SF Symbol 视觉重量相当。
  @ViewBuilder private var iconSlot: some View {
    ZStack {
      if let systemName {
        Image(systemName: systemName)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(selected ? Color.accentColor : Color.secondary)
      } else if let dotColor {
        Circle()
          .fill(Color(nsColor: dotColor))
          .frame(width: 10, height: 10)
      }
    }
    .frame(width: 16, height: 16)
  }
}

/// 给「新建标签」行一个可用的 NSView 作为弹窗定位锚点。
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
