import 'dart:convert';

Map<String, Object?>? asMap(Object? value) => value is Map ? value.cast<String, Object?>() : null;

List<Object?>? asList(Object? value) => value is List ? value : null;

String? asString(Object? value) {
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  return null;
}

/// Accepts numbers and numeric strings.
double? asDouble(Object? value) {
  if (value is num) return value.isFinite ? value.toDouble() : null;
  if (value is String) return double.tryParse(value.trim());
  return null;
}

int? asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.isFinite ? value.toInt() : null;
  if (value is String) return int.tryParse(value.trim());
  return null;
}

bool? asBool(Object? value) {
  if (value is bool) return value;
  if (value is String) {
    if (value == 'true') return true;
    if (value == 'false') return false;
  }
  return null;
}

/// First non-null value among snake/camel spellings.
Object? pick(Map<String, Object?> map, List<String> keys) {
  for (final key in keys) {
    final v = map[key];
    if (v != null) return v;
  }
  return null;
}

Map<String, Object?>? decodeJsonObject(String text) {
  try {
    return asMap(jsonDecode(text));
  } on FormatException {
    return null;
  }
}

/// Decodes the payload segment of a JWT without verifying it. Only used for
/// scheduling hints and identity claims, never for authorization decisions.
Map<String, Object?>? decodeJwtPayload(String? token) {
  if (token == null) return null;
  final parts = token.split('.');
  if (parts.length != 3 || parts[1].isEmpty) return null;
  try {
    final normalized = base64Url.normalize(parts[1]);
    return asMap(jsonDecode(utf8.decode(base64Url.decode(normalized))));
  } catch (_) {
    return null;
  }
}

DateTime? epochSeconds(int? seconds) =>
    seconds == null ? null : DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
