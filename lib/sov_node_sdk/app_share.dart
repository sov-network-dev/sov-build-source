/// app_share.dart — a citizen hands the app to another citizen, with nothing in the
/// middle that can be shut down.
///
/// WHY THIS EXISTS. Every way of getting SOV went through somebody else's host. Measured
/// 2026-10-01: the rented IPFS gateway returns nothing for every published address and its
/// metered allowance was spent before launch, and the BitTorrent leg seeds from nodes whose
/// peer port the cloud firewall closes inbound, so it only ever completed through its web
/// seed — which points at the primary host. Two documented fallbacks, both leading back to
/// the same place. The network has to be able to hand itself out.
///
/// WHAT IS SHARED IS A POINTER, NEVER THE FILE. The Android package is ~116 MB; pushing
/// that through the relay would be wrong and is not needed. The share carries the version
/// and, per platform, three things: the sha256, the IPFS content id and the BitTorrent
/// infohash. Each of those addresses the BYTES rather than a machine — anyone can serve
/// them, and holding one reveals nothing about where it came from.
///
/// NO NODE ADDRESS APPEARS HERE, EVER. `IP_INVISIBLE_RELAY_PROTOCOL.md` section 2 point 3
/// forbids any public manifest, directory or scrape from carrying a relay IP, and
/// `assets/relay_pool.json` is deliberately empty for the same reason — a published address
/// list is a readable map of the fleet and a target list for the shutdown this design
/// exists to survive. A share travels further and less predictably than a manifest, so the
/// rule binds harder here, not less. `assertNoNodeAddress` enforces it and is covered by a
/// test.
///
/// THE SENDER IS NOT TRUSTED. A share is a claim. [verifyAgainstNetwork] fetches the
/// signature-verified manifest independently and compares every field; a sender who alters
/// a hash, a content id or an infohash is caught, and the recipient is told the pointer
/// disagrees with the network rather than being quietly handed the wrong software. The
/// authority is the signed manifest, never the message.
///
/// iOS. An iPhone cannot install an app from outside the App Store, so the manifest
/// deliberately carries no iOS artifact (see `UpdateService.thisPlatform`). An iPhone
/// citizen can still COMPOSE and pass on a share — they are relaying a pointer, not
/// installing — and a recipient on iOS is told plainly that there is nothing to sideload
/// instead of being offered something they cannot run.
library;

import 'update_service.dart';

/// One platform's addresses, as claimed by a share.
class SharedArtifact {
  final String platform;
  final String sha256;
  final String ipfsCid;
  final String infohash;

  const SharedArtifact({
    required this.platform,
    required this.sha256,
    required this.ipfsCid,
    required this.infohash,
  });

  /// A magnet URI for this artifact. No tracker is invented here beyond the two public
  /// ones the release torrents already announce to, and deliberately no web seed: a web
  /// seed would point at the primary host and reintroduce the dependency this whole file
  /// exists to remove. Empty when the release carried no infohash.
  String magnet(String fileName) {
    if (infohash.isEmpty) return '';
    const trackers =
        '&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce'
        '&tr=udp%3A%2F%2Ftracker.openbittorrent.com%3A6969%2Fannounce';
    return 'magnet:?xt=urn:btih:$infohash&dn=${Uri.encodeComponent(fileName)}$trackers';
  }
}

/// What one citizen hands another.
class SharePointer {
  final String version;
  final List<SharedArtifact> artifacts;

  const SharePointer({required this.version, required this.artifacts});

  SharedArtifact? forPlatform(String platform) {
    for (final a in artifacts) {
      if (a.platform == platform) return a;
    }
    return null;
  }

  /// The wire form: short, plain text, survives being pasted anywhere.
  ///
  /// Deliberately not JSON. This travels through a message thread and gets copied by hand,
  /// and a format that survives a line wrap and a stray space is worth more here than one
  /// that round-trips perfectly in a parser.
  String toMessageText() {
    final b = StringBuffer()
      ..writeln('$_marker $version')
      ..writeln('# verify against the network before installing; do not trust this message');
    for (final a in artifacts) {
      b.writeln('${a.platform} ${a.sha256} ${a.ipfsCid} ${a.infohash}');
    }
    return b.toString().trimRight();
  }
}

/// The outcome of checking a share against the signed manifest.
class ShareVerdict {
  final bool ok;
  final String reason;

  /// The artifact the RECIPIENT can actually use, taken from the manifest — never from the
  /// message — and null when their platform has none (iOS, or a platform the release skips).
  final UpdateArtifact? artifact;

  const ShareVerdict({required this.ok, required this.reason, this.artifact});
}

const String _marker = 'SOV-APP';

