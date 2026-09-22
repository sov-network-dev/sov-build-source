// lib/test_conv_id.dart
// Run: dart lib/test_conv_id.dart
// Verifies ConversationUtils.conversationId is symmetric and consistent.
import 'package:flutter/foundation.dart';
import 'sov_node_sdk/conversation_utils.dart';

void main() {
  const a = 'SOV-6A849A265A9B30F9';
  const b = 'SOV-YOURENROLLEDID0';

  final id1 = ConversationUtils.conversationId(a, b);
  final id2 = ConversationUtils.conversationId(b, a);

  assert(id1 == id2, 'ConvId must be symmetric: "$id1" != "$id2"');
  debugPrint('ConvId: $id1');
  debugPrint('Symmetry: PASS');

  // Verify :: separator and sort order
  final parts = id1.split('::');
  assert(parts.length == 2, 'Must have exactly one :: separator');
  assert(parts[0].compareTo(parts[1]) <= 0, 'Must be sorted ascending');
  debugPrint('Separator: PASS');
  debugPrint('Sort order: PASS');
}
