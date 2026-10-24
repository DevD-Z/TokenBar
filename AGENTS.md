# TokenBar — Agent 指南

TokenBar 是参考 [CodexBar](https://github.com/steipete/CodexBar) 的开源跨平台 AI 额度监控，Flutter + Dart，
支持 Windows、macOS、Linux、Android、iOS（另有 Web 构建，配合同步服务器用）。
用户在客户端里添加某个服务（本机登录 / API Key / Cookie），直接向服务商查询额度。服务器是可选组件，只用于跨设备同步快照。

- 仓库：<https://github.com/lwh0630/TokenBar>（公开，MIT，默认分支 `main`）。
- **回复用户请使用简体中文。** 代码注释、README 主文档、提交信息用英文（`README.zh-CN.md` 和应用里的中文文案除外）。
- 本文件是唯一的约定来源；`CLAUDE.md` 只是 `@AGENTS.md` 引用。改约定只改这一份，并保持它和代码一致。
- 接手一个任务的顺序：读本文件 → 看相关代码和测试 → 动手 → 按「完成一项改动的检查清单」自检 → 提交推送 → 等 CI。

## 目录

```
lib/                            Flutter 应用（provider + ChangeNotifier）
  main.dart                     启动、MaterialApp、托盘面板的挂载点（面板自带 Overlay）
  app/                          app_shell.dart（导航：宽屏侧栏 / 窄屏底栏）、theme.dart（主题、字体回退、seriesPalette）
  app_info.dart                 仓库名、项目主页等常量
  demo/demo_data.dart           演示模式的虚构账户 / 快照 / 历史 / 分模型用量（截图用）
  l10n/                         app_zh.arb（模板）、app_en.arb、生成的 app_localizations*.dart（要提交）、app_locale.dart
  state/app_controller.dart     账户、刷新、同步、自动检测本机登录、modelUsage、updateSettings
  state/settings.dart           AppSettings、SyncMode、AppLanguage、平台判断（canUseLocalLogins）
  state/update_controller.dart  检查更新状态
  services/                     persistence（secure storage）、desktop_io/desktop_stub（托盘/窗口，条件导入）、
                                notifier、quota_alerts、home_widget_bridge、history_*、update/（读 GitHub releases）
  ui/pages/                     dashboard / accounts（编辑器由 ProviderField 生成）/ account_detail / settings
  ui/widgets/                   account_card、quota_ring、usage_bar、history_chart、stacked_bar_chart、provider_badge …
  ui/tray_panel.dart            桌面托盘小面板
  ui/format.dart                带 AppLocalizations 的格式化（倒计时、百分比、金额、窗口标签）
  ui/chart_math.dart, history_series.dart   图表的纯函数（有单元测试）
packages/tokenbar_core/         纯 Dart：模型、各服务抓取、同步客户端、托盘图标渲染
  lib/src/models/               AccountConfig、UsageSnapshot、RateWindow、Credits、UsagePoint、ModelUsageSeries
  lib/src/providers/            provider.dart（基类）、fields.dart、http_support.dart、common.dart、registry.dart
    api/                        简单服务（按类别分组的文件，一个文件多个服务）
    codex/ claude/ cursor/      有本机凭证读取、分模型用量等复杂逻辑的服务
  lib/src/platform/             platform_io.dart / platform_stub.dart（条件导入，web 无 dart:io）
  test/                         单元测试 + fixtures/（真实响应样本，日志类 fixture 必须是合成数据）
packages/tokenbar_server/       CLI（usage / collect / serve）与可选同步服务器（shelf + sqlite）
test/                           应用测试（widget、controller、图表、i18n、托盘面板、演示数据）
assets/provider_icons/          49 个服务 logo（SVG，来自 CodexBar，见该目录 README；归属见 NOTICE.md）
assets/icon/                    应用图标源图
tool/gen_icons.py               统一生成各平台应用图标（不要手改图标文件）
tool/build_windows_installer.ps1 Windows 安装程序构建 + 冒烟测试（CI 和发布共用）
windows/installer/              Inno Setup 脚本 tokenbar.iss + ChineseSimplified.isl
android/ ios/ macos/ linux/ windows/ web/   平台工程；Android 原生小组件、iOS WidgetKit 源码
.github/workflows/              ci.yml（检查 + 各平台构建）、release.yml（打 tag 发布草稿）
docs/screenshots/               README 截图：英文在根，中文在 zh/
README.md / README.zh-CN.md     英文主文档 / 中文文档（结构保持一致）
NOTICE.md                       第三方归属（CodexBar MIT、Inno Setup 语言文件等）
third_party/CodexBar/           参考源码（.gitignore，不提交）
third_party/provider_specs/     从 CodexBar 提取的接口规格（不提交，实现新服务时参考）
HANDOFF.md                      本地交接笔记（.gitignore，不提交，可能过期，以代码和本文件为准）
```

## 常用命令

```bash
flutter pub get
flutter gen-l10n                 # 改了 ARB 之后（生成文件要提交）
flutter analyze                  # 根目录，覆盖应用
flutter test                     # 应用测试
cd packages/tokenbar_core && dart analyze && dart test
cd packages/tokenbar_server && dart test
dart format lib test packages    # CI 会检查格式（行宽 100，见 analysis_options.yaml）：dart format --output=none --set-exit-if-changed lib test packages
dart run packages/tokenbar_server/bin/tokenbar.dart usage -p cursor --json   # 真实抓取验证
flutter run -d windows           # 本机调试；也可 -d emulator-5554 / -d chrome
flutter build windows | web | apk
cd packages/tokenbar_server && dart build cli -o ../../build/server          # 不要用 dart compile exe
```

演示模式（只用虚构数据，内存存储，不碰真实凭证，不发网络请求）：

```bash
flutter run -d windows --dart-define=TOKENBAR_DEMO=true
  --dart-define=TOKENBAR_DEMO_LANG=en|zh     # 固定界面语言（默认跟随系统）
  --dart-entrypoint-args=--panel             # 直接打开托盘面板（--dart-define=TOKENBAR_PANEL=true 同效）
```

## 完成一项改动的检查清单

1. `dart format lib test packages`（行宽 100）→ `flutter analyze` → `flutter test`；动了 `packages/*` 就再各跑一遍它们的 `dart analyze && dart test`。**三处都要绿。**
2. 新增 / 改动面向用户的文案：`app_zh.arb` 和 `app_en.arb` 一起改，跑 `flutter gen-l10n`，提交生成文件。
3. 新逻辑配测试：纯函数用单元测试；UI 用 widget 测试（注意测试里 `MaterialApp` 要带 locale 与 delegates）；修 bug 先写能复现的测试，并确认去掉修复后它会失败。
4. 改了行为、结构或踩了新坑：更新本文件（对应章节）；用户可见的改动同步 `README.md` 和 `README.zh-CN.md`。
5. UI 有可见变化：按「截图」一节重拍受影响的图。
6. 不要引入凭证、个人邮箱、本机路径（见「安全规则」）。
7. 提交推送，等 CI 全绿（见下一节）。

## 提交与推送

- **提交身份**必须是 GitHub noreply：`git config user.email` 应为 `79432134+lwh0630@users.noreply.github.com`，`user.name` 为 `lwh0630`。提交前先 `git config user.email` 确认；不要用个人邮箱，也不要改全局配置，只在本仓库设置。
- 推送用已登录的 `gh`（账户 `lwh0630`，https）：`git push origin main`。`gh` 偶尔报 `unexpected EOF`，重试即可（脚本里写重试循环）。
- 提交信息：英文，一行概要（祈使句，约 70 字符内）+ 空行 + 要点列表，写「为什么 / 改了什么」。一次提交只做一类事。
- 提交前 `git status` 看一眼，别带上 `build/`、`*.jks`、`key.properties`、`third_party/`、`HANDOFF.md`、`.dart_tool/`（都已在 `.gitignore`）和临时脚本 / 截图草稿。
- 默认直接推 `main`（个人项目）；改动大或有风险时先开分支，用 `gh pr create`。
- 推送后看 CI：`gh run list --repo lwh0630/TokenBar --workflow CI --limit 1 --json status,conclusion,headSha`，轮询到 `completed`；失败用 `gh run view <id> --log-failed` 排查。CI 在 GitHub 上构建所有平台，**不要在本机编译发布包**（本机只做 analyze / test / `flutter run` 调试和截图）。
- 并行的子代理 / 多个任务同时改文件时，只 `git add` 自己改的文件，不要 `git add -A` 把别人写到一半的东西带上。

## 发布

发布产物全部由 GitHub Actions 构建，Release 先建成**草稿**，由维护者实测后手动发布。

1. 确认 `main` 上最新提交的 CI 是绿的，工作区干净，README 的下载表 / 平台状态和实际一致。
2. 打 tag 触发 `release.yml`：`git tag vX.Y.Z && git push origin vX.Y.Z`（也可在 Actions 页手动触发 `workflow_dispatch`，填版本号）。
3. 等 Release 工作流完成（`gh run list --workflow Release`），然后核对草稿：`gh release view vX.Y.Z --repo lwh0630/TokenBar --json isDraft,assets`。应有：
   - Android：`arm64-v8a`、`armeabi-v7a`、`x86_64` 三个签名 APK
   - Windows：x64 / arm64 的 `-setup.exe`
   - macOS：arm64 / x86_64 的 `.dmg`
   - Linux：x64 / arm64 的 `.tar.gz`
   - iOS：`-ios-unsigned.ipa`
   - `SHA256SUMS.txt`
4. **要重打同一个版本**（tag 指向了旧提交）：`gh release delete vX.Y.Z --repo lwh0630/TokenBar --cleanup-tag --yes` → `git tag -d vX.Y.Z` → 在最新提交上重新 `git tag vX.Y.Z && git push origin vX.Y.Z`。已经发布（非草稿）的版本不要这样做，改发新的补丁版本。
5. 草稿保持草稿，告诉用户去实测（尤其 macOS dmg、Windows 安装程序、Android 升级安装），用户确认后才发布：`gh release edit vX.Y.Z --draft=false`（或网页上点 Publish）。
6. 版本号：`pubspec.yaml` 的 `version` 只是开发默认值，CI 用 tag 覆盖 `--build-name`，`--build-number` 取 `github.run_number`。应用内「检查更新」读 `releases/latest`（忽略草稿 / 预发布）。

升级 Flutter 版本：`ci.yml` 和 `release.yml` 里的 `FLUTTER_VERSION` 与 `FLUTTER_COMMIT`（该 tag 的完整 commit）要一起改，并同步 README 的徽章 / 构建说明。第三方 Action 一律固定到完整 commit SHA（注释里写 tag）。

## 截图（README 用）

- 一律用演示模式拍，**只允许虚构数据**：不得出现真实邮箱、本机路径、个人账户信息。
- 每次 UI 有可见改动就重拍，英文放 `docs/screenshots/`，中文放 `docs/screenshots/zh/`（`README.zh-CN.md` 引用 `zh/`）。文件名：`windows-dashboard.png`、`windows-history.png`、`windows-tray-panel.png`、`android-dashboard.png`、`android-detail.png`、`android-history.png`。只放浅色主题。
- Windows：`flutter run -d windows --dart-define=TOKENBAR_DEMO=true --dart-define=TOKENBAR_DEMO_LANG=en`，窗口约 1400×1400 物理像素（宽布局），用 Pillow 缩到宽 1100、裁掉底部 12 px 和左右各 2 px；托盘面板加 `--dart-entrypoint-args=--panel`，缩到宽 420。
- Android：模拟器 `flutter run -d emulator-5554 ...`，`adb shell screencap` + `adb shell input swipe/tap` 导航，缩到宽 540。
- 坑：Flutter 桌面 / 模拟器在没有输入时不刷新画面，截到的可能是上一帧；滚动后晃动鼠标（或再截一次）再取图。滚轮事件有延迟，分小步滚。
- 演示数据的分模型用量在 `DemoData.modelUsage`（只有 Cursor / Codex，确定性，按小时种子生成）。

## 核心概念

- `UsageProvider`（`provider.dart`）：`id`、`displayName`、`brandColor`、`supportedSources`、`setupHint`、`fields`、`fetch()`，可选 `fetchModelUsage()`。
  `fetchSafely()` 把 `ProviderException` 转成错误快照，UI 显示 `message` + `hint`（中文）。
- `SourceType.localCli`：读本机文件 / 运行 CLI（只在桌面端可用，`canUseLocalLogins`）。
  `SourceType.apiKey`：用户手填的字段（API Key、Cookie、Base URL、区域……），手机/网页也能用。
- `ProviderField`（`fields.dart`）：声明手填字段。`kind: secret` 的值存 `AccountConfig.secret`
  （只有一个主凭证 `key == 'secret'` 时存原文，多个时存 JSON，见 `SecretBundle`），其他存 `AccountConfig.options`。
  `envVars` 是桌面端留空时的回退（沿用 CodexBar 的环境变量名）。读取统一用 `FieldValues.of(this, account)`。
- `UsageSnapshot`：`windows`（`RateWindow`，usedPercent 0–100，`resetsAt`，`windowMinutes`）+ `credits`（`Credits`，余额 / 已用 / 上限 / 币种）+ `plan`/`email`/`source`/`extras`。
  托盘和小组件取 `tightestWindow`（剩余最少的窗口）。
- `SyncMode`：`local`（不使用服务器）、`server`（查看服务器数据）、`localPush`（推送本机数据）。本机账户在非 web 平台总是本地抓取。

## 添加一个服务

1. 先读 `third_party/provider_specs/<id>.md`（没有就去 `third_party/CodexBar/Sources/CodexBarCore/Providers/<Name>/` 与 `docs/<id>.md` 核对）。
   **端点、请求头、字段名、单位必须来自 CodexBar 源码或官方文档，不要猜。**
2. 简单服务放进 `packages/tokenbar_core/lib/src/providers/api/` 里按类别分组的文件（一个文件可以有多个服务，
   如 `account_api_providers.dart`、`coding_plan_providers.dart`、`cookie_*_providers.dart`）；
   有本机凭证读取等复杂逻辑的放 `providers/<id>/`。
   - 解析写成纯函数（`parseXxx(Map json) -> ...`），方便用 fixture 测试。
   - HTTP 用 `http_support.dart` 的 `fetchJsonObject` / `sendRequest` + `checkStatus`（统一超时、401/403/429 中文错误）；
     共用工具在 `common.dart`（`pct`、`quotaWindow`、`balanceRow`、`spendRow`、`gatewayBaseUrl`）和 `flex_quota.dart`。
   - 窗口 id 用 `<id>-xxx` 前缀，label 直接写中文（如 `每月`、`每日`）；金额用 `Credits`，`currency` 填 ISO 代码，非货币积分填 null。
   - `source` 字段：`api-key`、`web`（Cookie）、`local`、`admin-api` 等。
3. 在 `registry.dart` 注册；只有测试或 UI 需要的符号才在 `tokenbar_core.dart` 里 `show` 导出。
4. 在 `test/fixtures/` 放真实响应样本（来自 CodexBar 测试），在 `test/` 写 `MockClient` 抓取测试
   （`api_providers_test.dart` 里的 `_run(providerId, {URL 子串: 响应体或状态码})` 辅助函数）。
5. 更新 `README.md` 和 `README.zh-CN.md` 的服务表与服务数量（徽章、正文里的数字）。
6. 服务 logo：CodexBar 有对应 `ProviderIcon-<name>.svg` 就按 `assets/provider_icons/README.md` 的方式复制到 `assets/provider_icons/<id>.svg`，并把 id 加进 `provider_badge.dart` 的 `providerIconIds`（彩色 logo 另加到 `providerColoredIconIds`）；`test/provider_icons_test.dart` 会校验资源和集合一致。没有 logo 的服务回退成首字母方块。

## 多语言（i18n）

- 应用界面支持简体中文（模板 `lib/l10n/app_zh.arb`）和 English（`lib/l10n/app_en.arb`），由 Flutter gen-l10n 生成 `lib/l10n/app_localizations*.dart`（配置在根目录 `l10n.yaml`，`pubspec.yaml` 中 `generate: true`）。生成文件要提交（`synthetic-package` 已被 Flutter 移除，`.gitignore` 也不忽略它们）；不要手改，改 ARB 后运行 `flutter gen-l10n`（或 `flutter pub get`）。
- **新增或修改面向用户的文案，必须同时写 `app_zh.arb` 和 `app_en.arb`**（`test/i18n_test.dart` 会检查两边 key 一致）。带参数的文案用占位符并在模板里声明 `@key.placeholders`；英文复数用 ICU `plural`；ARB 里单引号要写成 `''`。
- 语言设置是 `AppSettings.language`（`AppLanguage.system / zh / en`，默认跟随系统：中文系统用中文，其他语言一律用英文），由 `lib/l10n/app_locale.dart` 的 `resolveAppLocale` 解析。`MaterialApp` 始终设置明确的 `locale`（zh_CN 或 en_US），中文环境的 CJK 字体回退仍在 `AppTheme.fonts`。
- 取文案：widget 里用 `AppLocalizations.of(context)`；不在 widget 树里的代码（服务层、controller、托盘）通过参数接收 `AppLocalizations`（controller 上是 `l10n` getter），不要用全局可变状态。`lib/ui/format.dart` 的格式化函数都带 `AppLocalizations l` 参数。
- `packages/tokenbar_core`（服务商）里的错误消息、`setupHint`、`ProviderField` 的 label 暂时仍是中文，不在 UI 的翻译范围内。UI 层的 `windowLabel` 只翻译常见窗口词（每周 / 每月 / 每日 / 5 小时 / 本月 / 今日 / 额度），新增常见词时在 `format.dart` 的 `_coreLabel` 里补充。
- 测试里的 `MaterialApp` 要加 `locale`、`supportedLocales` 和 `localizationsDelegates`（参考 `test/widget_test.dart`），否则 `AppLocalizations.of` 会报错。

## 安全规则（必须遵守）

- 不虚构 API；非公开接口必须能在 CodexBar 源码中找到依据，并注明授权方式与限制。
- 不索要、不保存账号密码；不做模拟登录。只用：本机官方客户端已有的登录（只读）、用户主动粘贴的 API Key / Cookie / Token。
- 默认不刷新、不改写其他工具的令牌（刷新会轮换 refresh token，可能把官方客户端踢下线）。Claude 刷新是显式开关，默认关闭。
- 凭证只存系统安全存储（`flutter_secure_storage`），`AccountConfig.toJson()` 不输出 `secret`；不要把凭证写进日志、快照或服务器。
- 服务器只接收额度快照，不接收任何服务商凭证。
- 读取本机用量日志（如 Codex 会话）只取模型名和数字，不读取、不存储、不输出提示词、路径或会话内容；测试用的日志 fixture 必须是合成数据。
- 签名密钥库（`*.jks`、`android/key.properties`）绝不提交；CI 用 `production` Environment 的 secrets（`ANDROID_KEYSTORE_BASE64`、`ANDROID_STORE_PASSWORD`、`ANDROID_KEY_PASSWORD`、`ANDROID_KEY_ALIAS`）。`release.yml` 里的 `EXPECTED_CERT_SHA256` 是公开的证书指纹，换密钥就会让已安装的 APK 无法升级。
- 公开仓库的提交邮箱用 GitHub noreply 地址，不要用个人邮箱；截图里不得有真实邮箱、本机路径、账户信息。

## 平台与发布细节

- CI / 发布矩阵：`ci.yml` 只检查与构建（format、analyze、测试、web 构建、Android debug、Windows x64/arm64 + 安装程序冒烟测试、Linux x64/arm64、macOS、iOS）；`release.yml` 生成**草稿** Release。`production` Environment 保存 Android 签名 secrets。
- macOS / iOS 没有 Apple 开发者账号：macOS 只有 ad-hoc 签名（不公证），iOS 用 `--no-codesign` 后手工打包 `Payload/Runner.app` 成 ipa，只能侧载。macOS 由维护者实测可用；Linux、iOS、Windows arm64 **未在真机验证**，README 与 Release 说明必须保持这个表述。Linux 构建需要 `libgtk-3-dev libsecret-1-dev libayatana-appindicator3-dev` 等（见 workflow）。
- macOS 的 arm64 / x86_64 两个 dmg 是从 Flutter 的通用（universal）构建里用 `lipo -thin` 逐个 Mach-O 裁剪后重新 ad-hoc 签名得到的（Flutter 只能构建通用包）。
- Windows 安装程序：`windows/installer/tokenbar.iss`（Inno Setup，默认按用户安装，`AppId` 的 GUID 永远不要改，否则升级找不到旧安装；简体中文语言文件 `ChineseSimplified.isl` 取自 Inno Setup 官方仓库 `is-6_5_4`）。构建、打包 VC++ 运行库、静默安装 / 卸载冒烟测试都在 `tool/build_windows_installer.ps1`，CI 和发布共用。
- Windows / Linux arm64：Flutter 不发布这两个平台 arm64 的 SDK 压缩包，`windows-11-arm` / `ubuntu-24.04-arm` 构建机上从源码克隆固定 commit（`FLUTTER_COMMIT`）的 Flutter，由它自动引导 arm64 Dart。用 x64 SDK 会构建出 x64 目标，所以工作流里校验了 exe 的 PE 机器类型 / ELF 架构。
- 检查更新：`lib/services/update/`（`UpdateService` 读 `releases/latest`，忽略草稿 / 预发布，只信任 github.com 链接）+ `state/update_controller.dart`。只打开发布页，不自动下载安装。仓库名常量在 `lib/app_info.dart`。
- 仓库简介和话题用 `gh repo edit lwh0630/TokenBar --description ... --add-topic ...` 维护；简介必须写明支持的平台。README 开头的标语不要再写「No server required」之类的绝对表述。

## 坑

- web 构建不能引入 `dart:io` / sqlite：本机访问一律走 `platform/platform.dart` 的条件导入。
- Android 也有 `dart:io`，判断“能否读本机登录”用 `canUseLocalLogins`（= 桌面平台），不要用 `localAccessSupported`。
- `sqlite3` 3.x 使用 build hooks：CLI 用 `dart build cli`；Cursor 的 `state.vscdb` 用只读模式打开（Cursor 运行时也能读）。
- `tray_manager` 固定在 `^0.5.0`（0.8 是不兼容重写）。它在 macOS 上用 `rootBundle.load(iconPath)` 读图标，只支持打包进 App 的资源；运行时生成的托盘图标要绕开它，直接用 `MethodChannel('tray_manager')` 传 `base64Icon`（见 `desktop_io.dart` 的 `_setMacIcon`）。Linux 的 AppIndicator 没有点击事件，托盘面板不可用，只有菜单。
- Android：`flutter_local_notifications` 需要 core library desugaring；项目与 pub 缓存不同盘符时需 `kotlin.incremental=false`（已配置）。
- 通知权限请求放在 `runApp` 之后，否则会卡启动。
- Widget 测试默认平台是 Android；测桌面行为需设置 `debugDefaultTargetPlatformOverride`。
- 测试里创建了 `AppController`（含 `initDemo`）要在测试体内 `dispose`，否则它的 15 秒定时器会触发 “Pending timers” 失败。
- Windows 下用 PowerShell 写文件注意不要带 UTF-8 BOM；PowerShell 双引号字符串里的反引号会变成控制字符、中文引号会破坏解析，写文件优先用编辑工具或单引号 here-string。仓库里文件的换行以 `.gitattributes` 为准（git 会提示 LF/CRLF 转换，无需处理）。
- Windows 的应用控制策略可能拦截未签名的 release exe（`flutter run` 的 debug 版可以运行）。
- `dart format` 会把单行 `if (x) y;` 拆开，随后 `curly_braces_in_flow_control_structures` 报 info：用 `dart fix --apply` 补花括号。
- Dart 的 `String.replaceFirst` 不支持 `$1` 反向引用，要用 `replaceFirstMapped`。
- `FractionallySizedBox` 放在 `Align` 里、子组件是没有 child 的 `DecoratedBox` 时，高度会塌成 0，要设 `heightFactor: 1`（占比条曾因此不可见）。
- 应用图标由 `python tool/gen_icons.py` 统一生成（Pillow 4 倍超采样，改设计只改这一个文件）；托盘图标由 `TrayIconRenderer` 绘制，同样做了超采样抗锯齿。不要手改各平台的图标文件。
- 中文字体：Flutter 在 Windows 的默认字体 Segoe UI 没有汉字，必须在 `AppTheme.fonts` 里显式写 CJK 回退（微软雅黑），并让 `MaterialApp` 始终设置 `locale`（中文为 zh_CN，英文为 en_US，见「多语言」一节；需要 `flutter_localizations`），否则会落到奇怪的字体。
- 托盘面板与主窗口是同一个窗口：`DesktopIntegration.panelMode` 为 true 时 `MaterialApp.builder` 显示 `TrayPanel`，主界面用 `Offstage` 保留状态；窗口失焦自动隐藏。面板高度由 `TrayPanel.heightFor` 估算，改面板布局要同步改它。面板在 Navigator 之上，没有自带的 `Overlay`，所以 `main.dart` 里要给它包一层 `Overlay`，否则 `Tooltip` 报 “No Overlay widget found”（`test/tray_panel_test.dart` 守着这一点）。`token_bar.exe --panel`（或 `flutter run -d windows --dart-entrypoint-args=--panel`）可直接打开面板用于调试。
- 托盘图标 / macOS 菜单栏文字跟随哪个账户由 `AppSettings.trayAccountId` 决定（空 = 自动取剩余最少的账户；设置页下拉框和托盘右键“托盘显示”子菜单都能改，菜单项 key 为 `tray:<accountId>`）。macOS 的 `AppDelegate.applicationShouldTerminateAfterLastWindowClosed` 必须返回 `false`，否则关窗口会直接退出而不是留在菜单栏（真正退出走 `DesktopIntegration.quit`）。改 `DesktopIntegration` 的签名时，`desktop_io.dart` 和 `desktop_stub.dart` 要一起改。
- 历史图表（`lib/ui/widgets/history_chart.dart`）有三个视图，只显示有数据的：「模型」（`AppController.modelUsage` 返回的 `ModelUsageSeries`，null 或空就不出现；tokens / 费用二选一，费用仅当有 `costUsd`）、「额度窗口」（`UsagePoint.used`）、「花费」（`UsagePoint.spend`）；默认模型 > 额度窗口 > 花费。额度/花费按桶求增量，数值下降视为窗口重置（`lib/ui/history_series.dart`）。纯函数在 `lib/ui/chart_math.dart`：`alignedBucketStarts`（桶对齐到本地整点 / 0·6·12·18 点 / 本地零点，横轴始终铺满范围，空桶也在）、`buildModelHistory`、`mergeTailSeries`（超过调色板 `seriesPalette` 的小项并入末尾“其他”）、`filterSeries` / `toggleHidden`（图例隐藏，全隐藏即恢复全部）、`niceScale`、`abbreviateNumber`、`pickAxisLabels`；都有单元测试（`test/chart_math_test.dart`）。
- 柱状图 `lib/ui/widgets/stacked_bar_chart.dart` 是自绘的 `CustomPainter`（已不再依赖 fl_chart）：柱宽 ≤ 28 px、段间留 1.8 px 缝、只有最上面一段有顶部圆角、入场动画靠 `animationKey` 变化重播；悬停（鼠标）/ 点按（触摸，再点收起）显示的提示卡片用 `CustomSingleChildLayout` 放在柱子旁边（靠右翻到左侧），不盖住柱子也不出图表。颜色按 `colorOrder`（模型按全范围 tokens 排序，窗口 / 花费线按 id 排序）固定，同一项在图例 / 列表 / 提示里一致；改调色板只改 `lib/app/theme.dart` 的 `seriesPalette` / `seriesOtherColor`。汇总列表、图例 chips 和空状态都在 `history_chart.dart`；组件测试在 `test/history_chart_test.dart`（用 `HistoryChart.now` 固定时钟，鼠标悬停用 `PointerDeviceKind.mouse` 手势扫描）。
- 按模型用量（历史页堆叠柱状图）：`UsageProvider.fetchModelUsage()` 钩子（默认 null）→ `ModelUsageSeries`（模型 × 时间桶）；`AppController.modelUsage()` 只回答本机账户（演示模式回答 `DemoData.modelUsage`），带 2 分钟内存缓存，失败一律返回 null。桶宽由 `modelUsageBucketWidth` 决定：范围 ≤ 36 小时用 1 小时桶，否则 1 天桶，按本地时区对齐（`ModelUsageAggregator`）。
  - Cursor：复用 `cursor_usage_events.dart` 的 `get-filtered-usage-events`（本机登录和 Cookie 都行，最多 20 页，凑不齐返回 null）。
  - Codex：只在桌面端（`localAccessSupported` + `canUseLocalLogins`）读 `<CODEX_HOME 或 AccountConfig.homeDir>/sessions/YYYY/MM/DD/*.jsonl` 与 `archived_sessions/*.jsonl`，逐行流式解析，语义对照 CodexBar `CostUsageScanner`（`token_count` 的 `last_token_usage` / `total_token_usage`，模型取最近的 `turn_context`）。**只读，只取模型名和数字。**费用只按 `codex_pricing.dart`（抄自 CodexBar 价格表）估算，表里没有的模型 `costUsd` 为 null，不编造价格。
- 不接入的服务（需要请求签名、浏览器 Cookie 库解密、macOS 钥匙串、或要发真实推理请求来探测额度）列在 README 的“暂不支持”里，新增前先看一眼。
