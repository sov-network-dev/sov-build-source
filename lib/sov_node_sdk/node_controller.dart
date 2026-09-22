// lib/sov_node_sdk/node_controller.dart
// ─────────────────────────────────────────────────────────────────────────────
// Full-node SIDECAR controller (desktop only — Windows/macOS/Linux).
//
// Full parity port of the abandoned Python wallet's node_mode.py, PLUS Tailscale:
//   • spawn / stop the bundled Node.js sov-node, sealed to this wallet's sovId
//   • AUTO-START on login (Startup shortcut) → protects the 21-day uptime streak
//   • REACHABILITY: the node self-detects (UPnP→STUN→circuit-relay, no config) for
//     a normal router; for hard CGNAT the operator picks Tailscale Funnel (free, no
//     port-forward) or a static IP/port-forward → SOV_PUBLIC_HOST
//   • read the node's live status from its localhost dashboard (/node-info,/health)
//
// Data protection (useless even if the folder is copied): node DB AES-256 at rest,
// private keys never on the node, messages E2E ciphertext, biometrics cancelable,
// the wallet's own key PIN-encrypted.
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'dht_discovery.dart';

enum ReachMode { auto, tailscale, staticHost }

class NodeController {
  NodeController._();
  static final NodeController instance = NodeController._();

  Process? _node;
  Process? _tunnel; // tailscale funnel child, if any
  final ValueNotifier<bool> running = ValueNotifier<bool>(false);
  final ValueNotifier<String> lastLine = ValueNotifier<String>('');
  final ValueNotifier<String> publicHost = ValueNotifier<String>(''); // resolved reachable address

  // Running is not the same as serving. `running` means the process is alive;
  // `reachVerified` means a peer has actually reached us from outside, which is
  // the only thing that makes this machine useful to a citizen who is not on it.
  // Kept separate so the UI can stop claiming one when it only knows the other.
  final ValueNotifier<bool> reachVerified = ValueNotifier<bool>(false);
  final ValueNotifier<String> reachMethod = ValueNotifier<String>('');

  // What the operator is actually connected THROUGH. Which route the node picks
  // is decided by the network it finds itself on, so showing the verdict without
  // showing the inputs leaves them guessing: an operator who switches from a
  // router to a phone hotspot needs to see that the machine moved, not just that
  // the badge changed colour.
  final ValueNotifier<String> detectedPublicIp = ValueNotifier<String>('');
  final ValueNotifier<String> localNetwork = ValueNotifier<String>('');
  // This node's own id — surfaced ONLY to derive its deterministic name for the
  // operator's eyes. A human should recognise their node by its name, never its
  // IP (an IP on screen is a target for an attacker); the id itself is never shown.
  final ValueNotifier<String> nodeId = ValueNotifier<String>('');

  /// Active adapter + its private address, e.g. "Wi-Fi · 192.168.1.18".
  Future<void> refreshNetworkInfo() async {
    try {
      final ifaces = await NetworkInterface.list(
          includeLoopback: false, type: InternetAddressType.IPv4);
      // Skip virtual adapters — Tailscale's 100.x and Hyper-V/WSL bridges are
      // not the link the node's traffic actually leaves by.
      for (final i in ifaces) {
        for (final a in i.addresses) {
          final ip = a.address;
          if (ip.startsWith('100.') || ip.startsWith('169.254.')) continue;
          if (i.name.toLowerCase().contains('vethernet') ||
              i.name.toLowerCase().contains('loopback')) continue;
          localNetwork.value = '${i.name} · $ip';
          return;
        }
      }
      localNetwork.value = '';
    } catch (_) {
      localNetwork.value = '';
    }
  }
  // When non-empty, the operator must click this Tailscale link ONCE to turn on
  // Funnel (free), then toggle the node on again. The UI shows it as a button so
  // no ACL/JSON editing is ever needed. Empty = nothing to do.
  final ValueNotifier<String> setupActionUrl = ValueNotifier<String>('');

  DateTime? _startedAt; // when the node process was last started (for uptime)
  /// How long the node has been running this session (null if not running).
  Duration? get uptime =>
      _startedAt == null ? null : DateTime.now().difference(_startedAt!);

  static bool get isDesktopPlatform =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
  bool get isRunning => _node != null;

