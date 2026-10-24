import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_info.dart';
import '../../state/app_controller.dart';
import '../../state/settings.dart';
import '../../state/update_controller.dart';
import '../update_dialog.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<AppController>();
    final s = c.settings;
    void update(AppSettings next) => c.updateSettings(next);

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Section('外观', [
                    ListTile(
                      title: const Text('主题'),
                      trailing: SegmentedButton<ThemeMode>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(value: ThemeMode.system, label: Text('跟随系统')),
                          ButtonSegment(value: ThemeMode.light, label: Text('浅色')),
                          ButtonSegment(value: ThemeMode.dark, label: Text('深色')),
                        ],
                        selected: {s.themeMode},
                        onSelectionChanged: (v) => update(s.copyWith(themeMode: v.first)),
                      ),
                    ),
                  ]),
                  _Section('刷新', [
                    ListTile(
                      title: const Text('自动刷新间隔'),
                      subtitle: const Text('连续失败时会自动退避，最长 30 分钟'),
                      trailing: DropdownButton<int>(
                        value: s.refreshMinutes,
                        underline: const SizedBox.shrink(),
                        items: const [
                          1,
                          2,
                          5,
                          10,
                          15,
                          30,
                          60,
                        ].map((m) => DropdownMenuItem(value: m, child: Text('$m 分钟'))).toList(),
                        onChanged: (v) => update(s.copyWith(refreshMinutes: v)),
                      ),
                    ),
                  ]),
                  _Section('通知', [
                    SwitchListTile(
                      title: const Text('低额度提醒'),
                      value: s.notificationsEnabled,
                      onChanged: (v) => update(s.copyWith(notificationsEnabled: v)),
                    ),
                    ListTile(
                      enabled: s.notificationsEnabled,
                      title: const Text('提醒阈值（剩余）'),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Wrap(
                          spacing: 8,
                          children: [
                            for (final t in const [50, 30, 20, 10, 5])
                              FilterChip(
                                label: Text('$t%'),
                                selected: s.thresholds.contains(t),
                                onSelected: !s.notificationsEnabled
                                    ? null
                                    : (on) {
                                        final next = {...s.thresholds};
                                        on ? next.add(t) : next.remove(t);
                                        update(s.copyWith(thresholds: next.toList()..sort()));
                                      },
                              ),
                          ],
                        ),
                      ),
                    ),
                    SwitchListTile(
                      title: const Text('额度重置提醒'),
                      subtitle: const Text('额度较低时重置后通知'),
                      value: s.notifyOnReset,
                      onChanged: s.notificationsEnabled
                          ? (v) => update(s.copyWith(notifyOnReset: v))
                          : null,
                    ),
                  ]),
                  const _SyncSection(),
                  if (isDesktopPlatform)
                    _Section('数据源', [
                      SwitchListTile(
                        title: const Text('允许调用 Codex CLI 兜底'),
                        subtitle: const Text('OAuth 令牌过期时通过 `codex app-server` 读取额度（由 CLI 负责刷新登录）'),
                        value: s.allowCliFallback,
                        onChanged: (v) => update(s.copyWith(allowCliFallback: v)),
                      ),
                      SwitchListTile(
                        title: const Text('允许 TokenBar 刷新 Claude 令牌'),
                        subtitle: const Text(
                          '令牌过期时由 TokenBar 刷新并写回 ~/.claude/.credentials.json。'
                          '刷新会轮换 refresh token，若 Claude Code 正在运行可能需要重新登录。默认关闭。',
                        ),
                        value: s.allowClaudeRefresh,
                        onChanged: (v) => update(s.copyWith(allowClaudeRefresh: v)),
                      ),
                    ]),
                  if (isDesktopPlatform)
                    _Section('桌面', [
                      SwitchListTile(
                        title: const Text('开机自动启动'),
                        value: s.launchAtStartup,
                        onChanged: (v) => update(s.copyWith(launchAtStartup: v)),
                      ),
                      SwitchListTile(
                        title: const Text('关闭窗口时最小化到托盘'),
                        value: s.minimizeToTray,
                        onChanged: (v) => update(s.copyWith(minimizeToTray: v)),
                      ),
                    ]),
                  const _AboutSection(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Version, update check and project links.
class _AboutSection extends StatelessWidget {
  const _AboutSection();

  static String _status(UpdateController u) => switch (u.status) {
    UpdateStatus.idle => '',
    UpdateStatus.checking => '正在检查…',
    UpdateStatus.upToDate => '已是最新版本',
    UpdateStatus.available => '发现新版本 ${u.release?.tag ?? ''}',
    UpdateStatus.error => switch (u.errorCode) {
      'rate_limit' => '检查失败：请求过于频繁，请稍后再试',
      'network' => '检查失败：无法连接 GitHub',
      _ => '检查失败：GitHub 返回了无法识别的数据',
    },
  };

  @override
  Widget build(BuildContext context) {
    final c = context.watch<AppController>();
    final u = context.watch<UpdateController>();
    final theme = Theme.of(context);
    final status = _status(u);
    final available = u.status == UpdateStatus.available && u.release != null;
    final version = u.currentVersion.isEmpty ? '' : ' ${u.currentVersion}';
    return _Section('关于', [
      ListTile(
        title: Text('TokenBar$version'),
        subtitle: status.isEmpty
            ? null
            : Text(
                status,
                style: TextStyle(
                  color: u.status == UpdateStatus.error
                      ? theme.colorScheme.error
                      : available
                      ? theme.colorScheme.primary
                      : null,
                ),
              ),
        trailing: available
            ? FilledButton(
                onPressed: () => showUpdateDialog(context, u, u.release!),
                child: const Text('查看更新'),
              )
            : OutlinedButton(
                onPressed: u.status == UpdateStatus.checking ? null : () => u.check(manual: true),
                child: u.status == UpdateStatus.checking
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('检查更新'),
              ),
      ),
      SwitchListTile(
        title: const Text('启动时自动检查更新'),
        subtitle: const Text('仅向 GitHub 请求最新版本号，不发送任何账号或使用数据'),
        value: c.settings.autoCheckUpdates,
        onChanged: (v) => c.updateSettings(c.settings.copyWith(autoCheckUpdates: v)),
      ),
      ListTile(
        title: const Text('项目主页'),
        subtitle: const Text('github.com/$kUpdateRepo'),
        trailing: const Icon(Icons.open_in_new, size: 18),
        onTap: () => openReleasePage(kRepoUrl),
      ),
      const ListTile(
        subtitle: Text(
          '开源跨平台 AI 额度监控（MIT）。数据获取方式参考 steipete/CodexBar。'
          '直接向各服务商官方接口查询，复用本机客户端的登录状态（只读），不收集账号密码；'
          '可选的自建服务器只保存额度快照，不保存令牌。',
        ),
      ),
    ]);
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.children);

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
            child: Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary),
            ),
          ),
          Card(child: Column(children: children)),
        ],
      ),
    );
  }
}

