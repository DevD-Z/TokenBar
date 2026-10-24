import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';
import 'package:tokenbar_core/tokenbar_core.dart';

import 'store.dart';

class ServerConfig {
  const ServerConfig({
    required this.adminToken,
    this.readToken,
    this.webDir,
    this.allowNoAuth = false,
  });

  /// Read + write (collectors push with this token).
  final String? adminToken;

  /// Optional read-only token for phones / browsers.
  final String? readToken;
  final String? webDir;
  final bool allowNoAuth;
}

enum _Access { none, read, write }

Handler buildHandler(SnapshotStore store, ServerConfig config) {
  _Access accessOf(Request request) {
    if (config.allowNoAuth && config.adminToken == null) return _Access.write;
    final header = request.headers['authorization'] ?? '';
    final token = header.startsWith('Bearer ') ? header.substring(7).trim() : '';
    if (token.isEmpty) return _Access.none;
    if (config.adminToken != null && _constantTimeEquals(token, config.adminToken!)) {
      return _Access.write;
    }
    if (config.readToken != null && _constantTimeEquals(token, config.readToken!)) {
      return _Access.read;
    }
    return _Access.none;
  }

  Response json(Object body, {int status = 200}) => Response(
    status,
    body: jsonEncode(body),
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  Response? requireAccess(Request request, _Access needed) {
    final access = accessOf(request);
    if (access == _Access.none) return json({'error': 'unauthorized'}, status: 401);
    if (needed == _Access.write && access != _Access.write) {
      return json({'error': 'forbidden'}, status: 403);
    }
    return null;
  }

  final router = Router()
    ..get('/api/v1/health', (Request request) {
      return json({
        'ok': true,
        'service': 'tokenbar',
        'authenticated': accessOf(request) != _Access.none,
      });
    })
    ..get('/api/v1/providers', (Request request) {
      return json({
        'providers': [
          for (final p in ProviderRegistry.instance.all)
            {'id': p.id, 'name': p.displayName, 'color': p.brandColor},
        ],
      });
    })
    ..get('/api/v1/snapshots', (Request request) {
      final denied = requireAccess(request, _Access.read);
      if (denied != null) return denied;
      return json({'snapshots': store.latest().map((s) => s.toJson()).toList()});
    })
    ..post('/api/v1/snapshots', (Request request) async {
      final denied = requireAccess(request, _Access.write);
      if (denied != null) return denied;
      try {
        final body = jsonDecode(await request.readAsString()) as Map<String, Object?>;
        final origin = body['origin'] as String?;
        final snapshots = (body['snapshots'] as List)
            .map((e) => UsageSnapshot.fromJson((e as Map).cast<String, Object?>()))
            .map((s) => s.origin == null && origin != null ? s.copyWith(origin: origin) : s)
            .toList();
        await store.put(snapshots);
        return json({'stored': snapshots.length});
      } catch (e) {
        return json({'error': 'invalid payload: $e'}, status: 400);
      }
    })
    ..delete('/api/v1/snapshots/<accountId>', (Request request, String accountId) async {
      final denied = requireAccess(request, _Access.write);
      if (denied != null) return denied;
      await store.remove(Uri.decodeComponent(accountId));
      return json({'removed': accountId});
    })
    ..get('/api/v1/history', (Request request) async {
      final denied = requireAccess(request, _Access.read);
      if (denied != null) return denied;
      final q = request.url.queryParameters;
      final points = await store.history(
        accountId: q['account'],
        since: q['since'] == null ? null : DateTime.tryParse(q['since']!),
      );
      return json({'points': points.map((p) => p.toJson()).toList()});
    });

  var cascade = Cascade().add(router.call);
  final webDir = config.webDir;
  if (webDir != null && Directory(webDir).existsSync()) {
    cascade = cascade.add(createStaticHandler(webDir, defaultDocument: 'index.html'));
  }

  return const Pipeline().addMiddleware(_cors()).addHandler(cascade.handler);
}

/// API is token-authenticated (no cookies), so permissive CORS is safe and
/// lets a separately hosted web build or `flutter run -d chrome` connect.
Middleware _cors() {
  const headers = {
    'access-control-allow-origin': '*',
    'access-control-allow-methods': 'GET, POST, DELETE, OPTIONS',
    'access-control-allow-headers': 'authorization, content-type, accept',
  };
  return (inner) => (request) async {
    if (request.method == 'OPTIONS') return Response.ok('', headers: headers);
    final response = await inner(request);
    return response.change(headers: headers);
  };
}

bool _constantTimeEquals(String a, String b) {
  final x = utf8.encode(a);
  final y = utf8.encode(b);
  var diff = x.length ^ y.length;
  for (var i = 0; i < x.length && i < y.length; i++) {
    diff |= x[i] ^ y[i];
  }
  return diff == 0;
}