class AppShare {
  /// Build a share from the signature-verified manifest.
  ///
  /// Every field comes from the manifest, so a citizen cannot accidentally pass on a stale
  /// or hand-edited pointer. Returns null when no manifest verifies — offering an
  /// unverified pointer would defeat the purpose.
  /// Pass [manifest] when the caller already holds a verified one. Fetching again would
  /// repeat the network walk AND the signature verification, and could land on a
  /// DIFFERENT manifest mid-release, so two parts of one screen would disagree.
  static Future<SharePointer?> compose({Map<String, dynamic>? manifest}) async {
    final man = manifest ?? await UpdateService.fetchVerifiedManifest();
    if (man == null) return null;

    final version = (man['version'] as String?)?.trim() ?? '';
    if (version.isEmpty) return null;

    final platforms = (man['platforms'] as Map?) ?? const {};
    final out = <SharedArtifact>[];
    platforms.forEach((key, value) {
      if (value is! Map) return;
      final sha = ((value['sha256'] as String?) ?? '').trim().toLowerCase();
      final cid = ((value['ipfs_cid'] as String?) ?? '').trim();
      final ih = ((value['infohash'] as String?) ?? '').trim().toLowerCase();
      // A platform with no content address is worth nothing in a share: the recipient would
      // be left with the host-based mirrors, which is what this is meant to survive.
      if (sha.isEmpty || (cid.isEmpty && ih.isEmpty)) return;
      out.add(SharedArtifact(
        platform: key.toString(),
        sha256: sha,
        ipfsCid: cid,
        infohash: ih,
      ));
    });
    if (out.isEmpty) return null;
    out.sort((a, b) => a.platform.compareTo(b.platform));

    final p = SharePointer(version: version, artifacts: out);
    assertNoNodeAddress(p.toMessageText());
    return p;
  }

  /// Content addresses for DISPLAY. Safe to show, copy, print or photograph.
  ///
  /// There is no host in any of these. A sha256 and an IPFS cid name the bytes; a magnet
  /// names them plus two public trackers that belong to nobody here. None of it can be
  /// reported to a host, because there is no host to report it to, and none of it reveals a
  /// node. That is the whole point: a take-down notice needs an addressee.
  ///
  /// Deliberately NO web page is offered. A page is a reportable address and the one thing
  /// the king ruled out, so this returns addresses of the software and nothing else.
  static List<String> displayAddresses(SharedArtifact a, String fileName) {
    final out = <String>['sha256 ${a.sha256}'];
    if (a.ipfsCid.isNotEmpty) out.add('ipfs ${a.ipfsCid}');
    final m = a.magnet(fileName);
    if (m.isNotEmpty) out.add(m);
    for (final line in out) {
      assertNoNodeAddress(line);
    }
    return out;
  }

  /// Where the app FETCHES from is NOT implemented here on purpose.
  ///
  /// `UpdateService.networkFallbackUrls` already does it, and already carries the reasoning:
  /// the addresses are built from nodes THIS DEVICE DISCOVERED AT RUNTIME, so none is written
  /// into the manifest, the page or the package. A second implementation of the same thing in
  /// the distribution path is how this repo has drifted before - two copies of one rule, and
  /// only one of them maintained. Call that, not something new here.
  ///
  /// Three properties of that path matter and are verified, not assumed:
  ///   - it fetches with an in-process HttpClient, so no system download manager, no browser
  ///     history, no notification and no "copy link" ever sees the address;
  ///   - `update_service.dart` contains no logging at all, so it is not written to a log;
  ///   - the bytes are hashed against the signed manifest before anything is installed.

