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
import 'package:cryptography/cryptography.dart' as sov_crypto;

class UpdateArtifact {
  final String version;
  final String sha256;
  final int sizeBytes;
  final List<String> mirrors;
  UpdateArtifact({
    required this.version,
    required this.sha256,
    required this.sizeBytes,
    required this.mirrors,
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
      ),
    );
  }

  /// Fetch the first signature-VALID manifest from [locations] (default list).
  /// Returns null if none reachable or none verifies.
  static Future<Map<String, dynamic>?> fetchVerifiedManifest({
    List<String>? locations,
    List<String> trustKeys = networkTrustKeys,
    int threshold = defaultThreshold,
  }) async {
    final locs = locations ?? manifestLocations;
    final trusted = trustKeys.map((k) => k.toLowerCase()).toSet();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      for (final loc in locs) {
        try {
          final man = await _fetchJson(client, loc);
          if (man == null) continue;
          if (await _countValidSignatures(man, trusted) >= threshold) return man;
        } catch (_) {
          // try the next location
        }
      }
    } finally {
      client.close(force: true);
    }
    return null;
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
      for (final mirror in art.mirrors) {
        final file = File(outPath);
        try {
          final req = await client.getUrl(Uri.parse(mirror));
          final res = await req.close();
          if (res.statusCode != 200) continue;
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
            return outPath;
          }
          // hash mismatch → poisoned/corrupt mirror; discard and try the next
          try { await file.delete(); } catch (_) {}
        } catch (_) {
          try { if (await file.exists()) await file.delete(); } catch (_) {}
        }
      }
    } finally {
      client.close(force: true);
    }
    return null;
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
