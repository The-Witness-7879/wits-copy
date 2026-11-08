import Foundation

/// Unknown sources are recordable in blacklist mode and rejected in whitelist mode.
enum ClipboardIgnoreRules {
  static func shouldIgnore(
    sourceAppBundle: String?,
    ignoredApps: [String],
    ignoreAllAppsExceptListed: Bool
  ) -> Bool {
    guard let sourceAppBundle else { return ignoreAllAppsExceptListed }
    let listed = ignoredApps.contains(sourceAppBundle)
    return ignoreAllAppsExceptListed ? !listed : listed
  }
}

/// Best-effort capture protection, not a guarantee that every secret can be recognized.
/// These pure rules never read files, OCR images, or mutate clipboard/history/preferences.
enum SensitiveContentDetector {
  typealias Representation = (type: String, data: Data?)

  // Limit each regex evaluation, not the total capture. Overlap keeps credentials
  // that straddle a chunk boundary detectable without dropping ordinary long text.
  static let scanChunkCharacterCount = 65_536
  private static let scanChunkOverlap = 512

  // Best-effort identities: browser extensions and future app IDs may not expose
  // these bundles. Pasteboard markers and text checks supply independent signals.
  private static let passwordManagerBundles: Set<String> = [
    "com.1password.1password", "com.1password.1password7",
    "com.agilebits.onepassword", "com.agilebits.onepassword7",
    "com.bitwarden.desktop", "org.keepassxc.keepassxc", "net.antelle.keeweb",
    "in.sinew.enpass-desktop", "com.lastpass.lastpass",
    "com.dashlane.dashlane", "com.dashlane.mac.dashlane"
  ]
  private static let sensitivePasteboardTypes: Set<String> = [
    "com.agilebits.onepassword", "net.antelle.keeweb",
    "de.petermaurer.TransientPasteboardType", "Pasteboard generator type",
    "com.typeit4me.clipping"
  ]
  private static let textTypes: Set<String> = [
    "public.utf8-plain-text", "public.utf16-plain-text", "NSStringPboardType",
    "public.html", "public.rtf"
  ]

  static func isSensitiveSource(_ bundle: String?) -> Bool {
    guard let bundle else { return false }
    return passwordManagerBundles.contains(bundle.lowercased())
  }

  static func hasSensitivePasteboardType(_ types: Set<String>) -> Bool {
    !types.isDisjoint(with: sensitivePasteboardTypes)
  }

  static func containsSensitiveContent(inItems items: [[Representation]]) -> Bool {
    items.contains { containsSensitiveContent(in: $0) }
  }

  static func containsSensitiveContent(in representations: [Representation]) -> Bool {
    for representation in representations where textTypes.contains(representation.type) {
      guard let data = representation.data, !data.isEmpty else { continue }
      // Do not load remote HTML resources. Undecodable text is rejected rather
      // than persisted without inspection; binary files/images never reach here.
      let encodings: [String.Encoding] = representation.type == "public.utf16-plain-text"
        ? [.utf16, .utf16LittleEndian, .utf16BigEndian]
        : [.utf8, .isoLatin1]
      let decoded = encodings.compactMap { String(data: data, encoding: $0) }
      guard !decoded.isEmpty else { return true }
      if decoded.contains(where: containsSensitiveText) { return true }
    }
    return false
  }

  static func containsSensitiveText(_ text: String) -> Bool {
    guard !text.isEmpty else { return false }
    var start = text.startIndex
    while start < text.endIndex {
      let end = text.index(
        start,
        offsetBy: scanChunkCharacterCount,
        limitedBy: text.endIndex
      ) ?? text.endIndex
      if containsSensitiveChunk(String(text[start..<end])) { return true }
      if end == text.endIndex { break }
      start = text.index(end, offsetBy: -scanChunkOverlap)
    }
    return false
  }

