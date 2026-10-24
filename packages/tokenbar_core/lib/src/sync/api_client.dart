import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/usage_point.dart';
import '../models/usage_snapshot.dart';
import '../util/json_utils.dart';

class SyncException implements Exception {
  SyncException(this.message, [this.statusCode]);

  final String message;
  final int? statusCode;

  @override
  String toString() => statusCode == null ? message : '$message (HTTP $statusCode)';
}

/// Client for a self-hosted `tokenbar serve` instance.
///
/// API (all JSON, `Authorization: Bearer <token>`):
/// - `GET  /api/v1/health`
/// - `GET  /api/v1/snapshots`            latest snapshot per account
/// - `POST /api/v1/snapshots`            `{origin, snapshots: [...]}`
/// - `GET  /api/v1/history?account=&since=`
class TokenBarApiClient {
  TokenBarApiClient({required String baseUrl, required this.token, http.Client? client})
    : baseUri = Uri.parse(baseUrl.endsWith('/') ? baseUrl : '$baseUrl/'),
      _client = client ?? http.Client();

  final Uri baseUri;
  final String token;
  final http.Client _client;

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $token',
    'Accept': 'application/json',
    'Content-Type': 'application/json',
  };

  Uri _uri(String path, [Map<String, String>? query]) =>
      baseUri.resolve(path).replace(queryParameters: query);

  Future<Map<String, Object?>> health() async {
    final r = await _client
        .get(_uri('api/v1/health'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    return _decode(r);
  }

  Future<List<UsageSnapshot>> latest() async {
    final r = await _client
        .get(_uri('api/v1/snapshots'), headers: _headers)
        .timeout(const Duration(seconds: 20));
    final json = _decode(r);
    return (asList(json['snapshots']) ?? const [])
        .map((e) => UsageSnapshot.fromJson(asMap(e)!))
        .toList();
  }

  Future<void> push(List<UsageSnapshot> snapshots, {required String origin}) async {
    final r = await _client
        .post(
          _uri('api/v1/snapshots'),
          headers: _headers,
          body: jsonEncode({
            'origin': origin,
            'snapshots': snapshots.map((s) => s.toJson()).toList(),
          }),
        )
        .timeout(const Duration(seconds: 20));
    _decode(r);
  }

  Future<List<UsagePoint>> history({String? accountId, DateTime? since}) async {
    final r = await _client
        .get(
          _uri('api/v1/history', {
            'account': ?accountId,
            if (since != null) 'since': since.toUtc().toIso8601String(),
          }),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 20));
    final json = _decode(r);
    return (asList(json['points']) ?? const []).map((e) => UsagePoint.fromJson(asMap(e)!)).toList();
  }

  Map<String, Object?> _decode(http.Response r) {
    if (r.statusCode == 401 || r.statusCode == 403) {
      throw SyncException('服务器令牌无效', r.statusCode);
    }
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw SyncException('服务器错误', r.statusCode);
    }
    if (r.body.isEmpty) return const {};
    final json = decodeJsonObject(utf8.decode(r.bodyBytes));
    if (json == null) throw SyncException('服务器返回了无效数据');
    return json;
  }

  void close() => _client.close();
}