class _SyncSection extends StatefulWidget {
  const _SyncSection();

  @override
  State<_SyncSection> createState() => _SyncSectionState();
}

class _SyncSectionState extends State<_SyncSection> {
  late final TextEditingController _url;
  late final TextEditingController _token;
  late final TextEditingController _device;
  String? _testResult;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppController>().settings;
    _url = TextEditingController(text: s.serverUrl);
    _token = TextEditingController(text: s.serverToken);
    _device = TextEditingController(text: s.deviceName);
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    _device.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final c = context.read<AppController>();
    await c.updateSettings(
      c.settings.copyWith(
        serverUrl: _url.text.trim(),
        serverToken: _token.text.trim(),
        deviceName: _device.text.trim(),
      ),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已保存同步设置')));
    }
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final error = await context.read<AppController>().testServer(_url.text, _token.text);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = error == null ? '连接成功' : '连接失败：$error';
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<AppController>();
    final s = c.settings;
    final theme = Theme.of(context);
    final modes = kIsWeb
        ? [SyncMode.server]
        : isDesktopPlatform
        ? SyncMode.values
        : [SyncMode.local, SyncMode.server];
    final content = <Widget>[
      if (modes.length > 1)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: SegmentedButton<SyncMode>(
            showSelectedIcon: false,
            segments: [for (final m in modes) ButtonSegment(value: m, label: Text(m.label))],
            selected: {s.syncMode},
            onSelectionChanged: (v) => c.updateSettings(s.copyWith(syncMode: v.first)),
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Text(switch (s.syncMode) {
          SyncMode.local => '所有账户都由本机直接向官方查询，不需要服务器。',
          SyncMode.server =>
            kIsWeb ? '显示各设备推送到本服务器的额度数据。' : '在本机账户之外，再显示其他设备推送到自建服务器的账户（例如电脑上的 Codex / Claude）。',
          SyncMode.localPush => '把本机查询结果推送到自建服务器，供手机和网页查看；同时显示服务器上其他设备的账户。',
        }, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ),
      if (s.syncMode.usesServer)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _url,
                decoration: const InputDecoration(
                  labelText: '服务器地址',
                  hintText: 'https://tokenbar.example.com',
                ),
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _token,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: '访问令牌',
                  helperText: s.syncMode == SyncMode.localPush
                      ? '推送需要管理员令牌 (TOKENBAR_TOKEN)'
                      : '只读令牌或管理员令牌',
                ),
              ),
              if (s.syncMode == SyncMode.localPush) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _device,
                  decoration: const InputDecoration(labelText: '设备名称', hintText: '例如：办公室电脑'),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  FilledButton(onPressed: _save, child: const Text('保存')),
                  const SizedBox(width: 8),
                  OutlinedButton(onPressed: _testing ? null : _test, child: const Text('测试连接')),
                  const SizedBox(width: 12),
                  if (_testing)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  if (_testResult != null)
                    Expanded(
                      child: Text(
                        _testResult!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _testResult == '连接成功'
                              ? theme.colorScheme.primary
                              : theme.colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
    ];
    if (kIsWeb) return _Section('服务器', content);
    return _Section('服务器同步（可选）', [
      ExpansionTile(
        initiallyExpanded: s.syncMode.usesServer,
        shape: const Border(),
        collapsedShape: const Border(),
        title: Text(s.syncMode.usesServer ? '已启用：${s.syncMode.label}' : '未启用'),
        subtitle: Text(
          '不需要服务器也能使用。只有想在手机或网页上查看电脑上的额度时，才需要自建 TokenBar 服务器。',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        children: content,
      ),
    ]);
  }
}
