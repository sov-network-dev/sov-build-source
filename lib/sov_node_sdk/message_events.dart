// lib/sov_node_sdk/message_events.dart
// ─────────────────────────────────────────────────────────────────────────────
// MessageEvents — app-wide broadcasts for async data changes.
//
// Two independent channels:
//
//   onConversationChanged  — fired when a conversation is created/updated
//     (message sent by SovLinkScreen OR incoming message handled by
//     main_shell).  MessagesScreen listens and reloads its list.
//
//   onTransactionsChanged  — fired when TransactionStore is written
//     (relay ledger sync imports records after connect/restore).
//     HomeTab listens and reloads its Recent Transactions list.
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:async';

class MessageEvents {
  MessageEvents._();

  // ── Conversation channel ──────────────────────────────────────────────────

  static final _convController =
      StreamController<void>.broadcast();

  /// Fires whenever the local conversation list may have changed.
  static Stream<void> get onConversationChanged => _convController.stream;

  /// Call after upsertConversation so MessagesScreen reloads.
  static void notifyConversationChanged() {
    if (!_convController.isClosed) _convController.add(null);
  }

  // ── Transaction channel ───────────────────────────────────────────────────

  static final _txController =
      StreamController<void>.broadcast();

  /// Fires whenever TransactionStore has new records (relay sync, received
  /// transfer, etc.).  HomeTab listens and reloads Recent Transactions.
  static Stream<void> get onTransactionsChanged => _txController.stream;

  /// Call after TransactionStore.save() / mergeAll() so HomeTab reloads.
  static void notifyTransactionsChanged() {
    if (!_txController.isClosed) _txController.add(null);
  }
}
