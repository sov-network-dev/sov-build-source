// lib/sov_node_sdk/update_service.dart
// ─────────────────────────────────────────────────────────────────────────────
// Client-side auto-update verifier (Dart port of wallet/node-client/src/update_check.js
// + wallet/windows/sovwallet/updater.py + integrity.py).
//
// The app carries NO hardcoded download URL — only a short ordered list of MANIFEST
// locations and the network trust keys. It:
//   1. fetches the signed Distribution Manifest from the first reachable location,
//   2. verifies >= threshold Ed25519 signatures against the network trust keys
//      (trust comes from the SIGNATURE, never the host — a poisoned mirror is caught),
//   3. compares the running version to the manifest version,
//   4. if newer, returns the per-platform artifact (version, sha256, size, mirrors),
//   5. after the UI downloads the artifact, re-verifies its SHA-256 before applying.
//
// Canonical bytes match the producer (release_signer.js) byte-for-byte: compact JSON
// of the manifest MINUS its `sigs` array. Dart's jsonDecode preserves source key
// order, so decode → drop `sigs` → jsonEncode reproduces JSON.stringify(rest).
//
// At Phase 2 (PI-37) the single interim signer below is replaced by the elected
// FROST witness-signers and the threshold is raised (3-of-5).
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' as pc;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cryptography/cryptography.dart' as sov_crypto;
import 'node_discovery.dart';

class UpdateArtifact {
  final String version;
  final String sha256;
  final int sizeBytes;
  final List<String> mirrors;

  /// IP-FREE content addresses, both covered by the manifest signature.
  ///
  /// `mirrors` are host URLs and therefore name machines. These two name the BYTES:
  /// anyone can serve them, and holding one reveals nothing about where it came from.
  /// That is what makes citizen-to-citizen sharing possible without publishing a node
  /// address - see IP_INVISIBLE_RELAY_PROTOCOL section 2, which forbids any public
  /// manifest from carrying a relay IP.
  ///
  /// Empty when the manifest predates them, so an older manifest still parses.
  final String ipfsCid;
  final String infohash;

  UpdateArtifact({
    required this.version,
    required this.sha256,
    required this.sizeBytes,
    required this.mirrors,
    this.ipfsCid = '',
    this.infohash = '',
  });
}

class UpdateCheckResult {
  final bool update;
  final String reason;
  final String? version;
  final UpdateArtifact? artifact;
  final int validSigs;
  final int threshold;
  UpdateCheckResult({
    required this.update,
    required this.reason,
    this.version,
    this.artifact,
    this.validSigs = 0,
    this.threshold = 0,
  });
}

class UpdateService {
  UpdateService._();

  // ── Network trust anchor (rotated by governance; bootstrap set) ───────────
  // Mirrors NETWORK_TRUST_KEYS in update_check.js — interim release signer,
  // owner-blessed 2026-06-10. → FROST witness-signers at Phase 2.
  static const List<String> networkTrustKeys = [
    'b4fa1c07c8935c500602957c500a7fac4c6953491c9d763180d07cd45fba7545',
  ];
  static const int defaultThreshold = 1; // → 3 (of 5) at Phase 2

  // ── LAUNCH PLACEHOLDERS — federated Layer-B pointer-store mirrors ──────────
  // SHIP READY, REPLACE AT LAUNCH (see docs/SOV_LAUNCH_ROADMAP_FINAL_20260617.md §3).
  // Each is signature-verified after fetch, so adding neutral third-party mirrors
  // needs no extra trust. Keep >=3 INDEPENDENT hosts (no single point of failure);
  // each must serve the SAME threshold-signed pool+manifest blob; none is a relay
  // and none carries a relay IP. Until these are filled the list stays empty and
  // cold-start falls back to bootstrap (the temporary no-IP gap we are closing).
  // Uncomment + fill each with the real URL once the accounts in §2 are live:
  static const List<String> manifestLocations = [
    'https://raw.githubusercontent.com/sov-network/relay-releases/main/sov-manifest.json', // GitHub raw
    'https://sov-pointer.sovnetworkdev.workers.dev/sov-manifest.json',                     // Cloudflare Worker+KV
    // 'https://<subdomain>/sov-manifest.json',                                          // Render+Upstash (CNAME)
    // 'https://<ipfs-gateway>/ipns/<k51...>',                                           // IPFS/IPNS (optional)
  ];

