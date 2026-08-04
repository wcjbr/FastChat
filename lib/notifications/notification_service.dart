import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  NotificationService._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _initialized = false;
  static int _nextId = 1;

  static Future<void> initialize() async {
    if (_initialized) {
      return;
    }

    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
      macOS: DarwinInitializationSettings(),
      linux: LinuxInitializationSettings(defaultActionName: '打开'),
      windows: WindowsInitializationSettings(
        appName: 'Fast Chat',
        appUserModelId: 'FastChat.Local.P2P',
        guid: '7f5728e5-65aa-45af-8c13-079f7a8dd7ab',
      ),
    );

    try {
      await _plugin.initialize(settings: settings);
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
      await _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: true, sound: true);
      await _plugin
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: true, sound: true);
      _initialized = true;
    } catch (_) {
      _initialized = false;
    }
  }

  static Future<void> showMessage({
    required String roomName,
    required String sender,
    required String text,
  }) async {
    if (!_initialized) {
      await initialize();
    }
    if (!_initialized) {
      return;
    }

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'fast_chat_messages',
        '聊天消息',
        channelDescription: 'Fast Chat 收到的新消息',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
      macOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
      linux: LinuxNotificationDetails(),
      windows: WindowsNotificationDetails(),
    );

    try {
      await _plugin.show(
        id: _nextId++,
        title: '$sender · $roomName',
        body: text,
        notificationDetails: details,
        payload: roomName,
      );
    } catch (_) {}
  }
}