  // ── locate bundled node + sov-node ─────────────────────────────────────────
  (String, String)? _locate() {
    final exeDir = p.dirname(Platform.resolvedExecutable);
    final nodeName = Platform.isWindows ? 'node.exe' : 'node';
    final roots = <String>[
      exeDir,                                // Windows: next to SovNode.exe; Linux: next to the binary
      p.join(exeDir, 'data', 'flutter_assets'),
      p.join(exeDir, '..', 'Resources'),     // macOS: SOV Node.app/Contents/Resources
      p.join(exeDir, 'lib'),                  // Linux: <bundle>/lib
      // Dev fallback when running from source (never hit in a shipped build,
      // which finds the node next to the executable). Read from SOV_DEV_NODE_DIR
      // so no developer's private folder layout is baked into the source.
      if ((Platform.environment['SOV_DEV_NODE_DIR'] ?? '').isNotEmpty)
        Platform.environment['SOV_DEV_NODE_DIR']!,
    ];
    for (final root in roots) {
      final entry = p.join(root, 'sov-node', 'src', 'index.js');
      if (!File(entry).existsSync()) continue;
      final bundled = p.join(root, 'node', nodeName);
      if (File(bundled).existsSync()) return (bundled, entry);
      final onPath = _which('node');
      if (onPath != null) return (onPath, entry);
    }
    return null;
  }

  bool get isAvailable => isDesktopPlatform && _locate() != null;

  String? _which(String bin) {
    try {
      final r = Process.runSync(Platform.isWindows ? 'where' : 'which', [bin]);
      if (r.exitCode == 0) {
        final line = (r.stdout as String).split('\n').first.trim();
        if (line.isNotEmpty && File(line).existsSync()) return line;
      }
    } catch (_) {}
    return null;
  }

  // ── start / stop ────────────────────────────────────────────────────────────
  /// Start the node. [reach] picks how it's reachable to citizens:
  ///   auto      → the node self-detects (UPnP/STUN/circuit-relay), no config
  ///   tailscale → expose via Tailscale Funnel (free, no port-forward, CGNAT-ok)
  ///   staticHost→ operator-provided public host[:port] (router port-forward)
  Future<void> start({
    required String sovereignId,
    String? dataDir,
    ReachMode reach = ReachMode.auto,
    String? staticHostValue,
    int servePort = 443,
  }) async {
    if (!isDesktopPlatform) throw 'Full node is desktop-only';
    if (_node != null) return;
    final loc = _locate();
    if (loc == null) throw 'Bundled node not found (node runtime + sov-node/src).';
    final (nodeBin, entry) = loc;

    // Resolve the public host for the chosen reachability mode (before node start,
    // since the node reads SOV_PUBLIC_HOST at boot).
    String host = '';
    switch (reach) {
      case ReachMode.auto:
        host = ''; // node self-detects
        break;
      case ReachMode.staticHost:
        host = (staticHostValue ?? '').trim();
        if (host.isEmpty) throw 'Static reachability needs a public host[:port].';
        break;
      case ReachMode.tailscale:
        host = await _startTailscaleFunnel(servePort);
        break;
    }
    publicHost.value = host;

    final env = Map<String, String>.from(Platform.environment);
    env['OPERATOR_SOVEREIGN_ID'] = sovereignId; // payouts credit THIS wallet
    env['SOV_NO_TRAY'] = '1'; // app owns the tray; node must not add a 2nd (blank) one
    if (dataDir != null) env['SOV_DATA_DIR'] = dataDir;
    if (host.isNotEmpty) env['SOV_PUBLIC_HOST'] = host;

    final proc = await Process.start(
      nodeBin, [entry],
      environment: env,
      workingDirectory: p.dirname(p.dirname(entry)),
      runInShell: false,
    );
    _node = proc;
    _startedAt = DateTime.now();
    running.value = true;
    reachVerified.value = false; // earned per run, never assumed from the last one
    reachMethod.value = '';
    detectedPublicIp.value = '';
    unawaited(refreshNetworkInfo()); // the link may have changed since last run

    // The node reports 'operator-configured' for Funnel, because all it sees is
    // a SOV_PUBLIC_HOST we handed it — it has no idea the host came from a
    // tunnel. WE do. Saying "Direct — the public host you configured" about a
    // Tailscale tunnel misdescribes the route the operator actually chose.
    if (reach == ReachMode.tailscale) reachMethod.value = 'tailscale-funnel';

    // Keep the node's own output. The card only ever showed the LAST line, so
    // stdout was effectively discarded and stderr thrown away outright — which
    // meant that when the node misbehaved there was nothing to look at. On
    // 2026-08-01 a node ran for an hour with an identity it never persisted and
    // we could not tell which data directory it had used, because every line it
    // printed saying so had already been dropped. An operator who hits a problem
    // needs a file they can read or send; so does whoever is debugging it.
    IOSink? sink;
    try {
      final f = File(p.join(
          Platform.environment['TEMP'] ?? Directory.systemTemp.path, 'sov-app-node.log'));
      sink = f.openWrite(mode: FileMode.append);
      sink.writeln('');
      sink.writeln('=== node start ${DateTime.now().toIso8601String()} ===');
      sink.writeln('  SOV_DATA_DIR   : ${dataDir ?? "(not set — node will pick its own)"}');
      sink.writeln('  SOV_PUBLIC_HOST: ${host.isEmpty ? "(none — self-detect)" : host}');
      sink.writeln('  reach mode     : $reach');
      sink.writeln('  nodeBin        : $nodeBin');
      sink.writeln('  entry          : $entry');
    } catch (_) {
      sink = null; // logging must never stop the node from starting
    }
    void record(String s) {
      final t = s.trimRight();
      if (t.isEmpty) return;
      lastLine.value = t.split('\n').last;
      try { sink?.writeln(t); } catch (_) {}

      // Read the node's own verdict on whether anyone can actually REACH us.
      //
      // The card used to say "Serving" the moment the process was alive, which
      // is true of a node behind a router that drops every inbound connection —
      // so it told the operator nothing. The node distinguishes the two now: a
      // method ending in '-unverified' means the address is detected but
      // unproven, and it is promoted only when a real peer arrives.
      for (final line in t.split('\n')) {
        if (line.contains('Node ID:')) {
          final m = RegExp(r'Node ID:\s*([0-9a-f]{16,})').firstMatch(line);
          if (m != null) nodeId.value = m.group(1)!;
        }
        if (line.contains('Reachability:')) {
          reachVerified.value = !line.contains('-unverified');
          final m = RegExp(r'Reachability:\s*(\S+)').firstMatch(line);
          // Don't let the node's 'operator-configured' overwrite what we already
          // know is a Funnel — we chose the mode, it only sees the host.
          if (m != null && reachMethod.value != 'tailscale-funnel') {
            reachMethod.value = m.group(1)!.replaceAll('-unverified', '');
          }
        } else if (line.contains('Inbound reachability PROVEN')) {
          reachVerified.value = true;
          // The node relabels the route on promotion (circuit-relay guessed at
          // boot becomes direct-inbound once something actually arrives). Pick
          // that up, or the badge and the route line contradict each other.
          final m = RegExp(r'\(([a-z\-]+)\)\s*$').firstMatch(line.trim());
          if (m != null) {
            reachMethod.value = m.group(1)!;
          } else if (reachMethod.value.startsWith('circuit-relay')) {
            reachMethod.value = 'direct-inbound';
          }
        } else if (line.contains('Detected public IP:')) {
          final m = RegExp(r'Detected public IP:\s*(\S+)').firstMatch(line);
          if (m != null) detectedPublicIp.value = m.group(1)!;
        }
      }
    }
    proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).listen(record);
    proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen(record);
    proc.exitCode.then((c) {
      try {
        sink?.writeln('=== node exited, code $c ===');
        sink?.flush().then((_) => sink?.close());
      } catch (_) {}
    });
    proc.exitCode.then((_) {
      _node = null;
      _startedAt = null;
      running.value = false;
      _stopDhtAnnounce();
    });