  static String thisPlatform() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isAndroid) return 'android'; // was falling through to 'linux' (found 2026-09-22)
    // iOS asks for a key the manifest deliberately does not carry: an iPhone app cannot
    // replace itself outside the App Store, so the honest answer is "no artifact for ios"
    // rather than offering it a Linux AppImage, which is what it used to be handed.
    if (Platform.isIOS) return 'ios';
    return 'linux';
  }

  /// The Dart SDK's own platform_arch token — "macos_arm64", "windows_x64", "linux_x64".
  /// `Platform.version` ends with it in quotes; there is no dedicated API for the CPU
  /// architecture, and this is the value the SDK itself was built for, which is exactly
  /// what has to match a downloaded binary.
  static String? platformArchKey() {
    final m = RegExp(r'"([a-z0-9]+_[a-z0-9]+)"').firstMatch(Platform.version);
    return m?.group(1);
  }

  /// Manifest platform keys to try, most specific first.
  ///
  /// v1.2.1 shipped ONE macOS asset built on an Apple Silicon runner but named "x64": the
  /// app bundle was universal, the node inside it was arm64, so on an Intel Mac the wallet
  /// ran and the node could not start. From v1.2.2 the release carries `macos_arm64` and
  /// `macos_x64` separately, and this is how a client asks for the one it can actually run.
  /// The bare platform key stays last so a manifest written for older clients still works.
  static List<String> platformKeys() {
    final arch = platformArchKey();
    final base = thisPlatform();
    return [
      if (arch != null && arch != base) arch,
      base,
    ];
  }

  // ── Canonical bytes = compact JSON of manifest minus `sigs` ───────────────
  static List<int> canonicalBytes(Map<String, dynamic> manifest) {
    final rest = <String, dynamic>{};
    manifest.forEach((k, v) {
      if (k != 'sigs') rest[k] = v; // preserves source key order
    });
    return utf8.encode(jsonEncode(rest));
  }

  // ── Verify >= threshold distinct trusted Ed25519 signatures ───────────────
  // Returns the count of valid distinct trusted signers.
  static Future<int> _countValidSignatures(
    Map<String, dynamic> manifest,
    Set<String> trusted,
  ) async {
    final bytes = canonicalBytes(manifest);
    final algo = sov_crypto.Ed25519();
    final good = <String>{};
    final sigs = (manifest['sigs'] as List?) ?? const [];
    for (final raw in sigs) {
      if (raw is! Map) continue;
      final alg = (raw['alg'] as String?)?.toLowerCase();
      final signer = (raw['signer'] as String?)?.toLowerCase();
      final sigHex = raw['signature'] as String?;
      if (alg != 'ed25519' || signer == null || sigHex == null) continue;
      if (!trusted.contains(signer) || good.contains(signer)) continue;
      try {
        final pub = sov_crypto.SimplePublicKey(
          _hex(signer),
          type: sov_crypto.KeyPairType.ed25519,
        );
        final ok = await algo.verify(
          bytes,
          signature: sov_crypto.Signature(_hex(sigHex), publicKey: pub),
        );
        if (ok) good.add(signer);
      } catch (_) {
        // malformed key/sig → ignore this signature
      }
    }
    return good.length;
  }

  /// Decide whether to update. Verifies signatures FIRST (refuses on failure),
  /// then version, then platform artifact.
  static Future<UpdateCheckResult> checkForUpdate(
    Map<String, dynamic> signedManifest,
    String currentVersion, {
    List<String> trustKeys = networkTrustKeys,
    int threshold = defaultThreshold,
  }) async {
    final trusted = trustKeys.map((k) => k.toLowerCase()).toSet();
    final valid = await _countValidSignatures(signedManifest, trusted);
    if (valid < threshold) {
      return UpdateCheckResult(
        update: false,
        reason: 'manifest signature/threshold INVALID — refusing',
        validSigs: valid,
        threshold: threshold,
      );
    }
    final manVersion = signedManifest['version'] as String? ?? '0';
    if (!_isNewer(manVersion, currentVersion)) {
      return UpdateCheckResult(
        update: false,
        reason: 'already current',
        validSigs: valid,
        threshold: threshold,
      );
    }
    final plats = signedManifest['platforms'] as Map?;
    final tried = platformKeys();
    Map? art;
    for (final k in tried) {
      art = plats?[k] as Map?;
      if (art != null) break;
    }
    if (art == null) {
      return UpdateCheckResult(
        update: false,
        reason: 'no artifact for ${tried.join(" or ")}',
        validSigs: valid,
        threshold: threshold,
      );
    }
    return UpdateCheckResult(
      update: true,
      reason: 'verified newer release',
      version: manVersion,
      validSigs: valid,
      threshold: threshold,
      artifact: UpdateArtifact(
        version: (art['version'] as String?) ?? manVersion,
        sha256: ((art['sha256'] as String?) ?? '').toLowerCase(),
        sizeBytes: (art['size_bytes'] as num?)?.toInt() ?? 0,
        mirrors: ((art['mirrors'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        ipfsCid: ((art['ipfs_cid'] as String?) ?? '').trim(),
        infohash: ((art['infohash'] as String?) ?? '').trim().toLowerCase(),
      ),
    );
  }

  /// Fetch the first signature-VALID manifest from [locations] (default list).
  /// Returns null if none reachable or none verifies.
  /// Where to look for the manifest on the MESH, after the fixed hosts.
  ///
  /// The two hosts in [manifestLocations] can both be taken down, and an app that knows
  /// only those two can never be told about a replacement however many are created
  /// afterwards. The nodes serve the manifest from the same public directory as the
  /// releases, so this is the channel that survives losing both — and it costs the operator
  /// almost nothing, because the manifest is about 3 KB against a 116 MB artifact.
  ///
  /// These addresses come from runtime discovery (cached pool, pointer mirrors, DHT) and are
  /// never rendered, logged, published or written into a share — the same rule
  /// [networkFallbackUrls] follows. Publishing an address is what the invisibility protocol
  /// forbids; using one the device already holds is explicitly allowed.
  static List<String> meshManifestUrls() {
    final out = <String>[];
    for (final node in NodeDiscovery.all) {
      if (node.ip.isEmpty) continue;
      out.add('http://${node.ip}/download/sov-manifest.json');
    }
    return out;
  }

  static const String _rollbackKey = 'sov_manifest_highest_built_at';

  /// The newest `built_at` this device has ever accepted.
  static Future<int> _rollbackFloor() async {
    try {
      final p = await SharedPreferences.getInstance();
      return p.getInt(_rollbackKey) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> _rememberBuiltAt(int builtAt) async {
    if (builtAt <= 0) return;
    try {
      final p = await SharedPreferences.getInstance();
      if (builtAt > (p.getInt(_rollbackKey) ?? 0)) {
        await p.setInt(_rollbackKey, builtAt);
      }
    } catch (_) {
      // A device that cannot persist this still gets signature + hash verification; it just
      // loses replay protection. Failing the fetch instead would be worse.
    }
  }

  static Future<Map<String, dynamic>?> fetchVerifiedManifest({
    List<String>? locations,
    List<String> trustKeys = networkTrustKeys,
    int threshold = defaultThreshold,
  }) async {
    final locs = locations ?? <String>[...manifestLocations, ...meshManifestUrls()];
    final trusted = trustKeys.map((k) => k.toLowerCase()).toSet();
    final floor = await _rollbackFloor();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      // NEWEST VALID WINS, NOT FIRST VALID (2026-10-02).
      //
      // This used to walk the list and return the first manifest that verified. That made
      // GitHub raw - first in the list - the authority whenever it answered at all. If the
      // GitHub account were ever frozen rather than deleted (readable, but no longer ours to
      // write), every app would keep reading its last manifest for ever, and a newer one
      // signed for a replacement host and published to the Worker and the nodes would never
      // be seen. Moving the release host is meant to need a re-sign, never a rebuild
      // (docs/GITHUB_FAILOVER_RUNBOOK.md), and that only holds if no single location can
      // outvote the others just by answering first.
      //
      // So every location is asked at once, every reply is signature-checked, and the newest
      // `built_at` wins. The signature is still what makes a manifest trustworthy; this only
      // decides between several trustworthy ones. Equal `built_at` keeps list order.
      //
      // Each location also gets a hard time budget. The old walk had none on the BODY read, so
      // one host that accepted the connection and then trickled could stall the whole check.
      final replies = await Future.wait(locs.map((loc) =>
          _fetchSigned(client, loc, trusted, threshold)
              .timeout(_perLocationBudget, onTimeout: () => null)));

      Map<String, dynamic>? best;
      var bestAt = -1;
      for (final man in replies) {
        if (man == null) continue;
        // ANTI-ROLLBACK. A signature proves a manifest is authentic, not that it is
        // CURRENT — an old one stays validly signed for ever. Without this, anyone able to
        // place a file where the app looks (which on a node means root, and on a host means
        // seizing it) could replay an earlier release and have it accepted as the truth.
        //
        // Monotonic against what this device has already seen, deliberately not against
        // the wall clock: a phone with a wrong date would otherwise lock itself out of
        // updates permanently.
        final builtAt = (man['built_at'] as num?)?.toInt() ?? 0;
        if (floor > 0 && builtAt < floor) continue;
        if (builtAt > bestAt) {
          best = man;
          bestAt = builtAt;
        }
      }
      if (best != null) await _rememberBuiltAt(bestAt);
      return best;
    } finally {
      // Also abandons any request still running past its budget.
      client.close(force: true);
    }
  }

  /// How long one manifest location may take, connect AND body together.
  static const Duration _perLocationBudget = Duration(seconds: 10);

  /// One location's manifest if it carries at least [threshold] trusted signatures, else null.
  /// Never throws: an unreachable or malformed location is simply not a candidate.
  static Future<Map<String, dynamic>?> _fetchSigned(
      HttpClient client, String loc, Set<String> trusted, int threshold) async {
    try {
      final man = await _fetchJson(client, loc);
      if (man == null) return null;
      if (await _countValidSignatures(man, trusted) < threshold) return null;
      return man;
    } catch (_) {
      return null;
    }
  }

  /// After downloading the artifact to [localPath], confirm SHA-256 matches.
  static Future<bool> verifyDownload(String localPath, UpdateArtifact art) async {
    final bytes = await File(localPath).readAsBytes();
    final got = pc.sha256.convert(bytes).toString().toLowerCase();
    return got == art.sha256.toLowerCase();
  }

  /// Download [art] from its mirrors (in order, first success wins), streaming to
  /// a temp file, then VERIFY the SHA-256 against the signed manifest before
  /// returning the path. Returns null if every mirror fails or the hash mismatches
  /// (a mismatched file is deleted — never handed back). [onProgress] receives
  /// 0.0–1.0 when the mirror reports a content length.
  static Future<String?> downloadVerifiedArtifact(
    UpdateArtifact art, {
    void Function(double progress)? onProgress,
  }) async {
    if (art.mirrors.isEmpty) return null;
    final tmpDir = Directory.systemTemp.createTempSync('sov_update_');
    final ext = _artifactExt(art.mirrors.first);
    final outPath = '${tmpDir.path}${Platform.pathSeparator}sov-${art.version}$ext';
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      // Published mirrors first — they are fast and usually up.
      for (final mirror in art.mirrors) {
        if (await _fetchAndVerify(client, mirror, outPath, art, onProgress)) return outPath;
      }
      // Then the NETWORK ITSELF. Every published mirror lives outside SOV — GitHub can be taken
      // down by a complaint, a gateway can throttle or vanish — and the network must not become
      // unusable when they do. These URLs are built from nodes THIS DEVICE DISCOVERED AT
      // RUNTIME, so no address is written into the manifest, the page, or the APK: the no-IP
      // law and self-sufficiency are only in tension if the addresses have to be published.
      // Any node can serve, so there is no single point of failure here either.
      for (final url in networkFallbackUrls(art)) {
        if (await _fetchAndVerify(client, url, outPath, art, onProgress)) return outPath;
      }
    } finally {
      client.close(force: true);
    }
    return null;
  }

  /// One attempt at one URL: stream to [outPath], verify the SHA-256 from the SIGNED manifest,
  /// and delete anything that does not match. A mismatch is a poisoned or truncated source, so
  /// the file is never handed back — which is also why a plain-HTTP node hop is safe here.
  static Future<bool> _fetchAndVerify(
    HttpClient client,
    String url,
    String outPath,
    UpdateArtifact art,
    void Function(double progress)? onProgress,
  ) async {
    final file = File(outPath);
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close();
      if (res.statusCode != 200) return false;
      final total = res.contentLength;
      var received = 0;
      final sink = file.openWrite();
      await for (final chunk in res) {
        received += chunk.length;
        sink.add(chunk);
        if (total > 0 && onProgress != null) onProgress(received / total);
      }
      await sink.flush();
      await sink.close();
      if (await verifyDownload(outPath, art)) {
        onProgress?.call(1.0);
        return true;
      }
      try { await file.delete(); } catch (_) {}
    } catch (_) {
      try { if (await file.exists()) await file.delete(); } catch (_) {}
    }
    return false;
  }

  /// Download URLs served by nodes this device has ALREADY DISCOVERED — never from a published
  /// list. The filename and CID are read back out of the mirror URLs the manifest already
  /// carries, so this needs no new manifest field and no re-signing: an app with this code
  /// recovers even from a manifest published before the node routes existed.
  ///
  /// Both node routes are tried: `/download/<file>` reads straight off the node's disk and works
  /// even if its IPFS daemon is down; `/ipfs/<cid>` is content-addressed.
  static List<String> networkFallbackUrls(UpdateArtifact art) {
    String? fileName, cid;
    for (final m in art.mirrors) {
      final u = Uri.tryParse(m);
      if (u == null || u.pathSegments.isEmpty) continue;
      if (u.pathSegments.contains('ipfs')) {
        cid ??= u.pathSegments.last;
      } else {
        fileName ??= u.pathSegments.last;
      }
    }
    final out = <String>[];
    for (final node in NodeDiscovery.all) {
      if (node.ip.isEmpty) continue;
      if (fileName != null && fileName.isNotEmpty) out.add('http://${node.ip}/download/$fileName');
      if (cid != null && cid.isNotEmpty) out.add('http://${node.ip}/ipfs/$cid');
    }
    return out;
  }

  /// Hand a verified artifact off to the OS to apply, then ask the app to exit so
  /// the file (a running exe can't overwrite itself) can be replaced.
  ///   • Windows / macOS: launch the installer/package DETACHED, then the caller
  ///     should exit(0). The installer swaps the bundle and relaunches.
  ///   • Other: returns false (caller shows "open the folder" guidance instead).
  /// Returns true if the apply process was launched.
  static Future<bool> launchInstaller(String localPath) async {
    try {
      if (Platform.isWindows) {
        await Process.start('cmd', ['/c', 'start', '', localPath],
            mode: ProcessStartMode.detached, runInShell: true);
        return true;
      }
      if (Platform.isMacOS) {
        await Process.start('open', [localPath],
            mode: ProcessStartMode.detached);
        return true;
      }
    } catch (_) {}
    return false;
  }

  static String _artifactExt(String url) {
    final path = Uri.tryParse(url)?.path ?? url;
    // A tarball must keep its full extension or the OS opens 'sov-1.2.1.gz' as a
    // bare gzip and the user gets a headless file (found 2026-09-22).
    if (path.toLowerCase().endsWith('.tar.gz')) return '.tar.gz';
    final dot = path.lastIndexOf('.');
    if (dot < 0) return Platform.isWindows ? '.exe' : '';
    final ext = path.substring(dot);
    if (ext.length > 6) return Platform.isWindows ? '.exe' : '';
    return ext;
  }

  // ── helpers ───────────────────────────────────────────────────────────────
  static Future<Map<String, dynamic>?> _fetchJson(
      HttpClient client, String loc) async {
    final uri = Uri.parse(loc);
    if (uri.scheme == 'file') {
      final txt = await File(uri.toFilePath()).readAsString();
      return jsonDecode(txt) as Map<String, dynamic>;
    }
    final req = await client.getUrl(uri);
    final res = await req.close();
    if (res.statusCode != 200) return null;
    final txt = await res.transform(utf8.decoder).join();
    return jsonDecode(txt) as Map<String, dynamic>;
  }

  static List<int> _hex(String h) {
    final out = <int>[];
    for (var i = 0; i + 1 < h.length; i += 2) {
      out.add(int.parse(h.substring(i, i + 2), radix: 16));
    }
    return out;
  }

  // Tuple version compare (mirrors updater.py _parse_version/is_newer).
  static bool _isNewer(String candidate, String current) {
    final a = _parseVersion(candidate);
    final b = _parseVersion(current);
    final n = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      final ai = i < a.length ? a[i] : 0;
      final bi = i < b.length ? b[i] : 0;
      if (ai != bi) return ai > bi;
    }
    return false;
  }

  static List<int> _parseVersion(String v) {
    // strip a build suffix ("1.2.7+3" → "1.2.7") and any leading 'v'
    final core = v.split('+').first.replaceFirst(RegExp(r'^v'), '');
    return core
        .split('.')
        .map((p) => int.tryParse(RegExp(r'\d+').firstMatch(p)?.group(0) ?? '0') ?? 0)
        .toList();
  }
}
