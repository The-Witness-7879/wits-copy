import AppKit

extension NSWorkspace {
  func applicationName(url: URL) -> String {
    if let bundle = Bundle(url: url) {
      let localized = bundle.localizedInfoDictionary ?? [:]
      if let displayName = localized["CFBundleDisplayName"] as? String, !displayName.isEmpty {
        return displayName
      }
      if let name = localized["CFBundleName"] as? String, !name.isEmpty {
        return name
      }
      if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
         !displayName.isEmpty {
        return displayName
      }
      if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty {
        return name
      }
    }
    return url.deletingPathExtension().lastPathComponent
  }
}