  private static func containsSensitiveChunk(_ text: String) -> Bool {
    let range = NSRange(text.startIndex..., in: text)
    for match in assignment.matches(in: text, range: range) {
      for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
        guard let valueRange = Range(match.range(at: index), in: text) else { continue }
        let value = text[valueRange].trimmingCharacters(in: .whitespacesAndNewlines)
        if isSecretValue(value, quoted: index != 3) { return true }
      }
    }
    if secretPatterns.contains(where: { $0.firstMatch(in: text, range: range) != nil }) { return true }
    return cardCandidate.matches(in: text, range: range).contains { match in
      guard let candidate = Range(match.range, in: text) else { return false }
      return isPaymentCard(String(text[candidate]))
    }
  }

  private static func isSecretValue(_ value: String, quoted: Bool) -> Bool {
    guard !value.isEmpty else { return false }
    let placeholders = ["null", "nil", "undefined", "true", "false", "required", "none"]
    if !quoted && placeholders.contains(value.lowercased()) { return false }
    if value.allSatisfy({ $0 == "*" }) { return false }
    if value.hasPrefix("<"), value.hasSuffix(">") { return false }
    if value.range(
      of: #"^\$\{?[A-Z_][A-Z0-9_]*\}?$"#,
      options: .regularExpression
    ) != nil { return false }
    return true
  }

  // Compile trusted, fixed patterns once, not on every clipboard tick.
  private static let assignment = regex(
    #"(?i)(?<![a-z0-9_])(?:password|passwd|pwd|passphrase|secret|token|api[_-]key|access[_-]key|auth[_-]token|client[_-]secret|private[_-]key|密码|口令|密钥|令牌|凭证)["']?\s*[=:：]\s*(?:"([^"\r\n]*)"|'([^'\r\n]*)'|([^\s"',;}\]]+))"#
  )
  private static let secretPatterns: [NSRegularExpression] = [
    // URL userinfo is sensitive only when it also contains a password.
    #"(?i)\b[a-z][a-z0-9+.-]{1,20}://[^\s/@:]+:[^\s/@]+@"#,
    #"(?i)\b(?:Bearer[ \t]+[a-z0-9._~+/-]+={0,2}|Basic[ \t]+[a-z0-9+/]{4,}={0,2})"#,
    #"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----"#,
    #"(?<![A-Za-z0-9_])(?:gh[pousr]_[A-Za-z0-9]{20,255}|github_pat_[A-Za-z0-9_]{40,255})(?![A-Za-z0-9_])"#,
    #"(?<![A-Za-z0-9_])glpat-[A-Za-z0-9_-]{20,255}(?![A-Za-z0-9_-])"#,
    #"(?<![A-Za-z0-9_])sk-(?:(?:proj|svcacct)-[A-Za-z0-9_-]{20,255}|[A-Za-z0-9]{20,255})(?![A-Za-z0-9_-])"#,
    #"(?<![A-Z0-9])(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Z0-9])"#,
    #"(?<![A-Za-z0-9_])(?:xox[baprs]-[A-Za-z0-9-]{10,255}|xapp-[0-9]-[A-Za-z0-9-]{20,255})(?![A-Za-z0-9-])"#,
    #"(?<![A-Za-z0-9_])(?:AIza[A-Za-z0-9_-]{35}|ya29\.[A-Za-z0-9_-]{20,255})(?![A-Za-z0-9_-])"#,
    #"(?<![A-Za-z0-9_])npm_[A-Za-z0-9]{36}(?![A-Za-z0-9])"#,
    #"(?<![A-Za-z0-9_])(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,255}(?![A-Za-z0-9])"#,
    #"(?<![A-Za-z0-9_])(?:dckr_pat_[A-Za-z0-9_-]{20,255}|shpat_[A-Za-z0-9]{32,255})(?![A-Za-z0-9_-])"#,
    #"(?<![A-Za-z0-9_])SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}(?![A-Za-z0-9_-])"#,
    #"(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{5,}\.eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{8,}(?![A-Za-z0-9_-])"#,
    #"(?i)(?:\b(?:otp|verification[ \t]+code|security[ \t]+code|one[ -]time[ \t]+(?:code|password))\b|验证码|校验码|动态码|动态口令)[^\r\n0-9]{0,24}(?<![0-9])[0-9]{6}(?![0-9])"#,
    #"(?i)(?<![0-9])[0-9]{6}(?![0-9])[^\r\n0-9]{0,24}(?:\b(?:otp|verification[ \t]+code|security[ \t]+code|one[ -]time[ \t]+(?:code|password))\b|验证码|校验码|动态码|动态口令)"#
  ].map(regex)
  private static let cardCandidate = regex(
    #"(?<![0-9A-Za-z])(?:[0-9][ -]?){12,18}[0-9](?![0-9A-Za-z]|[ -][0-9])"#
  )

  private static func regex(_ pattern: String) -> NSRegularExpression {
    // A malformed developer-owned pattern is a programming error, not a reason
    // to silently turn protection off. Tests exercise every pattern at this seam.
    try! NSRegularExpression(pattern: pattern)
  }

  private static func isPaymentCard(_ candidate: String) -> Bool {
    let digits = candidate.utf8.filter { (48...57).contains($0) }.map { Int($0 - 48) }
    guard (13...19).contains(digits.count) else { return false }
    func prefix(_ count: Int) -> Int { digits.prefix(count).reduce(0) { $0 * 10 + $1 } }
    let count = digits.count
    let visa = digits[0] == 4 && [13, 16, 19].contains(count)
    let mastercard = count == 16 && ((51...55).contains(prefix(2)) || (2221...2720).contains(prefix(4)))
    let amex = count == 15 && [34, 37].contains(prefix(2))
    let discover = (16...19).contains(count) && (
      prefix(4) == 6011 || prefix(2) == 65 || (644...649).contains(prefix(3)) ||
        (622126...622925).contains(prefix(6))
    )
    let jcb = (16...19).contains(count) && (3528...3589).contains(prefix(4))
    let diners = count == 14 && ((300...305).contains(prefix(3)) || [36, 38, 39].contains(prefix(2)))
    let unionPay = (16...19).contains(count) && prefix(2) == 62
    let maestro = (13...19).contains(count) && ([50, 63, 67].contains(prefix(2)) || (56...59).contains(prefix(2)))
    guard visa || mastercard || amex || discover || jcb || diners || unionPay || maestro else { return false }
    let sum = digits.reversed().enumerated().reduce(0) { sum, element in
      let value = element.offset.isMultiple(of: 2) ? element.element : element.element * 2
      return sum + (value > 9 ? value - 9 : value)
    }
    return sum.isMultiple(of: 10)
  }
}
