/// Compact countdown: `3d 4h`, `2h 13m`, `45m`, `<1m`.
String formatCountdown(Duration d) {
  if (d.inMinutes < 1) return '<1m';
  final days = d.inDays;
  final hours = d.inHours % 24;
  final minutes = d.inMinutes % 60;
  if (days > 0) return hours > 0 ? '${days}d ${hours}h' : '${days}d';
  if (d.inHours > 0) return minutes > 0 ? '${d.inHours}h ${minutes}m' : '${d.inHours}h';
  return '${minutes}m';
}

String formatPercent(double value) {
  final rounded = value.roundToDouble();
  return (value - rounded).abs() < 0.05 ? '${rounded.toInt()}%' : '${value.toStringAsFixed(1)}%';
}

String formatMoney(double value, String? currency) {
  final symbol = switch (currency?.toUpperCase()) {
    'USD' => r'$',
    'EUR' => '€',
    'GBP' => '£',
    'CNY' => '¥',
    null => '',
    final other => '$other ',
  };
  return '$symbol${value.toStringAsFixed(2)}';
}
