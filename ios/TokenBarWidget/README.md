# iOS 桌面小组件

WidgetKit 扩展需要在 macOS 的 Xcode 里添加一次 target（Flutter 无法自动生成）：

1. `open ios/Runner.xcworkspace`
2. File → New → Target → Widget Extension，名称 `TokenBarWidget`，不勾选 Live Activity / Configuration Intent。
3. 用本目录的 `TokenBarWidget.swift` 替换 Xcode 生成的同名文件，删除其余模板文件。
4. Runner 与 TokenBarWidget 两个 target 都在 Signing & Capabilities 中添加 App Groups：`group.dev.tokenbar.app`。
5. TokenBarWidget 的最低系统版本设为 iOS 17（使用了 `containerBackground`）。

App 每次刷新后通过 `home_widget` 写入共享数据并调用 `HomeWidget.updateWidget(iOSName: 'TokenBarWidget')`。
