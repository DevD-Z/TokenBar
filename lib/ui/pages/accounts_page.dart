import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tokenbar_core/tokenbar_core.dart';

import '../../demo/demo_data.dart';
import '../../state/app_controller.dart';
import '../../state/settings.dart';
import '../format.dart';
import '../widgets/provider_badge.dart';

class AccountsPage extends StatelessWidget {
  const AccountsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<AppController>();
    final theme = Theme.of(context);
    final local = c.settings.syncMode.fetchesLocally;
    final remote = c.snapshots.where((s) => !c.isLocalAccount(s.accountId)).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('账户')),
      floatingActionButton: local
          ? FloatingActionButton.extended(
              onPressed: () => showAccountEditor(context),
              icon: const Icon(Icons.add),
              label: const Text('添加账户'),
            )
          : null,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          if (local) ...[
            _SectionTitle('我的账户', trailing: c.accounts.length > 1 ? '拖动排序' : null),
            if (canUseLocalLogins)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () async {
                    final added = await c.addDetectedAccounts();
                    if (added.isNotEmpty) unawaited(c.refresh());
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(added.isEmpty ? '没有发现新的本机登录' : '已添加：${added.join('、')}'),
                      ),
                    );
                  },
                  icon: const Icon(Icons.search, size: 18),
                  label: const Text('检测本机已登录的服务'),
                ),
              ),
            if (c.accounts.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '还没有账户',
                  style: theme.textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              ),
            Card(
              child: ReorderableListView(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: true,
                onReorderItem: c.moveAccount,
                children: [
                  for (final a in c.accounts)
                    ListTile(
                      key: ValueKey(a.id),
                      leading: ProviderBadge(providerId: a.providerId),
                      title: Text(a.label),
                      subtitle: Text(_describe(a), maxLines: 2, overflow: TextOverflow.ellipsis),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Switch(
                            value: a.enabled,
                            onChanged: (v) => c.updateAccount(a.copyWith(enabled: v)),
                          ),
                          PopupMenuButton<String>(
                            onSelected: (v) async {
                              if (v == 'edit') showAccountEditor(context, existing: a);
                              if (v == 'delete' && await _confirmDelete(context, a.label)) {
                                await c.removeAccount(a.id);
                              }
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 'edit', child: Text('编辑')),
                              PopupMenuItem(value: 'delete', child: Text('删除')),
                            ],
                          ),
                          const SizedBox(width: 24),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
          if (c.settings.syncMode.usesServer) ...[
            const SizedBox(height: 16),
            _SectionTitle('服务器上的账户', trailing: c.settings.serverConfigured ? null : '未配置服务器'),
            if (remote.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '服务器上暂无其他设备推送的账户。',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              Card(
                child: Column(
                  children: [
                    for (final s in remote)
                      ListTile(
                        leading: ProviderBadge(providerId: s.providerId),
                        title: Text(s.accountLabel ?? s.accountId),
                        subtitle: Text(
                          [
                            planLabel(s.plan),
                            if (s.origin != null) '来自 ${s.origin}',
                            '更新于 ${agoZh(s.fetchedAt, DateTime.now())}',
                          ].where((e) => e.isNotEmpty).join(' · '),
                        ),
                      ),
                  ],
                ),
              ),
          ],
          if (local && !isDesktopPlatform)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '填写 API Key 或粘贴 Cookie 的服务可以直接在手机上查询。Codex / Claude 等只在电脑上登录的服务，'
                '想在手机上看，可在设置里开启可选的服务器同步。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _describe(AccountConfig a) {
    final provider = ProviderRegistry.instance.byId(a.providerId);
    final parts = <String>[provider?.displayName ?? a.providerId];
    if (a.sourceType == SourceType.apiKey) {
      parts.add(sourceTypeLabel(a.providerId, a.sourceType));
    } else {
      // Demo mode never shows real paths (they contain the OS user name).
      final home = kDemoMode
          ? null
          : switch (a.providerId) {
              'codex' => resolveCodexHome(a.homeDir),
              'claude' => resolveClaudeConfigDir(a.homeDir),
              'cursor' => cursorStateDbPath(a.homeDir),
              _ => a.homeDir,
            };
      parts.add(a.homeDir == null ? '默认登录${home == null ? '' : '（$home）'}' : a.homeDir!);
    }
    return parts.join(' · ');
  }

  static Future<bool> _confirmDelete(BuildContext context, String label) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('删除账户'),
          content: Text('确定删除"$label"？本地历史记录也会被删除，CLI 登录不受影响。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
          ],
        ),
      ) ??
      false;
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, {this.trailing});

  final String text;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary),
            ),
          ),
          if (trailing != null)
            Text(
              trailing!,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}