  /// This device's artifact from the signature-verified manifest, or null when the release
  /// carries nothing for it (iOS always, since an iPhone cannot install from outside the
  /// App Store).
  ///
  /// Separate from [verifyAgainstNetwork], which resolves the same entry in order to COMPARE
  /// it against a share. This one is for showing a citizen what is currently published.
  static Future<UpdateArtifact?> localArtifact({Map<String, dynamic>? manifest}) async {
    final man = manifest ?? await UpdateService.fetchVerifiedManifest();
    if (man == null) return null;
    if (UpdateService.thisPlatform() == 'ios') return null;
    final platforms = (man['platforms'] as Map?) ?? const {};
    for (final k in UpdateService.platformKeys()) {
      final art = platforms[k];
      if (art is! Map) continue;
      return UpdateArtifact(
        version: (art['version'] as String?) ?? (man['version'] as String? ?? ''),
        sha256: ((art['sha256'] as String?) ?? '').trim().toLowerCase(),
        sizeBytes: (art['size_bytes'] as num?)?.toInt() ?? 0,
        mirrors: ((art['mirrors'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        ipfsCid: ((art['ipfs_cid'] as String?) ?? '').trim(),
        infohash: ((art['infohash'] as String?) ?? '').trim().toLowerCase(),
      );
    }
    return null;
  }

  /// Does this text look like a share? Cheap enough to run on every inbound message.
  static bool looksLikeShare(String text) =>
      text.trimLeft().startsWith('$_marker ');

  /// Parse a received share. Returns null on anything malformed — a share that does not
  /// parse cleanly is discarded rather than half-read.
  static SharePointer? parse(String text) {
    final lines = text.split('\n');
    if (lines.isEmpty) return null;

    final head = lines.first.trim().split(RegExp(r'\s+'));
    if (head.length < 2 || head[0] != _marker) return null;
    final version = head[1];
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) return null;

    final out = <SharedArtifact>[];
    for (final raw in lines.skip(1)) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final f = line.split(RegExp(r'\s+'));
      if (f.length < 4) continue;
      final platform = f[0];
      final sha = f[1].toLowerCase();
      final cid = f[2];
      final ih = f[3].toLowerCase();
      if (!RegExp(r'^[a-z0-9_]{3,20}$').hasMatch(platform)) continue;
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) continue;
      if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(ih)) continue;
      out.add(SharedArtifact(
          platform: platform, sha256: sha, ipfsCid: cid, infohash: ih));
    }
    if (out.isEmpty) return null;
    return SharePointer(version: version, artifacts: out);
  }

  /// Check a share against the network. THIS is what makes a share safe to act on.
  ///
  /// The message is treated as a rumour. The signed manifest decides, and the artifact
  /// handed back is the manifest's, so even a share that passes every comparison cannot
  /// inject its own values into the install path.
  static Future<ShareVerdict> verifyAgainstNetwork(SharePointer share) async {
    final man = await UpdateService.fetchVerifiedManifest();
    if (man == null) {
      return const ShareVerdict(
        ok: false,
        reason: 'no signed manifest could be verified, so this pointer cannot be checked',
      );
    }

    final netVersion = (man['version'] as String?)?.trim() ?? '';
    if (netVersion != share.version) {
      return ShareVerdict(
        ok: false,
        reason: 'this pointer is for ${share.version} and the network publishes $netVersion',
      );
    }

    final me = UpdateService.thisPlatform();
    if (me == 'ios') {
      return const ShareVerdict(
        ok: false,
        reason: 'an iPhone cannot install an app from outside the App Store — '
            'pass this on to someone on Android, Windows, macOS or Linux',
      );
    }

    final platforms = (man['platforms'] as Map?) ?? const {};
    Map? art;
    String? key;
    for (final k in UpdateService.platformKeys()) {
      final v = platforms[k];
      if (v is Map) {
        art = v;
        key = k;
        break;
      }
    }
    if (art == null || key == null) {
      return ShareVerdict(
          ok: false, reason: 'the release carries nothing for this device ($me)');
    }

    final claimed = share.forPlatform(key);
    if (claimed == null) {
      return ShareVerdict(
          ok: false, reason: 'this pointer carries nothing for this device ($key)');
    }

    final netSha = ((art['sha256'] as String?) ?? '').trim().toLowerCase();
    final netCid = ((art['ipfs_cid'] as String?) ?? '').trim();
    final netIh = ((art['infohash'] as String?) ?? '').trim().toLowerCase();

    if (claimed.sha256 != netSha) {
      return const ShareVerdict(
        ok: false,
        reason: 'the hash in this message does not match the signed manifest — '
            'do not install it',
      );
    }
    if (netCid.isNotEmpty && claimed.ipfsCid != netCid) {
      return const ShareVerdict(
        ok: false,
        reason: 'the content id in this message does not match the signed manifest',
      );
    }
    if (netIh.isNotEmpty && claimed.infohash != netIh) {
      return const ShareVerdict(
        ok: false,
        reason: 'the torrent address in this message does not match the signed manifest',
      );
    }

    return ShareVerdict(
      ok: true,
      reason: 'matches the signed manifest',
      artifact: UpdateArtifact(
        version: (art['version'] as String?) ?? netVersion,
        sha256: netSha,
        sizeBytes: (art['size_bytes'] as num?)?.toInt() ?? 0,
        mirrors: ((art['mirrors'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        ipfsCid: netCid,
        infohash: netIh,
      ),
    );
  }

  /// Throws if a share text contains anything that looks like a bare IPv4 address.
  ///
  /// Not decoration. A node address in a share is the one mistake in this area that cannot
  /// be taken back — a manifest can be republished, a message that has already been passed
  /// between citizens cannot. Content ids and infohashes are hex or base58 and never match
  /// this shape, so a hit means a host leaked in.
  static void assertNoNodeAddress(String text) {
    final m = RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}\b').firstMatch(text);
    if (m != null) {
      throw StateError(
          'refusing to build a share containing a host address: ${m.group(0)}');
    }
  }
}
