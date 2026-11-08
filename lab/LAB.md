# Wit's Copy · 开发说明

当前版本 **0.1.0**，是本项目的首个发布版本。基于 Maccy 2.7.1 改造。

## 版本

- 版本号 `MAJOR.MINOR.PATCH` 写在工程的 `MARKETING_VERSION`，Git 标签带 `v` 前缀，如 `v0.1.0`。
- 1.0 之前：新增功能、改界面或改数据行为升 MINOR（0.1.0 → 0.2.0）；只修缺陷升 PATCH（0.1.0 → 0.1.1）。
- 构建号 `CURRENT_PROJECT_VERSION` 用 `YYYYMMDDNN`，只增不减。Sparkle 按构建号判断新旧，
  本机自装的包也必须比正在用的包大。
- 发布：改版本号和构建号 → `./scripts/test.sh` → 提交并打标签 → `./scripts/release.sh` →
  把 `lab/releases/<版本>-<构建号>/updates/` 下的 DMG、`appcast.xml`、`SHA256SUMS` 上传到 GitHub Release。

## 身份与数据

| 项 | 值 |
|---|---|
| 显示名 / 可执行文件 | Wit's Copy / `WitsCopy` |
| 包标识 | `local.thewitness.WitsCopy` |
| 历史库 | `~/Library/Application Support/Wit's Copy/Storage.sqlite` |
| 偏好 | `~/Library/Preferences/local.thewitness.WitsCopy.plist` |
| 更新源 | `https://github.com/The-Witness-7879/wits-copy/releases/latest/download/appcast.xml` |

- 永不打开 Maccy 自己的库（`Application Support/Maccy`），`Storage.swift` 里有守卫。
- XCTest、SwiftUI 预览和 `--lab-*-smoke` 实例只用内存库和隔离偏好，不读写真实剪贴板，不发通知，不启动 Sparkle。
- 每次 ad-hoc 重建签名都会变，系统可能要求重新授予粘贴所需的辅助功能权限。

## 常用命令

```sh
./scripts/test.sh                                   # 单元测试：跳过真实剪贴板与 UI 测试
./scripts/test.sh -only-testing:WitsCopyTests/Foo   # 只跑一个测试类
INSTALL_PATH=/Applications/WitsCopy.app ./scripts/deploy.sh   # 构建 Release 并替换本机安装
./scripts/release.sh                                # DMG、SHA256 与签名的 appcast
```

- `scripts/adhoc-sign.py` 由 `deploy.sh` 和 `release.sh` 共用，按由内到外的顺序做 ad-hoc 签名并校验。
- `deploy.sh` 替换前把旧应用、偏好和历史目录备份到 `lab/backups/<时间>/`。
- 测试用 `lab/.derived`，Release 用 `lab/.derived-release`；测试结果包在 `lab/results/`，只留最近 10 个。
- 预览测试的合成素材由 `WitsCopyTests/TestFixtures.swift` 在测试进程里生成；
  `lab/fixtures/` 是 `--lab-fixtures` smoke 实例用的合成样本。
- 查死代码：`periphery scan`（读 `.periphery.yml`）。
- 提交钩子 `.githooks/pre-commit` 拦截构建产物和超过 5 MB 的文件；克隆后运行
  `git config core.hooksPath .githooks`。

## 约定

- `lab/` 下除本文件和 `fixtures/` 外都是本地状态，不进版本库。
- Sparkle 更新私钥只存在 macOS 钥匙串，仓库和 `Info.plist` 里只有公钥。
- 界面语言只保留 `en`（开发语言）和 `zh-Hans`。
