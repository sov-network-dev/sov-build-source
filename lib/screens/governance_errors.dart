// Plain-language text for the codes the governance and justice engines return.
//
// The node answers a refused poll, vote, petition or case with a code such as
// ALREADY_VOTED or UNKNOWN_TAG. The screen used to show that code as-is (E2E run
// 2026-10-03, finding 2). The list below is every error code that
// governance_engine.js and justice_engine.js emit, plus the two the gateway can
// return for any signed operation. An unlisted code still reaches the citizen —
// after the plain fallback, so a new node error is never swallowed.

const Map<String, String> _plain = {
  // Polls
  'ALREADY_VOTED':    'You have already voted in this poll.',
  'POLL_CLOSED':      'This poll has closed.',
  'POLL_EXPIRED':     'This poll has closed.',
  'POLL_NOT_FOUND':   'This poll is no longer on the network.',
  'POLL_ID_EXISTS':   'This poll already exists. Pull down to refresh.',
  'INVALID_OPTION':   'That choice is not one of this poll\'s options.',
  'INVALID_VOTE':     'That choice is not one of this poll\'s options.',
  'TOO_MANY_OPTIONS': 'A poll can offer at most 10 options.',
  'UNKNOWN_TAG':      'The network does not accept votes on this yet. '
                      'It is listed ahead of its release.',
  // Petitions
  'ALREADY_SIGNED':     'You have already signed this petition.',
  'PETITION_NOT_FOUND': 'This petition is no longer on the network.',
  'PETITION_CLOSED':    'This petition has closed.',
  'UNKNOWN_PARAM':      'The network does not accept petitions on this setting yet.',
  // Justice
  'CANNOT_DISPUTE_SELF':           'You cannot open a case against yourself.',
  'INSUFFICIENT_BALANCE_FOR_BOND': 'Your balance does not cover the bond for opening a case.',
  'CASE_NOT_FOUND':                'This case is no longer on the network.',
  'CASE_NOT_ACTIVE':               'This case is no longer open.',
  'CASE_ID_EXISTS':                'This case already exists. Pull down to refresh.',
  'NOT_AN_ACCEPTED_JUROR':         'Only jurors who accepted this case can vote on it.',
  'NOT_INVITED_OR_ALREADY_RESPONDED':
      'You were not invited to this jury, or you have already answered.',
  'PANEL_AT_MAXIMUM': 'The jury is already at its largest size.',
  // Any signed operation
  'SIGNATURE_REQUIRED': 'Your wallet could not sign this. Close and reopen the app, then try again.',
  'MISSING_FIELDS':     'The request was incomplete. Update the app and try again.',
};

/// The text to show when the node refuses a governance or justice request.
/// [resp] is the node's reply (null when it did not answer in time).
String governanceErrorText(Map<String, dynamic>? resp, String fallback) {
  if (resp == null) return '$fallback — the network did not answer. Try again.';
  final code = (resp['error'] ?? '').toString();
  if (code.isEmpty) return fallback;
  if (code == 'COOLDOWN_ACTIVE') {
    final days = (resp['days_remaining'] as num?)?.toInt();
    return days == null
        ? 'This was voted on recently and cannot be proposed again yet.'
        : 'This was voted on recently. It can be proposed again in '
          '$days day${days == 1 ? '' : 's'}.';
  }
  final plain = _plain[code];
  if (plain != null) return plain;
  // Not a known code: if it reads like one, keep it visible but secondary;
  // if the node sent a sentence, show the sentence.
  return RegExp(r'^[A-Z0-9_]+$').hasMatch(code) ? '$fallback ($code)' : code;
}
