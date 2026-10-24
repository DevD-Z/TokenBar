import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Thin wrapper over flutter_local_notifications; no-op where unsupported.
class Notifier {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  int _nextId = 1;

  static const _darwin = DarwinInitializationSettings(
    requestAlertPermission: false,
    requestSoundPermission: false,
    requestBadgePermission: false,
  );

  Future<void> init() async {
    if (kIsWeb) return;
    try {
      _ready =
          await _plugin.initialize(
            settings: const InitializationSettings(
              android: AndroidInitializationSettings('@mipmap/ic_launcher'),
              iOS: _darwin,
              macOS: _darwin,
              linux: LinuxInitializationSettings(defaultActionName: '打开 TokenBar'),
              windows: WindowsInitializationSettings(
                appName: 'TokenBar',
                appUserModelId: 'TokenBar.TokenBar.App',
                guid: '6f1d6a2e-4d0b-4bb5-9a86-5b9b8a7f2c10',
              ),
            ),
          ) ??
          false;
    } catch (e) {
      debugPrint('notifications unavailable: $e');
      _ready = false;
    }
  }

  /// Shows the Android 13+ permission dialog; call after the UI is up.
  Future<void> requestPermission() async {
    if (!_ready) return;
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      await _plugin
          .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, sound: true);
      await _plugin
          .resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, sound: true);
    } catch (e) {
      debugPrint('notification permission request failed: $e');
    }
  }

  Future<void> show(String title, String body) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        id: _nextId++,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'quota',
            '额度提醒',
            channelDescription: '低额度和额度重置提醒',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
          macOS: DarwinNotificationDetails(),
          linux: LinuxNotificationDetails(),
          windows: WindowsNotificationDetails(),
        ),
      );
    } catch (e) {
      debugPrint('notification failed: $e');
    }
  }
}
