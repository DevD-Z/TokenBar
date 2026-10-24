/// Local machine access (files, env, processes).
///
/// On the web every function reports "unsupported" so providers that need
/// local CLI credentials degrade to a clear error instead of crashing.
library;

export 'platform_stub.dart' if (dart.library.io) 'platform_io.dart';
