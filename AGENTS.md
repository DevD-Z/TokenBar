# TokenBar — Agent 指南

TokenBar 是参考 [CodexBar](https://github.com/steipete/CodexBar) 的开源跨平台 AI 额度监控，Flutter + Dart。
用户在客户端里添加某个服务（本机登录 / API Key / Cookie），直接向服务商查询额度。服务器是可选组件，只用于跨设备同步快照。

回复用户请使用简体中文。

## 目录

```
lib/                          Flutter 应用（provider + ChangeNotifier）
  state/app_controller.dart   账户、刷新、同步、自动检测本机登录
  state/settings.dart         AppSettings、SyncMode、平台判断（canUseLocalLogins）
  services/                   持久化（secure storage）、托盘/桌面、通知、小组件桥、历史
  ui/pages/accounts_page.dart 账户列表 + 由 ProviderField 生成的编辑器 + 服务搜索选择器
  ui/format.dart              中文标签、倒计时、金额格式
packages/tokenbar_core/       纯 Dart：模型、各服务抓取、同步客户端、托盘图标渲染
  lib/src/models/             AccountConfig、UsageSnapshot、RateWindow、Credits
  lib/src/providers/          provider.dart（基类）、fields.dart、http_support.dart、registry.dart、<id>/...
  lib/src/platform/           platform_io.dart / platform_stub.dart（条件导入，web 无 dart:io）
  test/                       单元测试 + fixtures/（真实响应样本）
packages/tokenbar_server/     CLI（usage / collect / serve）与可选同步服务器（shelf + sqlite）
android/ ios/ macos/ ...      平台工程；Android 原生小组件、iOS WidgetKit 源码
third_party/CodexBar/         参考源码（.gitignore，不提交）
third_party/provider_specs/   从 CodexBar 提取的接口规格（不提交，实现新服务时参考）
```

## 常用命令

```bash
flutter pub get
flutter analyze                 # 根目录，覆盖应用
flutter test                    # 应用测试
cd packages/tokenbar_core && dart analyze && dart test
cd packages/tokenbar_server && dart test
dart format --output=none --set-exit-if-changed lib test packages # CI 会检查格式（行宽 100，见 analysis_options.yaml）
dart run packages/tokenbar_server/bin/tokenbar.dart usage -p cursor --json   # 真实抓取验证
flutter build windows | web | apk
cd packages/tokenbar_server && dart build cli -o ../../build/server         # 不要用 dart compile exe
```

完成改动后至少跑 analyze + 格式检查 + 相关测试，三处都要绿。

演示模式：`flutter run --dart-define=TOKENBAR_DEMO=true`（数据在 `lib/demo/demo_data.dart`，内存存储，不碰真实凭证；README 截图用它拍：英文放 `docs/screenshots/`，中文放 `docs/screenshots/zh/`，用 `--dart-define=TOKENBAR_DEMO_LANG=en|zh` 固定语言；托盘面板加 `--dart-entrypoint-args=--panel`；Cursor / Codex 的分模型用量也是虚构的，见 `DemoData.modelUsage`）。
加 `--dart-define=TOKENBAR_PANEL=true` 直接打开托盘面板。截图里不得出现真实邮箱、本机路径（演示模式已隐藏路径）。

## 核心概念

- `UsageProvider`（`provider.dart`）：`id`、`displayName`、`brandColor`、`supportedSources`、`setupHint`、`fields`、`fetch()`。
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
5. 更新 `README.md` 的服务表。

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
- 签名密钥库（`*.jks`、`android/key.properties`）绝不提交；CI 用 `production` Environment 的 secrets（`ANDROID_KEYSTORE_BASE64`、`ANDROID_STORE_PASSWORD`、`ANDROID_KEY_PASSWORD`、`ANDROID_KEY_ALIAS`）。`release.yml` 里的 `EXPECTED_CERT_SHA256` 是公开的证书指纹，换密钥就会让已安装的 APK 无法升级。
- 公开仓库的提交邮箱用 GitHub noreply 地址，不要用个人邮箱。

## 发布与更新

- 发布：推送 `vX.Y.Z` 标签触发 `.github/workflows/release.yml`，生成**草稿** Release（Android 分 ABI 签名 APK + Windows x64 / arm64 安装程序（Inno Setup）+ Linux x64 / arm64 tar.gz + macOS arm64 / x86_64 dmg + iOS 未签名 ipa + `SHA256SUMS.txt`），手动发布后才对外可见。`ci.yml` 只检查与构建（含 Windows arm64 / Linux / macOS / iOS）。
- macOS / iOS 没有 Apple 开发者账号：macOS 只有 ad-hoc 签名（不公证），iOS 用 `--no-codesign` 后手工打包 `Payload/Runner.app` 成 ipa，只能侧载。macOS 由维护者实测可用；Linux、iOS、Windows arm64 **未在真机验证**，README 与 Release 说明必须保持这个表述。Linux 构建需要 `libgtk-3-dev libsecret-1-dev libayatana-appindicator3-dev` 等（见 workflow）。
- macOS 的 arm64 / x86_64 两个 dmg 是从 Flutter 的通用（universal）构建里用 `lipo -thin` 逐个 Mach-O 裁剪后重新 ad-hoc 签名得到的（Flutter 只能构建通用包）。
- Windows 安装程序：`windows/installer/tokenbar.iss`（Inno Setup，默认按用户安装，`AppId` 的 GUID 永远不要改，否则升级找不到旧安装；简体中文语言文件 `ChineseSimplified.isl` 取自 Inno Setup 官方仓库 `is-6_5_4`）。构建、打包 VC++ 运行库、静默安装 / 卸载冒烟测试都在 `tool/build_windows_installer.ps1`，CI 和发布共用。
- Windows / Linux arm64：Flutter 不发布这两个平台 arm64 的 SDK 压缩包，`windows-11-arm` / `ubuntu-24.04-arm` 构建机上从源码克隆固定 commit（`FLUTTER_COMMIT`）的 Flutter，由它自动引导 arm64 Dart。用 x64 SDK 会构建出 x64 目标，所以工作流里校验了 exe 的 PE 机器类型。升级 Flutter 版本时 `FLUTTER_VERSION` 和 `FLUTTER_COMMIT` 要一起改。
- `tray_manager` 0.5.0 在 macOS 上用 `rootBundle.load(iconPath)` 读图标，只支持打包进 App 的资源；运行时生成的托盘图标要绕开它，直接用 `MethodChannel('tray_manager')` 传 `base64Icon`（见 `desktop_io.dart` 的 `_setMacIcon`）。Linux 的 AppIndicator 没有点击事件，托盘面板不可用，只有菜单。
- 检查更新：`lib/services/update/`（`UpdateService` 读 `releases/latest`，忽略草稿 / 预发布，只信任 github.com 链接）+ `state/update_controller.dart`。只打开发布页，不自动下载安装。仓库名常量在 `lib/app_info.dart`。
- 版本号：`pubspec.yaml` 的 `version` 是开发默认值，CI 用 tag 覆盖 `--build-name`，`--build-number` 取 `github.run_number`。

## 坑

- web 构建不能引入 `dart:io` / sqlite：本机访问一律走 `platform/platform.dart` 的条件导入。
- Android 也有 `dart:io`，判断“能否读本机登录”用 `canUseLocalLogins`（= 桌面平台），不要用 `localAccessSupported`。
- `sqlite3` 3.x 使用 build hooks：CLI 用 `dart build cli`；Cursor 的 `state.vscdb` 用只读模式打开（Cursor 运行时也能读）。
- `tray_manager` 固定在 `^0.5.0`（0.8 是不兼容重写）。
- Android：`flutter_local_notifications` 需要 core library desugaring；项目与 pub 缓存不同盘符时需 `kotlin.incremental=false`（已配置）。
- 通知权限请求放在 `runApp` 之后，否则会卡启动。
- Widget 测试默认平台是 Android；测桌面行为需设置 `debugDefaultTargetPlatformOverride`。
- Windows 下用 PowerShell 写文件注意不要带 UTF-8 BOM。
- Windows 的应用控制策略可能拦截未签名的 release exe（`flutter run` 的 debug 版可以运行）。
- `dart format` 会把单行 `if (x) y;` 拆开，随后 `curly_braces_in_flow_control_structures` 报 info：用 `dart fix --apply` 补花括号。
- Dart 的 `String.replaceFirst` 不支持 `$1` 反向引用，要用 `replaceFirstMapped`。
- 应用图标由 `python tool/gen_icons.py` 统一生成（Pillow 4 倍超采样，改设计只改这一个文件）；托盘图标由 `TrayIconRenderer` 绘制，同样做了超采样抗锯齿。不要手改各平台的图标文件。
- 中文字体：Flutter 在 Windows 的默认字体 Segoe UI 没有汉字，必须在 `AppTheme.fonts` 里显式写 CJK 回退（微软雅黑），并让 `MaterialApp` 始终设置 `locale`（中文为 zh_CN，英文为 en_US，见上面的多语言一节；需要 `flutter_localizations`），否则会落到奇怪的字体。
- 托盘面板与主窗口是同一个窗口：`DesktopIntegration.panelMode` 为 true 时 `MaterialApp.builder` 显示 `TrayPanel`，主界面用 `Offstage` 保留状态；窗口失焦自动隐藏。面板高度由 `TrayPanel.heightFor` 估算，改面板布局要同步改它。面板在 Navigator 之上，没有自带的 `Overlay`，所以 `main.dart` 里要给它包一层 `Overlay`，否则 `Tooltip` 报 “No Overlay widget found”（`test/tray_panel_test.dart` 守着这一点）。`token_bar.exe --panel`（或 `flutter run -d windows --dart-entrypoint-args=--panel`）可直接打开面板用于调试。
- 托盘图标 / macOS 菜单栏文字跟随哪个账户由 `AppSettings.trayAccountId` 决定（空 = 自动取剩余最少的账户；设置页下拉框和托盘右键“托盘显示”子菜单都能改，菜单项 key 为 `tray:<accountId>`）。macOS 的 `AppDelegate.applicationShouldTerminateAfterLastWindowClosed` 必须返回 `false`，否则关窗口会直接退出而不是留在菜单栏（真正退出走 `DesktopIntegration.quit`）。
- 历史图表（`lib/ui/widgets/history_chart.dart`）有三个视图，只显示有数据的：「模型」（`AppController.modelUsage` 返回的 `ModelUsageSeries`，null 或空就不出现；tokens / 费用二选一，费用仅当有 `costUsd`）、「额度窗口」（`UsagePoint.used`）、「花费」（`UsagePoint.spend`）；默认模型 > 额度窗口 > 花费。额度/花费按桶求增量，数值下降视为窗口重置（`lib/ui/history_series.dart`）。纯函数在 `lib/ui/chart_math.dart`：`alignedBucketStarts`（桶对齐到本地整点 / 0·6·12·18 点 / 本地零点，横轴始终铺满范围，空桶也在）、`buildModelHistory`、`mergeTailSeries`（超过调色板 `seriesPalette` 的小项并入末尾“其他”）、`filterSeries` / `toggleHidden`（图例隐藏，全隐藏即恢复全部）、`niceScale`、`abbreviateNumber`、`pickAxisLabels`；都有单元测试（`test/chart_math_test.dart`）。
- 柱状图 `lib/ui/widgets/stacked_bar_chart.dart` 是自绘的 `CustomPainter`（已不再依赖 fl_chart）：柱宽 ≤ 28 px、段间留 1.8 px 缝、只有最上面一段有顶部圆角、入场动画靠 `animationKey` 变化重播；悬停（鼠标）/ 点按（触摸，再点收起）显示的提示卡片用 `CustomSingleChildLayout` 放在柱子旁边（靠右翻到左侧），不盖住柱子也不出图表。颜色按 `colorOrder`（模型按全范围 tokens 排序，窗口 / 花费线按 id 排序）固定，同一项在图例 / 列表 / 提示里一致；改调色板只改 `lib/app/theme.dart` 的 `seriesPalette` / `seriesOtherColor`。汇总列表、图例 chips 和空状态都在 `history_chart.dart`；组件测试在 `test/history_chart_test.dart`（用 `HistoryChart.now` 固定时钟，鼠标悬停用 `PointerDeviceKind.mouse` 手势扫描）。
- 按模型用量（历史页堆叠柱状图）：`UsageProvider.fetchModelUsage()` 钩子（默认 null）→ `ModelUsageSeries`（模型 × 时间桶）；`AppController.modelUsage()` 只回答本机账户，带 2 分钟内存缓存，失败一律返回 null。桶宽由 `modelUsageBucketWidth` 决定：范围 ≤ 36 小时用 1 小时桶，否则 1 天桶，按本地时区对齐（`ModelUsageAggregator`）。
  - Cursor：复用 `cursor_usage_events.dart` 的 `get-filtered-usage-events`（本机登录和 Cookie 都行，最多 20 页，凑不齐返回 null）。
  - Codex：只在桌面端（`localAccessSupported` + `canUseLocalLogins`）读 `<CODEX_HOME 或 AccountConfig.homeDir>/sessions/YYYY/MM/DD/*.jsonl` 与 `archived_sessions/*.jsonl`，逐行流式解析，语义对照 CodexBar `CostUsageScanner`（`token_count` 的 `last_token_usage` / `total_token_usage`，模型取最近的 `turn_context`）。**只读，只取模型名和数字**，不读取、不存储、不输出提示词、路径或会话内容；测试用的日志 fixture 必须是合成数据。费用只按 `codex_pricing.dart`（抄自 CodexBar 价格表）估算，表里没有的模型 `costUsd` 为 null，不编造价格。
- 不接入的服务（需要请求签名、浏览器 Cookie 库解密、macOS 钥匙串、或要发真实推理请求来探测额度）列在 README 的“暂不支持”里，新增前先看一眼。
