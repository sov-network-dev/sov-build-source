// lib/sov_node_sdk/conversation_utils.dart
// ─────────────────────────────────────────────────────────────────────────────
// Canonical conversation ID generator.
//
// Sorts the two participant sovereign IDs alphabetically and joins them with
// '::' so the same pair always produces the same ID regardless of which
// participant is "sender" and which is "receiver".
//
// MUST be used everywhere a conversationId is created or queried:
//   - main_shell.dart  (_wireMessageStream)
//   - sov_link_screen.dart (_conversationId / _openThread)
//   - contacts_db.dart would accept any string — callers must use this util.
// ─────────────────────────────────────────────────────────────────────────────

class ConversationUtils {
  /// Returns a deterministic, symmetric conversation ID for two sovereign IDs.
  ///
  /// Example:
  ///   conversationId('SOV-BBB', 'SOV-AAA') == 'SOV-AAA::SOV-BBB'
  ///   conversationId('SOV-AAA', 'SOV-BBB') == 'SOV-AAA::SOV-BBB'
  static String conversationId(String a, String b) {
    final sorted = [a, b]..sort();
    return '${sorted[0]}::${sorted[1]}';
  }
}
