import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

struct PrivacySettingsPane: View {
  @Default(.ignoredApps) private var ignoredApps
  @State private var selection: String?
  @State private var isAddingApplication = false
  @State private var importFailed = false

  var body: some View {
    SettingsLayout.form {
      SettingsLayout.row("SensitiveContent", table: "PrivacySettings") {
        Defaults.Toggle(key: .protectSensitiveContent) {
          Text("ProtectSensitiveContent", tableName: "PrivacySettings")
        }
        .help(Text("ProtectSensitiveContentDescription", tableName: "PrivacySettings"))
        SettingsLayout.description("ProtectSensitiveContentDescription", table: "PrivacySettings", underCheckbox: true)
      }

      SettingsLayout.sectionBreak()

      SettingsLayout.row("Applications", table: "PrivacySettings", alignment: .top) {
        VStack(spacing: 0) {
          List(selection: $selection) {
            ForEach(uniqueIgnoredApps, id: \.self) { bundle in
              applicationRow(bundle)
                .tag(bundle)
            }
          }
          .listStyle(.plain)
          .scrollContentBackground(.hidden)
          .frame(height: ignoredApps.isEmpty ? 52 : min(CGFloat(uniqueIgnoredApps.count) * 40 + 4, 164))
          .overlay {
            if ignoredApps.isEmpty {
              Text("NoApplications", tableName: "PrivacySettings")
                .font(.callout)
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)
            }
          }
          .accessibilityLabel(Text("Applications", tableName: "PrivacySettings"))
          .onDeleteCommand(perform: removeSelectedApplication)

          Divider()

          HStack(spacing: 0) {
            Button {
              isAddingApplication = true
            } label: {
              Image(systemName: "plus")
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
            }
            .help(Text("AddApplication", tableName: "PrivacySettings"))
            .accessibilityLabel(Text("AddApplication", tableName: "PrivacySettings"))
            Divider()
              .frame(height: 14)
            Button(action: removeSelectedApplication) {
              Image(systemName: "minus")
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
            }
            .disabled(selection == nil || !ignoredApps.contains(selection ?? ""))
            .help(Text("RemoveApplication", tableName: "PrivacySettings"))
            .accessibilityLabel(Text("RemoveApplication", tableName: "PrivacySettings"))
            Spacer(minLength: 0)
          }
          .buttonStyle(.borderless)
          .padding(.horizontal, 4)
          .frame(height: 24)
        }
        // Same translucent field skin as the other inputs; an opaque
        // control-background box would sit on the glass like a patch.
        .background(GlassField.fill)
        .clipShape(RoundedRectangle(cornerRadius: GlassField.cornerRadius, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: GlassField.cornerRadius, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor))
        )
        .frame(width: SettingsMetrics.controlWidth, alignment: .leading)
        .padding(.bottom, 4)

        Defaults.Toggle(key: .ignoreAllAppsExceptListed) {
          Text("OnlyRecordListedApplications", tableName: "PrivacySettings")
        }
        .help(Text("ApplicationsDescription", tableName: "PrivacySettings"))
        SettingsLayout.description("ApplicationsDescription", table: "PrivacySettings", underCheckbox: true)
      }
    }
    .fileDialogDefaultDirectory(URL(fileURLWithPath: "/Applications", isDirectory: true))
    .fileImporter(isPresented: $isAddingApplication, allowedContentTypes: [.application]) { result in
      switch result {
      case .success(let url):
        addApplication(at: url)
      case .failure(let error):
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError { return }
        importFailed = true
      }
    }
    .alert(Text("ApplicationImportFailed", tableName: "PrivacySettings"), isPresented: $importFailed) {
      Button(role: .cancel) {
        importFailed = false
      } label: {
        Text("Dismiss", tableName: "PrivacySettings")
      }
      .help(Text("ApplicationImportDismissHelp", tableName: "PrivacySettings"))
    }
  }

  private var uniqueIgnoredApps: [String] {
    var seen = Set<String>()
    return ignoredApps.filter { seen.insert($0).inserted }
  }

  private func applicationRow(_ bundle: String) -> some View {
    let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
    return HStack(spacing: 8) {
      if let url {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
          .resizable()
          .scaledToFit()
          .frame(width: 24, height: 24)
      } else {
        Image(systemName: "questionmark.app")
          .frame(width: 24, height: 24)
      }
      VStack(alignment: .leading, spacing: 2) {
        if let url {
          Text(NSWorkspace.shared.applicationName(url: url))
          Text(bundle)
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Text(bundle)
        }
      }
      .lineLimit(1)
    }
    .frame(height: 32)
  }

  private func addApplication(at url: URL) {
    let isAccessing = url.startAccessingSecurityScopedResource()
    defer {
      if isAccessing { url.stopAccessingSecurityScopedResource() }
    }
    guard let bundle = Bundle(url: url)?.bundleIdentifier, !bundle.isEmpty else {
      importFailed = true
      return
    }
    if !ignoredApps.contains(bundle) { ignoredApps.append(bundle) }
    selection = bundle
  }

  private func removeSelectedApplication() {
    guard let selection else { return }
    ignoredApps.removeAll { $0 == selection }
    self.selection = nil
  }
}
