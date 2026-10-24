import '../models/credits.dart';
import '../models/rate_window.dart';
import 'provider.dart';

/// used/limit as 0-100; non-positive limit counts as exhausted.
double pct(num used, num limit) => limit <= 0 ? 100 : (used / limit * 100).clamp(0, 100).toDouble();

RateWindow quotaWindow(
  String id,
  String label, {
  required double usedPercent,
  DateTime? resetsAt,
  int? windowMinutes,
}) => RateWindow(
  id: id,
  label: label,
  usedPercent: usedPercent.isFinite ? usedPercent : 0,
  resetsAt: resetsAt,
  windowMinutes: windowMinutes,
);

Credits balanceRow(String id, double balance, {String label = '余额', String? currency = 'USD'}) =>
    Credits(id: id, label: label, balance: balance, currency: currency);

Credits spendRow(
  String id,
  double used, {
  double? limit,
  String label = '花费',
  String? currency = 'USD',
  DateTime? resetsAt,
}) => Credits(
  id: id,
  label: label,
  used: used,
  limit: (limit != null && limit > 0) ? limit : null,
  currency: currency,
  resetsAt: resetsAt,
);

String moneyText(double amount, String? currency) {
  final code = currency?.toUpperCase();
  final fixed = amount.abs().toStringAsFixed(2);
  final sign = amount < 0 ? '-' : '';
  return switch (code) {
    'USD' || null => '$sign\$$fixed',
    'CNY' => '$sign¥$fixed',
    'EUR' => '$sign€$fixed',
    _ => '$sign$fixed $code',
  };
}

/// Next UTC midnight / Monday / first of month after [now].
DateTime nextUtcDay(DateTime now) {
  final u = now.toUtc();
  return DateTime.utc(u.year, u.month, u.day + 1);
}

DateTime nextUtcMonth(DateTime now) {
  final u = now.toUtc();
  return DateTime.utc(u.year, u.month + 1);
}

DateTime startOfUtcMonth(DateTime now) {
  final u = now.toUtc();
  return DateTime.utc(u.year, u.month);
}

/// Hosts where plain HTTP is acceptable for self-hosted gateways.
bool isPrivateHost(String host) {
  final h = host.toLowerCase();
  if (h == 'localhost' || h.endsWith('.local') || h == '::1' || h == '[::1]') return true;
  final ip = RegExp(r'^(\d+)\.(\d+)\.(\d+)\.(\d+)$').firstMatch(h);
  if (ip != null) {
    final a = int.parse(ip[1]!);
    final b = int.parse(ip[2]!);
    return a == 127 ||
        a == 10 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) ||
        (a == 169 && b == 254);
  }
  final v6 = h.replaceAll(RegExp(r'[\[\]]'), '');
  return v6.startsWith('fc') || v6.startsWith('fd') || v6.startsWith('fe80');
}

/// Validates a self-hosted gateway URL: HTTPS, or HTTP on loopback/private
/// networks; never embedded credentials. Returns it without trailing slash.
String gatewayBaseUrl(String provider, String raw) {
  final trimmed = raw.trim().replaceAll(RegExp(r'/+$'), '');
  final uri = Uri.tryParse(trimmed);
  final valid =
      uri != null &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      (uri.isScheme('https') || (uri.isScheme('http') && isPrivateHost(uri.host)));
  if (!valid) {
    throw ProviderException(
      '$provider 的地址无效: $trimmed',
      hint: '公网地址必须是 https://，http:// 只允许本机或局域网地址，且不能包含账号密码',
    );
  }
  return trimmed;
}
