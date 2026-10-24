class ProcessOutput {
  const ProcessOutput(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final String stdout;
  final String stderr;
}

/// A line-delimited JSON-RPC session over a child process' stdio.
abstract class JsonRpcSession {
  /// Sends a request and waits for the response with the same id.
  /// Returns the `result` object; throws [JsonRpcException] on `error`.
  Future<Object?> request(String method, {Object? params, Duration timeout});

  void notify(String method, {Object? params});

  Future<void> close();
}

class JsonRpcException implements Exception {
  JsonRpcException(this.message);

  final String message;

  @override
  String toString() => 'JsonRpcException: $message';
}