    // This machine is now serving. Publish that fact somewhere nobody can take
    // down, so a citizen who has never heard of it can still find it when every
    // mirror and domain is gone. Without this a desktop node is reachable only
    // through the pool — fine while the pool is reachable, useless the day it
    // isn't, which is exactly the day it matters.
    _startDhtAnnounce(reach, host);
  }

  // ── DHT presence ──────────────────────────────────────────────────────────
  // Only a machine genuinely accepting connections announces. A phone wallet
  // must never advertise itself as somewhere to connect to — it would hand
  // every new client an address that cannot answer.
  Timer? _dhtTimer;

  static const int _peerMeshPort = 7771;

  static final RegExp _ipv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');

  /// Whether this node's address is something the DHT can actually express.
  ///
  /// A DHT peer entry is FOUR BYTES OF IPv4 AND A PORT. There is no room in it
  /// for a hostname — so a node reached by name cannot be published there, and
  /// pretending otherwise is worse than silence:
  ///
  ///   * **Tailscale Funnel** reaches the node at `<machine>.<tailnet>.ts.net`.
  ///     The address the DHT would record is whatever public IP the announce
  ///     packet came from — the operator's home connection, where nothing is
  ///     listening. Every client that found it would try a dead address, and
  ///     the operator's home IP would be published for nothing.
  ///   * **A static host given as a name** has the same problem.
  ///
  /// Those nodes stay perfectly discoverable through the pool, which carries
  /// full URLs and is gossiped between nodes and mirrored publicly. The DHT is
  /// one rung of the ladder, not the whole of it.
  ///
  /// Note this only limits being FOUND. Looking others UP over the DHT works
  /// from behind any NAT, so a Funnel node still uses the DHT to find the
  /// network — it simply does not advertise itself there.
  static bool _dhtCanExpress(ReachMode reach, String host) {
    switch (reach) {
      case ReachMode.tailscale:
        return false;
      case ReachMode.staticHost:
        // Only a bare IPv4 literal can be published; a name cannot.
        return _ipv4.hasMatch(host.split(':').first.trim());
      case ReachMode.auto:
        // The node self-detects and is announced at whatever public IPv4 the
        // DHT sees. If UPnP/STUN did not actually open a path, the entry is a
        // dead target — but a harmless one: dial targets are verified before
        // use, so it costs one failed request and expires on its own.
        return true;
    }
  }

  void _startDhtAnnounce(ReachMode reach, String host) {
    _dhtTimer?.cancel();
    if (!_dhtCanExpress(reach, host)) {
      debugPrint('[NODE] Not announcing to the DHT — this node is reached by '
          'name (${reach.name}), which a DHT entry cannot carry. It stays '
          'discoverable through the pool.');
      return;
    }
    Future<void> beat() async {
      try {
        await DhtDiscovery.announce(_peerMeshPort);
      } catch (e) {
        // Announcing is best-effort. A blocked UDP path costs discoverability
        // through this one route; the node keeps serving regardless.
        debugPrint('[NODE] DHT announce skipped: $e');
      }
    }

    beat();
    // Re-announce well inside the DHT's expiry so the entry never lapses.
    _dhtTimer = Timer.periodic(const Duration(minutes: 15), (_) => beat());
  }

  void _stopDhtAnnounce() {
    _dhtTimer?.cancel();
    _dhtTimer = null;
  }

  Future<void> stop() async {
    _stopDhtAnnounce();
    final n = _node;
    _node = null;
    _startedAt = null;
    running.value = false;
    n?.kill();
    final t = _tunnel;
    _tunnel = null;
    t?.kill();
    // Tailscale Funnel runs via tailscaled (--bg), so killing _tunnel isn't enough —
    // best-effort reset so we stop publicly serving when the node stops.
    final ts = _which('tailscale') ??
        (Platform.isWindows ? r'C:\Program Files\Tailscale\tailscale.exe' : '/usr/bin/tailscale');
    if (File(ts).existsSync()) {
      try { await Process.run(ts, ['funnel', 'reset']); } catch (_) {}
    }
    publicHost.value = '';
    setupActionUrl.value = '';
  }

  // ── Tailscale presence + assisted install ──────────────────────────────────
  /// True if the Tailscale CLI is present on this machine.
  bool get isTailscaleInstalled => _tailscaleBin() != null;

  /// Whether Tailscale is signed in (has a MagicDNS name). Null if not installed.
  Future<bool> isTailscaleLoggedIn() async {
    final ts = _tailscaleBin();
    if (ts == null) return false;
    try {
      final r = await Process.run(ts, ['status', '--json']);
      if (r.exitCode != 0) return false;
      final j = jsonDecode(r.stdout as String) as Map<String, dynamic>;
      final dns = ((j['Self'] as Map?)?['DNSName'] as String? ?? '');
      return dns.isNotEmpty;
    } catch (_) { return false; }
  }

  /// Where the Tailscale CLI actually lives, per platform.
  ///
  /// PATH alone is not enough. On macOS the App Store and standalone builds keep
  /// the CLI INSIDE the app bundle and never put it on PATH, so an operator with
  /// Tailscale plainly running would be told it was not installed. Homebrew is
  /// the only macOS route that lands on PATH, and it differs between Apple
  /// silicon (/opt/homebrew) and Intel (/usr/local).
  List<String> _tailscaleCandidates() {
    if (Platform.isWindows) {
      return [
        r'C:\Program Files\Tailscale\tailscale.exe',
        r'C:\Program Files (x86)\Tailscale\tailscale.exe',
      ];
    }
    if (Platform.isMacOS) {
      return [
        // Bundled CLI — the usual case, and the one PATH never finds.
        '/Applications/Tailscale.app/Contents/MacOS/Tailscale',
        '/opt/homebrew/bin/tailscale',   // Homebrew, Apple silicon
        '/usr/local/bin/tailscale',      // Homebrew, Intel
      ];
    }
    // Linux
    return [
      '/usr/bin/tailscale',
      '/usr/local/bin/tailscale',
      '/snap/bin/tailscale',
    ];
  }

  String? _tailscaleBin() {
    final onPath = _which('tailscale');
    if (onPath != null) return onPath;
    for (final c in _tailscaleCandidates()) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  /// Install Tailscale on this machine WITHOUT the operator hunting for it.
  /// Windows: winget first (silent), else download the OFFICIAL signed MSI and
  /// run it (a normal Windows UAC prompt appears — expected; the app never
  /// requests elevation itself). The operator still signs in to their OWN
  /// Tailscale account afterwards (their own tailnet — no SOV central control).
  /// Returns when the CLI is present, or throws with a clear message.
  Future<void> installTailscale({void Function(String)? onProgress}) async {
    if (isTailscaleInstalled) return;
    if (!Platform.isWindows) {
      // Auto-install stays Windows-only on purpose: the operator installs
      // Tailscale themselves and signs in to THEIR OWN tailnet. Nothing about
      // this network provisions it for them.
      if (Platform.isMacOS) {
        throw 'Install Tailscale for macOS first:\n\n'
              '  • From tailscale.com/download, or\n'
              '  • brew install --cask tailscale\n\n'
              'Open it once and sign in, then come back and press this again.';
      }
      throw 'Install Tailscale for Linux first:\n\n'
            '  • Debian/Ubuntu:  sudo apt install tailscale\n'
            '  • Fedora:         sudo dnf install tailscale\n'
            '  • Arch:           sudo pacman -S tailscale\n\n'
            'Then:  sudo tailscale up   and   sudo tailscale set --operator=\$USER';
    }
    void say(String m) { onProgress?.call(m); lastLine.value = m; }

    // 1) winget (present on Windows 10 1809+/11) — silent, signed source.
    final winget = _which('winget');
    if (winget != null) {
      say('Installing Tailscale via winget…');
      try {
        final r = await Process.run(winget, [
          'install', '--id', 'Tailscale.Tailscale', '-e', '--silent',
          '--accept-source-agreements', '--accept-package-agreements',
        ]).timeout(const Duration(minutes: 5));
        if (isTailscaleInstalled) { say('Tailscale installed.'); return; }
        // winget may exit 0 but PATH not refreshed this session — fall through
        if (r.exitCode != 0) debugPrint('winget tailscale rc=${r.exitCode}: ${r.stderr}');
      } catch (e) { debugPrint('winget install failed: $e — falling back to MSI'); }
    }

    // 2) Official MSI download + msiexec (UAC prompt expected).
    say('Downloading the official Tailscale installer…');
    final tmp = p.join(Directory.systemTemp.path, 'tailscale-setup-sov.msi');
    const url = 'https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi';
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw 'Download failed (HTTP ${resp.statusCode}). Install Tailscale from tailscale.com manually.';
      }
      final f = File(tmp);
      await resp.pipe(f.openWrite());
      say('Running the installer (approve the Windows prompt)…');
      final r = await Process.run('msiexec', ['/i', tmp, '/qb', '/norestart'])
          .timeout(const Duration(minutes: 10));
      if (!isTailscaleInstalled && r.exitCode != 0) {
        throw 'Installer exited ${r.exitCode}. If a prompt was declined, re-run "Install Tailscale".';
      }
      say('Tailscale installed.');
    } finally {
      client.close(force: true);
      try { File(tmp).deleteSync(); } catch (_) {}
    }
    if (!isTailscaleInstalled) {
      throw 'Tailscale install did not complete. Try again, or install from tailscale.com.';
    }
  }

  // When non-empty, the operator must open THIS URL in a browser to sign in to
  // THEIR OWN Tailscale account (SSO to Google/Microsoft/GitHub/email — SOV never
  // sees the credentials). The UI opens it and shows it as a button. Cleared when
  // sign-in completes. This is the only way Tailscale auth works — there is no
  // in-app password form because the identity lives with the operator's provider.
  final ValueNotifier<String> tailscaleLoginUrl = ValueNotifier<String>('');

  /// Bring Tailscale up on the operator's OWN account. Starts `tailscale up`,
  /// captures the browser login URL it emits (surfaced via [tailscaleLoginUrl] so
  /// the UI opens it), then polls until the device has joined their tailnet.
  /// No-op if already signed in. Their account, their tailnet — SOV holds no key.
  Future<void> tailscaleUp({Duration timeout = const Duration(minutes: 4)}) async {
    final ts = _tailscaleBin();
    if (ts == null) throw 'Tailscale is not installed yet.';
    if (await isTailscaleLoggedIn()) return;
    tailscaleLoginUrl.value = '';

    // Start (not run) so we can read the login URL live. `up` blocks until auth
    // completes; with the Tailscale GUI installed it also auto-opens the browser,
    // but we capture + surface the URL regardless so a headless box still works.
    final proc = await Process.start(ts, ['up']);
    void scan(String s) {
      final m = RegExp(r'https://login\.tailscale\.com/\S+').firstMatch(s);
      if (m != null) {
        tailscaleLoginUrl.value = m.group(0)!.replaceAll(RegExp(r'[).,\s]+$'), '');
      }
    }
    proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).listen(scan);
    proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen(scan);

    // Poll until the device joins their tailnet (a MagicDNS name appears).
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(seconds: 3));
      if (await isTailscaleLoggedIn()) {
        tailscaleLoginUrl.value = '';
        try { proc.kill(); } catch (_) {}
        return;
      }
    }
    try { proc.kill(); } catch (_) {}
    throw 'Sign-in not finished in time. Tap "Open Tailscale sign-in", complete it '
        'in your browser, then try again.';
  }

  // ── reachability: Tailscale Funnel (the pivot) ──────────────────────────────
  /// Detect tailscale, expose [port] via Funnel, return the public MagicDNS host.
  /// Run a command with stdin CLOSED and a hard timeout, then kill it.
  ///
  /// Anything that might prompt must be launched this way. A CLI waiting on a
  /// question the GUI cannot answer looks identical to a hung app, and the user
  /// is given nothing to act on.
  Future<ProcessResult> _runNoStdin(String exe, List<String> args, Duration limit) async {
    final p = await Process.start(exe, args, runInShell: false);
    await p.stdin.close();
    final out = StringBuffer(), err = StringBuffer();
    final done = Future.wait([
      p.stdout.transform(const Utf8Decoder(allowMalformed: true)).forEach(out.write),
      p.stderr.transform(const Utf8Decoder(allowMalformed: true)).forEach(err.write),
      p.exitCode,
    ]);
    int code;
    try {
      code = (await done.timeout(limit))[2] as int;
    } on TimeoutException {
      p.kill(ProcessSignal.sigkill);
      throw '${args.first} timed out after ${limit.inSeconds}s — it is waiting for '
            'input the app cannot give.\n\n${out.toString()}${err.toString()}'.trim();
    }
    return ProcessResult(p.pid, code, out.toString(), err.toString());
  }

  Future<String> _startTailscaleFunnel(int port) async {
    final ts = _which('tailscale') ??
        (Platform.isWindows
            ? r'C:\Program Files\Tailscale\tailscale.exe'
            : '/usr/bin/tailscale');
    if (!File(ts).existsSync() && _which('tailscale') == null) {
      throw 'Tailscale not installed. Install from tailscale.com, then sign in.';
    }
    // Public hostname = this node's MagicDNS name (tailscale status --json → Self.DNSName)
    String dns = '';
    try {
      final r = await Process.run(ts, ['status', '--json']);
      if (r.exitCode == 0) {
        final j = jsonDecode(r.stdout as String) as Map<String, dynamic>;
        dns = ((j['Self'] as Map?)?['DNSName'] as String? ?? '').replaceAll(RegExp(r'\.$'), '');
      }
    } catch (_) {}
    if (dns.isEmpty) throw 'Tailscale is not signed in (no MagicDNS name). Run: tailscale up';
    // Expose the port publicly via Funnel (background). We RUN (not start) so we can
    // read the result: if Funnel isn't turned on for this tailnet yet, Tailscale
    // returns a one-click approval URL — we surface that to the operator instead of
    // making them hand-edit ACL policy JSON.
    //
    // CRITICAL (2026-07-24): the node serves WSS/TLS on :port with a SELF-SIGNED
    // cert. The old `funnel <port>` target proxied PLAINTEXT (http://localhost:port)
    // into that TLS port — a protocol mismatch that silently failed, so no citizen
    // could ever connect. The correct target for a self-signed HTTPS backend is
    // `https+insecure://localhost:<port>` (documented in `tailscale funnel --help`):
    // Tailscale terminates public TLS with a real Let's Encrypt cert for the ts.net
    // name and re-proxies to the node over HTTPS, accepting its self-signed cert —
    // and WebSocket upgrades pass straight through. Citizens then reach
    // wss://<dns> with a VALID cert.
    ProcessResult r;
    try {
      // NOT Process.run. `tailscale funnel` PROMPTS on first use, and Process.run
      // gives the child no stdin, so it waits for an answer that can never
      // arrive — forever. start() then never returns, the node never spawns, and
      // the toggle silently does nothing with no error anywhere. Observed live
      // 2026-08-02: the operator could only ever use `auto`, because picking
      // Funnel wedged the switch. `serve` returns straight away because it does
      // not prompt, which is what made the difference visible.
      //
      // So: close stdin (a prompt then sees EOF and gives up instead of
      // blocking), and cap the wait. A Funnel that cannot be set up in 25s is
      // not going to be set up by waiting longer — report it and let the
      // operator act.
      r = await _runNoStdin(ts, ['funnel', '--bg', 'https+insecure://localhost:$port'],
          const Duration(seconds: 25));
      // On Linux the CLI talks to tailscaled over a root-owned socket. Unless the
      // operator has been granted access, this fails with a permissions error that
      // says nothing about the one command that fixes it — so say it here.
      if (Platform.isLinux && r.exitCode != 0) {
        final err = '${r.stderr}'.toLowerCase();
        if (err.contains('permission') || err.contains('access denied') ||
            err.contains('operator') || err.contains('not permitted')) {
          throw 'Tailscale needs permission to run as you.\n\n'
                'Run this once, then try again:\n'
                '    sudo tailscale set --operator=\$USER\n\n'
                '(Linux only — Windows and macOS handle this for you.)';
        }
      }
    } catch (e) {
      // The timeout path lands here, and it must NOT lose the enable URL.
      // Tailscale prints "Funnel is not enabled on your tailnet / To enable,
      // visit: <url>" and then waits at a prompt — so the message we need is in
      // the output we captured before killing it. Throwing plainly put that URL
      // in a snackbar that vanished before the operator could click it
      // (observed 2026-08-02). Surface it as the persistent button instead.
      final m = RegExp(r'https://login\.tailscale\.com/\S+').firstMatch('$e');
      if (m != null) {
        setupActionUrl.value = m.group(0)!.replaceAll(RegExp(r'[).,\s]+$'), '');
        throw 'Tailscale Funnel needs ONE click to turn on (free, no setup). '
            'Tap "Enable Tailscale Funnel" below, approve in your browser, then '
            'switch the node ON again.';
      }
      throw 'Could not start Tailscale Funnel: $e';
    }
    if (r.exitCode != 0) {
      final out = '${r.stdout}\n${r.stderr}';
      final m = RegExp(r'https://login\.tailscale\.com/\S+').firstMatch(out);
      if (m != null) {
        final url = m.group(0)!.replaceAll(RegExp(r'[).,\s]+$'), '');
        setupActionUrl.value = url;
        throw 'Tailscale Funnel needs ONE click to turn on (free, no setup). '
            'Tap "Enable Tailscale Funnel" below, approve in your browser, then '
            'switch the node ON again.';
      }
      throw 'Could not start Tailscale Funnel: ${(r.stderr as String).trim()}';
    }
    setupActionUrl.value = ''; // success — clear any prior prompt
    return dns; // citizens reach the node at https://<dns> (Funnel terminates TLS)
  }

  // ── auto-start on login (Startup shortcut → uptime streak) ───────────────────
  String? _startupDir() {
    final appdata = Platform.environment['APPDATA'];
    if (appdata == null) return null;
    return p.join(appdata, 'Microsoft', 'Windows', 'Start Menu', 'Programs', 'Startup');
  }

  String? _startupLnk() {
    final d = _startupDir();
    return d == null ? null : p.join(d, 'SOV.lnk');
  }

  bool get isAutostartEnabled {
    final lnk = _startupLnk();
    return lnk != null && File(lnk).existsSync();
  }

  Future<void> enableAutostart() async {
    if (!Platform.isWindows) return; // (macOS/Linux: future — LaunchAgent/.desktop)
    final lnk = _startupLnk();
    if (lnk == null) throw 'Could not resolve the Windows Startup folder.';
    Directory(p.dirname(lnk)).createSync(recursive: true);
    final target = Platform.resolvedExecutable;
    final ps =
        "\$s=(New-Object -ComObject WScript.Shell).CreateShortcut('${lnk.replaceAll("'", "''")}');"
        "\$s.TargetPath='${target.replaceAll("'", "''")}';"
        "\$s.WorkingDirectory='${p.dirname(target).replaceAll("'", "''")}';"
        "\$s.Description='SOV — auto-start to keep the node uptime streak';\$s.Save()";
    final r = await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-Command', ps]);
    if (r.exitCode != 0) throw 'Auto-start setup failed: ${r.stderr}';
  }

  Future<void> disableAutostart() async {
    final lnk = _startupLnk();
    if (lnk != null) {
      try {
        File(lnk).deleteSync();
      } catch (_) {}
    }
  }

  /// Canonical node data dir (DB + identity). Both the manual "Run a Node" toggle
  /// and [maybeAutoStart] resolve to this so they share one node identity.
  Future<String> resolveDataDir() async {
    final docs = await getApplicationSupportDirectory();
    return p.join(docs.path, 'sov-node-data');
  }

  // ── Intelligent full-node auto-start ────────────────────────────────────────
  // On app launch (wallet already restored → the operator is a verified citizen,
  // no re-scan needed), bring the node up on its own in the best reachability mode
  // the machine already supports — zero clicks — so an idle desktop with a working
  // router, a public IP, or a configured Tailscale becomes a serving node by itself.
  // Never throws: any failure simply leaves the node off and the app launches fine.
  //
  //   [preferred] = the operator's saved mode. If they chose tailscale/static and
  //   it is not ready, the node REFUSES TO START and says why — it does not fall
  //   back to `auto`. See the comment at the mode check below: falling back gave a
  //   CGNAT operator the one mode that cannot work for them, silently, while
  //   publishing their home IP to every citizen.
  //
  //   `auto` remains the default for operators who never chose otherwise: it
  //   self-detects UPnP → STUN → circuit-relay, so an ordinary home router "just
  //   works". It is a fine default and a bad substitute for a deliberate choice.
  Future<void> maybeAutoStart({
    required String sovereignId,
    String? dataDir,
    bool enabled = true,
    ReachMode preferred = ReachMode.auto,
    String? staticHostValue,
  }) async {
    if (!isDesktopPlatform || !enabled || sovereignId.isEmpty) return;
    if (running.value || _node != null) return;
    if (!isAvailable) return; // bundled node runtime + src must be present
    // ADOPT an already-serving local node. On an app UPDATE/relaunch the previous
    // node.exe can outlive the app and keep holding :443/:7771/:8080; spawning a
    // second one just fails to bind and silently leaves the toggle OFF (the exact
    // "node off after rebuild" bug). If one is already healthy, adopt it.
    if (await _localNodeAlive()) { running.value = true; return; }
    try {
      dataDir ??= await resolveDataDir(); // same DB/identity as a manual start
      ReachMode mode = preferred;

      // REFUSE, do not downgrade. This used to silently rewrite the operator's
      // chosen mode to `auto` and start anyway.
      //
      // Why that was wrong, observed live on 2026-08-01: an operator picks
      // Tailscale Funnel PRECISELY BECAUSE `auto` cannot work for them — they are
      // behind CGNAT or a router they do not control. Downgrading them to `auto`
      // gives them the one mode that cannot succeed, and says nothing. The node
      // then registers its raw home IP into the relay pool, shows a green
      // "Serving" badge, and is unreachable from outside on every port. Every
      // citizen who tries that address fails, and the operator has published
      // their home address for nothing.
      //
      // Refusing is the honest outcome: the node stays off, `lastLine` says why,
      // and the operator can fix the one thing that is actually missing. A node
      // that cannot serve in the mode it was told to use must not pretend to.
      if (mode == ReachMode.tailscale && !(await isTailscaleLoggedIn())) {
        lastLine.value =
            'Node not started — Tailscale Funnel is selected but you are not '
            'signed in to Tailscale. Sign in, then turn the node on. '
            '(Starting in "auto" instead would publish this computer\'s IP '
            'address, which is not reachable from outside.)';
        running.value = false;
        return;
      }
      if (mode == ReachMode.staticHost && (staticHostValue ?? '').trim().isEmpty) {
        lastLine.value =
            'Node not started — a fixed public address is selected but none has '
            'been entered. Add the host, then turn the node on.';
        running.value = false;
        return;
      }
      await start(
        sovereignId: sovereignId,
        dataDir: dataDir,
        reach: mode,
        staticHostValue: staticHostValue,
      );
      // Confirm it actually bound the ports. If a stale instance was still
      // releasing :443, the freshly-spawned child exits within a second or two —
      // wait for the port to free, then retry once so a transient conflict never
      // leaves the operator's node dark (which would break the uptime streak).
      await Future.delayed(const Duration(seconds: 3));
      if (!(await _localNodeAlive())) {
        await stop();
        await Future.delayed(const Duration(seconds: 3));
        if (await _localNodeAlive()) { running.value = true; return; } // one came up — adopt
        await start(
          sovereignId: sovereignId,
          dataDir: dataDir,
          reach: mode,
          staticHostValue: staticHostValue,
        );
      }
    } catch (_) { /* leave node off — never break app launch */ }
  }

  /// True if a local bundled node is already serving (its dashboard answers).
  /// Used to adopt an orphaned node instead of spawning a conflicting duplicate.
  Future<bool> _localNodeAlive() async {
    try { return (await nodeStatus()) != null; } catch (_) { return false; }
  }

  // ── read the node's live status from its localhost dashboard ────────────────
  Future<Map<String, dynamic>?> nodeStatus({int dashboardPort = 8080}) async {
    for (final path in ['/node-info', '/health', '/economy/snapshot']) {
      try {
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
        final req = await client.getUrl(Uri.parse('http://127.0.0.1:$dashboardPort$path'));
        final res = await req.close();
        final body = await res.transform(utf8.decoder).join(); // always drain
        client.close();
        if (res.statusCode == 200) {
          try {
            return jsonDecode(body) as Map<String, dynamic>;
          } catch (_) {
            return {'up': true, 'endpoint': path};
          }
        }
        // ANY HTTP response means the node's dashboard is listening — including a
        // 302 redirect to /dashboard/login (the node gates /node-info behind auth).
        // Treating only 200 as "alive" made adoption ALWAYS fail, so every relaunch
        // spawned a duplicate that collided on :7771 (EADDRINUSE) and went dark.
        if (res.statusCode > 0) {
          return {'up': true, 'endpoint': path, 'http_status': res.statusCode};
        }
      } catch (_) {}
    }
    return null;
  }
}