Future<void> showAccountEditor(BuildContext context, {AccountConfig? existing}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _AccountEditor(existing: existing),
  );
}

List<SourceType> _sourcesOf(UsageProvider p) =>
    p.supportedSources.where((s) => s != SourceType.localCli || canUseLocalLogins).toList();

/// Providers that can be added on this device.
List<UsageProvider> get availableProviders =>
    ProviderRegistry.instance.all.where((p) => _sourcesOf(p).isNotEmpty).toList();

class _AccountEditor extends StatefulWidget {
  const _AccountEditor({this.existing});

  final AccountConfig? existing;

  @override
  State<_AccountEditor> createState() => _AccountEditorState();
}

class _AccountEditorState extends State<_AccountEditor> {
  late String _providerId;
  late SourceType _source;
  late final TextEditingController _label;
  late final TextEditingController _home;
  final Map<String, TextEditingController> _fields = {};
  final Map<String, String> _choices = {};
  late Map<String, String> _savedSecrets;

  UsageProvider get _provider => ProviderRegistry.instance.byId(_providerId)!;
  List<SourceType> get _sources => _sourcesOf(_provider);

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _providerId = e?.providerId ?? availableProviders.first.id;
    _source = e?.sourceType ?? _sources.first;
    _label = TextEditingController(text: e?.label ?? _provider.displayName);
    _home = TextEditingController(text: e?.homeDir ?? '');
    _savedSecrets = e?.providerId == _providerId ? SecretBundle.decode(e?.secret) : {};
    _resetFields();
  }

  void _resetFields() {
    for (final c in _fields.values) {
      c.dispose();
    }
    _fields.clear();
    _choices.clear();
    final options = widget.existing?.providerId == _providerId
        ? widget.existing!.options
        : const <String, String>{};
    for (final f in _provider.fields) {
      if (f.kind == FieldKind.choice) {
        _choices[f.key] = options[f.key] ?? f.defaultValue ?? f.choices.first.value;
      } else {
        _fields[f.key] = TextEditingController(text: f.isSecure ? '' : (options[f.key] ?? ''));
      }
    }
  }

  @override
  void dispose() {
    _label.dispose();
    _home.dispose();
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  String? get _defaultHome => switch (_providerId) {
    'codex' => resolveCodexHome(null),
    'claude' => resolveClaudeConfigDir(null),
    'cursor' => cursorStateDbPath(null),
    _ => null,
  };

  bool get _supportsHomeDir => const {'codex', 'claude', 'cursor'}.contains(_providerId);

  void _selectProvider(UsageProvider p) {
    setState(() {
      final previousName = _provider.displayName;
      _providerId = p.id;
      _source = _sources.first;
      _savedSecrets = {};
      if (_label.text.trim().isEmpty || _label.text == previousName) _label.text = p.displayName;
      _resetFields();
    });
  }

  void _toast(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _save() async {
    final c = context.read<AppController>();
    final label = _label.text.trim().isEmpty ? _provider.displayName : _label.text.trim();
    final home = _home.text.trim();
    final manual = _source == SourceType.apiKey;

    final secrets = <String, String>{..._savedSecrets};
    final options = <String, String>{...?widget.existing?.options};
    for (final f in _provider.fields) {
      final value = f.kind == FieldKind.choice ? _choices[f.key]! : _fields[f.key]!.text.trim();
      if (f.isSecure) {
        if (value.isNotEmpty) secrets[f.key] = value;
      } else if (value.isEmpty) {
        options.remove(f.key);
      } else {
        options[f.key] = value;
      }
    }
    String? secret;
    if (manual) {
      for (final f in _provider.fields) {
        final present = f.isSecure ? secrets[f.key] != null : options[f.key] != null;
        if (f.required && !present && f.defaultValue == null && FieldValues.envValue(f) == null) {
          _toast('请填写 ${f.label}');
          return;
        }
      }
      secret = SecretBundle.encode(secrets);
      final draft = AccountConfig(
        id: '',
        providerId: _providerId,
        label: label,
        sourceType: _source,
        secret: secret,
        options: options,
      );
      final problem = _provider.validateManual(FieldValues.of(_provider, draft));
      if (problem != null) {
        _toast(problem);
        return;
      }
    }

    final e = widget.existing;
    if (e == null) {
      await c.addAccount(
        providerId: _providerId,
        label: label,
        sourceType: _source,
        homeDir: !manual && home.isNotEmpty ? home : null,
        secret: secret,
        options: options,
      );
    } else {
      await c.updateAccount(
        e.copyWith(
          label: label,
          sourceType: _source,
          homeDir: home.isEmpty ? null : home,
          clearHomeDir: home.isEmpty || manual,
          secret: secret,
          clearSecret: secret == null,
          options: options,
        ),
      );
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final editing = widget.existing != null;
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return AlertDialog(
      title: Text(editing ? '编辑账户' : '添加账户'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                key: const ValueKey('provider-picker'),
                borderRadius: BorderRadius.circular(4),
                onTap: editing
                    ? null
                    : () async {
                        final picked = await showProviderPicker(context);
                        if (picked != null) _selectProvider(picked);
                      },
                child: InputDecorator(
                  decoration: InputDecoration(labelText: '服务', enabled: !editing),
                  child: Row(
                    children: [
                      ProviderBadge(providerId: _providerId, size: 22),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_provider.displayName)),
                      if (!editing) const Icon(Icons.arrow_drop_down),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(_provider.setupHint, style: muted),
              const SizedBox(height: 12),
              TextField(
                controller: _label,
                decoration: const InputDecoration(labelText: '显示名称'),
              ),
              if (_sources.length > 1) ...[
                const SizedBox(height: 12),
                SegmentedButton<SourceType>(
                  segments: [
                    for (final s in _sources)
                      ButtonSegment(value: s, label: Text(sourceTypeLabel(_providerId, s))),
                  ],
                  selected: {_source},
                  onSelectionChanged: (v) => setState(() => _source = v.first),
                ),
              ],
              const SizedBox(height: 12),
              if (_source == SourceType.localCli) ...[
                if (_supportsHomeDir)
                  TextField(
                    controller: _home,
                    decoration: InputDecoration(
                      labelText: _providerId == 'cursor' ? 'Cursor 数据目录（可选）' : '配置目录（可选）',
                      hintText: _defaultHome ?? '',
                      helperText: '留空使用默认目录；多账户时为每个账户指定不同目录',
                      helperMaxLines: 2,
                    ),
                  ),
              ] else
                for (final f in _provider.fields) ...[_buildField(f), const SizedBox(height: 12)],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }

  Widget _buildField(ProviderField f) {
    if (f.kind == FieldKind.choice) {
      return DropdownButtonFormField<String>(
        initialValue: _choices[f.key],
        decoration: InputDecoration(labelText: f.label, helperText: f.help, helperMaxLines: 3),
        items: [for (final c in f.choices) DropdownMenuItem(value: c.value, child: Text(c.label))],
        onChanged: (v) => setState(() => _choices[f.key] = v!),
      );
    }
    final env = canUseLocalLogins ? FieldValues.envValue(f) : null;
    final saved = f.isSecure && _savedSecrets[f.key] != null;
    final helper = [
      if (f.help != null) f.help!,
      if (env != null) '已检测到环境变量 ${f.envVars.join(' / ')}，可留空',
      if (f.isSecure) '保存在系统安全存储中',
    ].join('。');
    return TextField(
      controller: _fields[f.key],
      obscureText: f.isSecure && !f.multiline,
      minLines: f.multiline ? 2 : 1,
      maxLines: f.multiline ? 4 : 1,
      style: f.multiline ? const TextStyle(fontFamily: 'monospace', fontSize: 12) : null,
      keyboardType: f.kind == FieldKind.url ? TextInputType.url : null,
      decoration: InputDecoration(
        labelText: f.required ? f.label : '${f.label}（可选）',
        hintText: saved ? '已保存，留空保持不变' : (f.hint ?? f.defaultValue),
        helperText: helper.isEmpty ? null : helper,
        helperMaxLines: 4,
      ),
    );
  }
}

/// Searchable list of providers usable on this device.
Future<UsageProvider?> showProviderPicker(BuildContext context) {
  return showDialog<UsageProvider>(context: context, builder: (_) => const _ProviderPicker());
}

class _ProviderPicker extends StatefulWidget {
  const _ProviderPicker();

  @override
  State<_ProviderPicker> createState() => _ProviderPickerState();
}

class _ProviderPickerState extends State<_ProviderPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final items = availableProviders
        .where((p) => q.isEmpty || p.displayName.toLowerCase().contains(q) || p.id.contains(q))
        .toList();
    return AlertDialog(
      title: const Text('选择服务'),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 420,
        height: 520,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '搜索',
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final p = items[i];
                  return ListTile(
                    dense: true,
                    leading: ProviderBadge(providerId: p.id, size: 26),
                    title: Text(p.displayName),
                    subtitle: Text(_sourcesOf(p).map((s) => sourceTypeLabel(p.id, s)).join(' / ')),
                    onTap: () => Navigator.pop(context, p),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消'))],
    );
  }
}
