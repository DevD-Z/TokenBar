import 'dart:convert';
import 'dart:io';

import 'package:tokenbar_core/tokenbar_core.dart';

/// Loads accounts from a JSON file (`[{"providerId": "codex", ...}]`), or
/// falls back to the default local Codex + Claude logins of this machine.
Future<List<AccountConfig>> loadAccounts(String? path) async {
  if (path != null) {
    final raw = jsonDecode(await File(path).readAsString());
    final list = raw is Map ? raw['accounts'] as List : raw as List;
    final host = hostName();
    return list.map((e) {
      final map = (e as Map).cast<String, Object?>();
      final provider = map['providerId'] as String;
      return AccountConfig.fromJson({
        'id': '$provider@$host',
        'label': '${ProviderRegistry.instance.byId(provider)?.displayName ?? provider} ($host)',
        ...map,
      });
    }).toList();
  }
  return await defaultLocalAccounts();
}

/// One account per provider with a local login on this machine; all local
/// providers when none is found, so the errors explain how to log in.
Future<List<AccountConfig>> defaultLocalAccounts() async {
  final host = hostName();
  final all = [
    for (final p in ProviderRegistry.instance.all)
      if (p.needsLocalAccess)
        AccountConfig(id: '${p.id}@$host', providerId: p.id, label: '${p.displayName} ($host)'),
  ];
  final detected = <AccountConfig>[];
  for (final p in ProviderRegistry.instance.all) {
    final candidate = AccountConfig(
      id: '${p.id}@$host',
      providerId: p.id,
      label: '${p.displayName} ($host)',
    );
    final source = await p.detectLocalSetup(candidate);
    if (source != null) detected.add(candidate.copyWith(sourceType: source));
  }
  return detected.isEmpty ? all : detected;
}

String hostName() {
  try {
    return Platform.localHostname.toLowerCase();
  } catch (_) {
    return 'local';
  }
}

Future<List<UsageSnapshot>> collectOnce(
  List<AccountConfig> accounts,
  FetchContext ctx, {
  String? origin,
}) async {
  final futures = <Future<UsageSnapshot>>[];
  for (final account in accounts.where((a) => a.enabled)) {
    final provider = ProviderRegistry.instance.byId(account.providerId);
    if (provider == null) {
      futures.add(
        Future.value(
          UsageSnapshot.failure(
            accountId: account.id,
            providerId: account.providerId,
            fetchedAt: ctx.now(),
            accountLabel: account.label,
            error: 'Unknown provider ${account.providerId}',
          ),
        ),
      );
      continue;
    }
    futures.add(provider.fetchSafely(account, ctx));
  }
  final results = await Future.wait(futures);
  return origin == null ? results : results.map((s) => s.copyWith(origin: origin)).toList();
}

Duration parseInterval(String value) {
  final match = RegExp(r'^(\d+)\s*([smh]?)$').firstMatch(value.trim());
  if (match == null) throw FormatException('Invalid interval: $value');
  final n = int.parse(match.group(1)!);
  return switch (match.group(2)) {
    'h' => Duration(hours: n),
    's' => Duration(seconds: n),
    _ => Duration(minutes: n),
  };
}
