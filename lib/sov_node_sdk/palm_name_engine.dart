// palm_name_engine.dart
// ─────────────────────────────────────────────────────────────────────────────
// SOV Network — Deterministic Citizen Nickname Engine
//
// Derives a stable, vivid name from a citizen's SOVEREIGN ID.
// Format: Adjective + Noun (e.g. "IronHawk", "DeepFlame", "WildTide")
//
// ⚠️ NO BIOMETRIC DATA IS USED, DERIVED FROM, OR ENCODED HERE. ⚠️
// This header previously described an embedding-based algorithm. That algorithm
// was replaced (see deriveName below) but the header was not updated, which left
// the source stating the opposite of what the code does. That matters legally,
// not just cosmetically: this source is public, and the resulting name travels
// off-network as `palm_name` in the SOV_LINK_CREATED callback to third-party
// platforms. A reader of the old header would reasonably conclude that SOV
// transmits biometric-derived data to those platforms. It does not, and no
// third party can infer anything about a palm from this name.
//
// ALGORITHM:
//   1. SHA-256 of the sovereign ID (a public identifier, not biometric)
//   2. Two 4-hex-digit slices of that digest → two indices
//   3. Adjective[32] × Noun[32] = 1,024 unique deterministic names
//
// STABILITY GUARANTEE:
//   Same sovereign ID → same digest → same name, on every device, with no
//   network round-trip and no access to any embedding.
//
//   The guarantee is conditional on ONE thing: the two vocabulary arrays below
//   are FROZEN. The name is an INDEX into them, so inserting, removing or
//   reordering a single word silently renames a large fraction of the network's
//   citizens — including names already stored in sov_enrollments.palm_name on
//   the nodes and already sent off-network in SOV_LINK_CREATED callbacks.
//   Append-only is not safe either: the index is `% length`, so growing an
//   array from 32 changes the modulus and rewrites nearly every name.
//   Treat both arrays as a protocol constant, not as content.
//
// The `embedding` parameter survives on the public methods only so existing
// call sites keep compiling. It is ignored. See deriveName.
//
// APP SIZE IMPACT: ~2 KB (vocabulary strings only — no new packages)
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:convert';
import 'package:crypto/crypto.dart';

class PalmNameEngine {
  // ── Vocabulary — 32 adjectives × 32 nouns = 1,024 unique names ──────────────
  // Adjectives: strong character qualities — vivid, personal, gender-neutral
  static const _adjectives = [
    'Bold',   'Deep',   'Swift',  'Dark',   'Wild',   'Iron',   'Still',  'Bright',
    'Cold',   'Sharp',  'Fierce', 'Calm',   'Lone',   'True',   'Stark',  'Free',
    'Stone',  'Ember',  'Storm',  'Frost',  'Dusk',   'Dawn',   'Ash',    'Tide',
    'Hollow', 'Silent', 'Bare',   'Keen',   'Grim',   'Clear',  'Dry',    'Whole',
  ];

  // Nouns: forces of nature, creatures, elemental things — vivid and memorable
  static const _nouns = [
    'Hawk',   'Wolf',   'Tide',   'Flame',  'Ridge',  'Storm',  'Thorn',  'River',
    'Blade',  'Crow',   'Shore',  'Ember',  'Peak',   'Rift',   'Gale',   'Reed',
    'Flint',  'Veil',   'Crest',  'Heron',  'Coil',   'Fern',   'Mist',   'Drake',
    'Dune',   'Kite',   'Ash',    'Prism',  'Vale',   'Spire',  'Birch',  'Forge',
  ];

  // ── Derive name from the sovereign ID ────────────────────────────────────────
  /// Returns "AdjectiveNoun" — e.g. "IronHawk", "DeepFlame", "WildTide".
  /// Used for the home screen balance card (personal display name).
  ///
  /// [embedding] — IGNORED. Retained only so existing call sites compile; it is
  ///               never read, and no biometric value reaches the returned name.
  /// [sovereignId] — the ONLY input. The name is a pure function of it.
  static String deriveName(List<double> embedding, {String sovereignId = ''}) {
    // DETERMINISTIC, network-consistent name: a PURE function of the sovereign ID.
    //
    // The palm embedding is intentionally NOT used. Other citizens — and contact
    // lists, chat threads, groups, the node pool — only ever have a citizen's
    // sovereign ID, never their palm embedding. An embedding-based name therefore
    // rendered ONE way on the owner's own device (which has the embedding, e.g.
    // "ColdHawk") and a DIFFERENT way everywhere else (id-only fallback, e.g.
    // "BrightKite") — the same citizen showing two names. Deriving purely from the
    // ID guarantees every device, everywhere, shows the SAME name for the same
    // citizen, with zero network round-trip. `embedding` is accepted only for
    // backward-compatible call sites and is ignored.
    return _fallbackName(sovereignId);
  }

