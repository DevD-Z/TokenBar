import 'dart:async';
import 'dart:io';

class OAuthCallbackServer {
  OAuthCallbackServer._(this._server, this._path);

  final HttpServer _server;
  final String _path;

  Uri get redirectUri => Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: _server.port,
    path: _path,
  );

  static Future<OAuthCallbackServer> bind({int? port, required String path}) async {
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      port ?? 0,
      shared: false,
    );
    return OAuthCallbackServer._(server, path);
  }

  Future<Uri> waitForCallback({Duration timeout = const Duration(minutes: 5)}) async {
    final completer = Completer<Uri>();
    late final StreamSubscription<HttpRequest> subscription;
    subscription = _server.listen((request) async {
      if (request.uri.path != _path) {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write('Not found');
        await request.response.close();
        return;
      }

      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write(
          '<!doctype html><html><body style="font-family:system-ui;padding:32px">'
          '<h2>TokenBar sign-in complete</h2>'
          '<p>You can close this window and return to TokenBar.</p>'
          '<script>window.close()</script></body></html>',
        );
      await request.response.close();
      if (!completer.isCompleted) completer.complete(request.uri);
    });

    try {
      return await completer.future.timeout(timeout);
    } finally {
      await subscription.cancel();
    }
  }

  Future<void> close() => _server.close(force: true);
}
