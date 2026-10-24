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

演示模式：`flutter run --dart-define=TOKENBAR_DEMO=true`（数据在 `lib/demo/demo_data.dart`，内存存储，不碰真实凭证；README 截图用它拍）。
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

## 安全规则（必须遵守）

- 不虚构 API；非公开接口必须能在 CodexBar 源码中找到依据，并注明授权方式与限制。
- 不索要、不保存账号密码；不做模拟登录。只用：本机官方客户端已有的登录（只读）、用户主动粘贴的 API Key / Cookie / Token。
- 默认不刷新、不改写其他工具的令牌（刷新会轮换 refresh token，可能把官方客户端踢下线）。Claude 刷新是显式开关，默认关闭。
- 凭证只存系统安全存储（`flutter_secure_storage`），`AccountConfig.toJson()` 不输出 `secret`；不要把凭证写进日志、快照或服务器。
- 服务器只接收额度快照，不接收任何服务商凭证。
- 签名密钥库（`*.jks`、`android/key.properties`）绝不提交；CI 用 `production` Environment 的 secrets（`ANDROID_KEYSTORE_BASE64`、`ANDROID_STORE_PASSWORD`、`ANDROID_KEY_PASSWORD`、`ANDROID_KEY_ALIAS`）。`release.yml` 里的 `EXPECTED_CERT_SHA256` 是公开的证书指纹，换密钥就会让已安装的 APK 无法升级。
- 公开仓库的提交邮箱用 GitHub noreply 地址，不要用个人邮箱。

## 发布与更新

- 发布：推送 `vX.Y.Z` 标签触发 `.github/workflows/release.yml`，生成**草稿** Release（Android 分 ABI 签名 APK + Windows zip + Linux tar.gz + macOS dmg + iOS 未签名 ipa + `SHA256SUMS.txt`），手动发布后才对外可见。`ci.yml` 只检查与构建（含 Linux / macOS / iOS）。
- macOS / iOS 没有 Apple 开发者账号：macOS 只有 ad-hoc 签名（不公证），iOS 用 `--no-codesign` 后手工打包 `Payload/Runner.app` 成 ipa，只能侧载。这三个平台**未在真机验证**，README 与 Release 说明必须保持这个表述。Linux 构建需要 `libgtk-3-dev libsecret-1-dev libayatana-appindicator3-dev` 等（见 workflow）。
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
- 中文字体：Flutter 在 Windows 的默认字体 Segoe UI 没有汉字，必须在 `AppTheme.fonts` 里显式写 CJK 回退（微软雅黑），并在 `MaterialApp` 设 `locale: zh_CN`（需要 `flutter_localizations`），否则会落到奇怪的字体。
- 托盘面板与主窗口是同一个窗口：`DesktopIntegration.panelMode` 为 true 时 `MaterialApp.builder` 显示 `TrayPanel`，主界面用 `Offstage` 保留状态；窗口失焦自动隐藏。面板高度由 `TrayPanel.heightFor` 估算，改面板布局要同步改它。`token_bar.exe --panel`（或 `flutter run -d windows --dart-entrypoint-args=--panel`）可直接打开面板用于调试。
- 历史图表分项来自 `UsagePoint.used`（窗口已用 %）和 `UsagePoint.spend`（`Credits.used`），按桶求增量，数值下降视为窗口重置；计算在 `lib/ui/history_series.dart`，有单元测试。
- 不接入的服务（需要请求签名、浏览器 Cookie 库解密、macOS 钥匙串、或要发真实推理请求来探测额度）列在 README 的“暂不支持”里，新增前先看一眼。
