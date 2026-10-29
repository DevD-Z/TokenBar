class OAuthCallbackServer {
  Uri get redirectUri => throw UnsupportedError('OAuth loopback callback is not available on web');

  static Future<OAuthCallbackServer> bind({int? port, required String path}) =>
      throw UnsupportedError('OAuth loopback callback is not available on web');

  Future<Uri> waitForCallback({Duration timeout = const Duration(minutes: 5)}) =>
      throw UnsupportedError('OAuth loopback callback is not available on web');

  Future<void> close() async {}
}