  // ── Derive unique network handle ─────────────────────────────────────────────
  /// Returns "AdjectiveNoun·XXXX" — e.g. "IronHawk·A3F7".
  ///
  /// Both parts derive from the sovereign ID and NOTHING ELSE — the two words
  /// via deriveName, the 4-char hex suffix via sha256(sovereignId). No palm
  /// data is involved.
  ///
  /// ⚠️ THE HANDLE IS NOT UNIQUE AND MUST NEVER BE USED AS AN IDENTIFIER. ⚠️
  /// A previous version of this comment claimed that two citizens who collide
  /// on the two-word name still get different handles. That is false, and the
  /// reason is worth stating so nobody re-derives the wrong conclusion:
  ///   • suffix       = digest[0..4]        (16 bits)
  ///   • adjective ix = digest[0..4] % 32   ← THE SAME 16 BITS
  ///   • noun ix      = digest[4..8] % 32   (5 bits)
  /// The adjective is fully determined by the suffix, so a handle carries
  /// 16 + 5 = 21 bits, i.e. 2,097,152 distinct handles — NOT the ~67 million
  /// (1,024 names × 65,536 suffixes) a reader of the format would assume.
  /// Simulated over random sovereign IDs: first duplicate handles appear at
  /// ~2,000 citizens, 50% chance of at least one at ~1,705, and 22 duplicates
  /// at 10,000. The suffix makes collisions RARER than the bare name, never
  /// impossible. The sovereign ID is the only unique value in this system.
  ///
  /// Intended for display only — SOV Speak groups, SOV Enclave, anywhere
  /// multiple citizens appear. Home screen shows the plain two-word name
  /// without the suffix. Currently no call sites; retained for that display use.
  static String deriveHandle(List<double> embedding, String sovereignId) {
    final name   = deriveName(embedding, sovereignId: sovereignId);
    final digest = sha256.convert(utf8.encode(sovereignId)).toString();
    final suffix = digest.substring(0, 4).toUpperCase();
    return '$name·$suffix';
  }

  /// Extract just the handle suffix (e.g. "A3F7") from a sovereign ID.
  /// Useful for displaying the suffix separately from the name.
  static String handleSuffix(String sovereignId) {
    if (sovereignId.isEmpty) return '0000';
    final digest = sha256.convert(utf8.encode(sovereignId)).toString();
    return digest.substring(0, 4).toUpperCase();
  }

  /// Split a full handle "IronHawk·A3F7" into its name and suffix parts.
  /// Returns [name, suffix] or [handle, ''] if no suffix present.
  static List<String> splitHandle(String handle) {
    final idx = handle.indexOf('·');
    if (idx == -1) return [handle, ''];
    return [handle.substring(0, idx), handle.substring(idx + '·'.length)];
  }

  // ── Validate a stored palm name ──────────────────────────────────────────────
  static bool isValidPalmName(String name) {
    if (name.isEmpty) return false;
    for (final adj in _adjectives) {
      if (name.startsWith(adj)) {
        final noun = name.substring(adj.length);
        if (_nouns.contains(noun)) return true;
      }
    }
    return false;
  }

  // ── Private helpers ──────────────────────────────────────────────────────────

  /// Derive a deterministic name from sovereign_id — the canonical algorithm.
  /// Used for citizens enrolled before this feature was added.
  static String _fallbackName(String sovereignId) {
    if (sovereignId.isEmpty) return 'IronHawk';
    final digest = sha256.convert(utf8.encode(sovereignId)).toString();
    final ai = int.parse(digest.substring(0, 4), radix: 16) % _adjectives.length;
    final ni = int.parse(digest.substring(4, 8), radix: 16) % _nouns.length;
    return '${_adjectives[ai]}${_nouns[ni]}';
  }
}
