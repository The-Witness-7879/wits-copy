# Wit's Copy

A clipboard history for the macOS menu bar. Text, images and files you copy are kept on your Mac;
search them, pin them, tag them, and preview before you paste.

[中文说明](#中文说明)

Wit's Copy is built on [Maccy](https://github.com/p0deje/Maccy) by Alex Rodionov. It is an
independent derivative, not an official Maccy release, and keeps its own history, preferences
and update channel.

## Install

Download `WitsCopy-<version>.dmg` from [Releases](https://github.com/The-Witness-7879/wits-copy/releases/latest),
open it, and drag Wit's Copy into Applications. Requires macOS 14 or later.

The app is ad-hoc signed and not notarized by Apple. If macOS blocks the first launch, open
**System Settings → Privacy & Security** and choose **Open Anyway**. Pasting into other apps needs
Accessibility permission; macOS may ask for it again after an update.

Wit's Copy checks for updates once a day. Turn this off, or check manually, in
**Settings → General**. Updates are verified with this project's own signing key.

## Use

| Action | How |
|---|---|
| Open the panel | Menu bar icon, or <kbd>⇧</kbd><kbd>⌥</kbd><kbd>⌘</kbd><kbd>V</kbd> (configurable) |
| Search | Start typing |
| Select / paste | Click selects; double-click pastes into the app you came from |
| Copy / paste the selection | <kbd>↩</kbd> copies; <kbd>⌥</kbd><kbd>↩</kbd> pastes |
| Pin / tag | <kbd>⌥</kbd><kbd>P</kbd> / <kbd>⌥</kbd><kbd>T</kbd>, or right-click a row |
| Preview | <kbd>⌃</kbd><kbd>Space</kbd> |
| Settings | <kbd>⌘</kbd><kbd>,</kbd> |

## Privacy

History is stored only on this Mac, in `~/Library/Application Support/Wit's Copy/`. The app does
not upload it anywhere. Passwords, one-time codes, tokens, private keys and card numbers can be
skipped automatically, and specific apps can be ignored (**Settings → Privacy**).

The only network requests are update checks, which download the public update feed and, when you
agree, the signed update.

## Build

Requires Xcode 26 or later. If `xcode-select` points at the Command Line Tools, set
`DEVELOPER_DIR` to Xcode's `Contents/Developer` first.

```sh
./scripts/test.sh      # unit tests; never touches the real clipboard or runs UI tests
./scripts/deploy.sh    # build Release and install it (INSTALL_PATH, default /Applications)
./scripts/release.sh   # DMG, checksum and signed update feed under lab/releases/
```

Development notes are in [lab/LAB.md](./lab/LAB.md).

## Acknowledgements

Wit's Copy exists because of **[Maccy](https://github.com/p0deje/Maccy)**. Alex Rodionov and the
Maccy contributors built the clipboard engine, the panel and many of the details this app still
relies on. Wit's Copy started from Maccy 2.7.1 and keeps its MIT license and copyright notice.
If you want a mature, well-maintained clipboard manager, use Maccy.

It also builds on:

| Project | License |
|---|---|
| [Sparkle](https://github.com/sparkle-project/Sparkle) | MIT, with bundled BSD and zlib notices |
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | MIT |
| [Defaults](https://github.com/sindresorhus/Defaults) | MIT |
| [LaunchAtLogin](https://github.com/sindresorhus/LaunchAtLogin-Modern) | MIT |
| [Sauce](https://github.com/Clipy/Sauce) | MIT |
| [Fuse](https://github.com/krisk/fuse-swift) | MIT |
| [SwiftHEXColors](https://github.com/thii/SwiftHEXColors) | MIT |
| [swift-log](https://github.com/apple/swift-log) | Apache 2.0 |

Full license texts ship inside the app (**About → Acknowledgements & Licenses**) and in
[Acknowledgements.txt](./WitsCopy/Acknowledgements.txt).

## License

[MIT](./LICENSE). Copyright © 2025 Alex Rodionov (Maccy); modifications copyright © 2026 TheWitness.

---

## 中文说明

Wit's Copy 是常驻 macOS 菜单栏的剪贴板历史工具。复制过的文字、图片和文件自动留存在本机，可以搜索、置顶、
打标签，粘贴前先预览。

本项目基于 Alex Rodionov 的开源项目 [Maccy](https://github.com/p0deje/Maccy) 2.7.1 改造，是独立的衍生版本，
不是 Maccy 官方发行版；历史、设置和更新渠道都与 Maccy 分开。感谢 Maccy 及其贡献者，这个应用的剪贴板核心、
面板和许多细节都来自他们的工作。

- **安装**：从 [Releases](https://github.com/The-Witness-7879/wits-copy/releases/latest) 下载 DMG，把应用拖进
  「应用程序」。需要 macOS 14 或更高版本。应用未经 Apple 公证，首次打开如被拦截，到「系统设置 → 隐私与安全性」
  选择「仍要打开」。粘贴到其他应用需要辅助功能权限，更新后系统可能要求重新授权。
- **隐私**：历史只保存在 `~/Library/Application Support/Wit's Copy/`，应用不会上传。唯一的联网是检查更新。
- **许可**：MIT，见 [LICENSE](./LICENSE)。
