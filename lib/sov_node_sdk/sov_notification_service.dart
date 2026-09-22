// lib/sov_node_sdk/sov_notification_service.dart
// ─────────────────────────────────────────────────────────────────────────────
// SovNotificationService — system-tray notifications for SOV transfers.
//
// Wraps flutter_local_notifications so the rest of the app has a single
// fire-and-forget API.  All methods are safe to call before init() — they
// silently no-op until the plugin is ready.
//
// Notification channels (Android 8+):
//   sov_transfers — high-importance, for received SOV transfers
// ─────────────────────────────────────────────────────────────────────────────
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class SovNotificationService {
  SovNotificationService._();

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  // ── Android notification channel ───────────────────────────────────────────
  static const _kTransferChannelId   = 'sov_transfers';
  static const _kTransferChannelName = 'SOV Transfers';
  static const _kTransferChannelDesc =
      'Alerts when you receive SOV from another citizen';

  // ── Init ────────────────────────────────────────────────────────────────────
  /// Call once from main() before runApp().
  /// Safe to call again — idempotent.
  static Future<void> init() async {
    if (_initialized) return;
    try {
      const androidSettings =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      const settings = InitializationSettings(android: androidSettings);
      await _plugin.initialize(settings);
      _initialized = true;
      debugPrint('[NOTIFY] Initialized');
    } catch (e) {
      debugPrint('[NOTIFY] Init error: $e');
    }
  }

  // ── Permission request — call after runApp() from a Widget context ─────────
  /// Requests POST_NOTIFICATIONS on Android 13+ (API 33).
  /// Safe to call multiple times — no-op if already granted.
  /// Must be called AFTER the Flutter engine has a live window
  /// (e.g. in initState of the root shell widget).
  static Future<void> requestPermission() async {
    if (!_initialized) return;
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      debugPrint('[NOTIFY] Permission requested');
    } catch (e) {
      debugPrint('[NOTIFY] Permission request error: $e');
    }
  }

  // ── Message received ───────────────────────────────────────────────────────
  /// Show a system notification when a SOV Speak message arrives while the
  /// app is in the background or the screen is locked.
  /// [senderName] — display name or truncated ID
  /// [preview]    — first ~60 chars of the message (already decrypted)
  static Future<void> showMessageReceived({
    required String senderName,
    required String preview,
    String          fromId = '',
  }) async {
    if (!_initialized) return;
    try {
      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          'sov_messages',
          'SOV Speak Messages',
          channelDescription: 'Alerts for incoming encrypted messages',
          importance:        Importance.high,
          priority:          Priority.high,
          icon:              '@mipmap/ic_launcher',
          enableVibration:   true,
          styleInformation:  BigTextStyleInformation(''),
        ),
      );

      final body = preview.length > 80 ? '${preview.substring(0, 80)}…' : preview;

      await _plugin.show(
        // Use fromId hash for dedup so rapid messages from same sender collapse
        fromId.isEmpty
            ? DateTime.now().millisecondsSinceEpoch & 0x7FFFFFFF
            : _notifId(fromId) & 0x7FFFFFFF,
        senderName,
        body,
        details,
      );
    } catch (e) {
      debugPrint('[NOTIFY] showMessageReceived error: $e');
    }
  }

  // ── Transfer received ──────────────────────────────────────────────────────
  /// Show a high-priority system notification when a SOV transfer arrives.
  /// [fromId]      — sender's sovereign ID
  /// [amountSeeds] — transfer amount in seeds (1 SOV = 1 000 000 seeds)
  /// [txHash]      — relay transaction hash (used for dedup ID; may be empty)
  static Future<void> showTransferReceived({
    required String fromId,
    required int    amountSeeds,
    String          txHash = '',
  }) async {
    if (!_initialized) return;
    try {
      final sovStr  = _formatSov(amountSeeds);
      final sender  = _shortId(fromId);

      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          _kTransferChannelId,
          _kTransferChannelName,
          channelDescription: _kTransferChannelDesc,
          importance:  Importance.high,
          priority:    Priority.high,
          icon:        '@mipmap/ic_launcher',
          // Vibrate once (default pattern)
          enableVibration: true,
        ),
      );

      await _plugin.show(
        _notifId(txHash),
        '+$sovStr SOV Received',
        'From $sender',
        details,
      );
    } catch (e) {
      debugPrint('[NOTIFY] showTransferReceived error: $e');
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  static String _formatSov(int seeds) {
    final sov = seeds / 1000000;
    return sov >= 1 ? sov.toStringAsFixed(2) : sov.toStringAsFixed(6);
  }

  static String _shortId(String id) {
    if (id.length <= 18) return id;
    return '${id.substring(0, 10)}…${id.substring(id.length - 6)}';
  }

  /// Deterministic notification ID derived from tx hash so duplicate relay
  /// deliveries (e.g. during reconnect) don't stack multiple notifications.
  static int _notifId(String txHash) {
    if (txHash.isEmpty) {
      return DateTime.now().millisecondsSinceEpoch & 0x7FFFFFFF;
    }
    return txHash.codeUnits
            .fold<int>(0, (acc, c) => (acc * 31 + c) & 0x7FFFFFFF);
  }
}
