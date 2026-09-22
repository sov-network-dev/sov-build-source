// lib/sov_node_sdk/draft_manager.dart
// ─────────────────────────────────────────────────────────────────────────────
// Universal draft persistence.
//
// Every text field in the app calls DraftManager.save() on change.
// The 500 ms debounce prevents excessive disk writes.
// Fields call DraftManager.load() in initState to restore after
// PIN lock, app switch, or cold start.
// Successful form submission calls DraftManager.clear/clearAll()
// so the restored state reflects a clean form on next open.
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';

class DraftManager {
  static final Map<String, Timer?> _timers = {};

  static const Duration _debounce = Duration(milliseconds: 500);

  /// Save a draft value after 500 ms debounce.
  /// Key should be unique to the field and context.
  static void save(String key, String value) {
    _timers[key]?.cancel();
    _timers[key] = Timer(_debounce, () async {
      final prefs = await SharedPreferences.getInstance();
      if (value.isEmpty) {
        await prefs.remove(key);
      } else {
        await prefs.setString(key, value);
      }
    });
  }

  /// Load a saved draft. Returns empty string if no draft exists.
  static Future<String> load(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(key) ?? '';
  }

  /// Clear a saved draft after successful submission.
  static Future<void> clear(String key) async {
    _timers[key]?.cancel();
    _timers[key] = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }

  /// Clear multiple keys at once.
  /// Use after a form submits successfully.
  static Future<void> clearAll(List<String> keys) async {
    for (final key in keys) {
      await clear(key);
    }
  }

  /// Cancel all pending timers.
  /// Called in main.dart dispose / app detach.
  static void cancelAll() {
    for (final timer in _timers.values) {
      timer?.cancel();
    }
    _timers.clear();
  }
}
