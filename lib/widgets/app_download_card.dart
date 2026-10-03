// lib/widgets/app_download_card.dart
// ─────────────────────────────────────────────────────────────────────────────
// THE ACADEMY'S DOWNLOAD CARD — the network handing out its own software.
//
// Every route to SOV used to run through somebody else's host, and both documented
// fallbacks led back to the same one: the rented IPFS gateway answers nothing for every
// published address, and the torrent leg seeds from nodes whose peer port the cloud
// firewall closes inbound, so it only ever completed through its web seed, which points
// at the primary host.
//
// NO ADDRESS IS SHOWN HERE. Not a page, not a node. The king's rule is that the protocol
// must reveal no IP and no link that can be reported to a host, and a download URL carries
// its source in plain sight — `http://<node>/ipfs/<cid>` names the machine in its first
// characters. So this card renders a version, a button and a progress bar, and the
// addresses it displays are of the BYTES: a sha256, a content id, a magnet. None of those
// has a host, so there is no addressee for a take-down notice.
//
// WHERE THE BYTES COME FROM is `UpdateService.downloadVerifiedArtifact`, which already
// existed and already resolves nodes this device discovered at runtime. That is permitted
// precisely because those addresses arrived through in-network channels
// (IP_INVISIBLE_RELAY_PROTOCOL section 2 point 4); what is forbidden is publishing them.
// It fetches with an in-process client, so no system download manager, browser history,
// notification or copy-link ever sees the URL, and `update_service.dart` contains no
// logging, so it is written nowhere.
//
// AND IT IS HASH-CHECKED BEFORE IT COUNTS. The bytes are compared with the sha256 in the
// signature-verified manifest; a mismatch is deleted rather than handed back. That is what
// makes an unencrypted hop harmless — a hostile network can waste the download, it cannot
// substitute the software.
//
// iOS shows the honest answer instead of a dead button: an iPhone cannot install from
// outside the App Store, so the manifest deliberately carries no iOS artifact.
// ─────────────────────────────────────────────────────────────────────────────
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../sov_node_sdk/app_share.dart';
import '../sov_node_sdk/update_service.dart';

const Color _gold = Color(0xFFD4AF37);

class AppDownloadCard extends StatefulWidget {
  const AppDownloadCard({super.key});

  @override
  State<AppDownloadCard> createState() => _AppDownloadCardState();
}

class _AppDownloadCardState extends State<AppDownloadCard> {
  UpdateArtifact? _art;
  bool _loading = true;
  bool _noArtifact = false;

  /// Every platform in the signed manifest, so the addresses can be handed to
  /// someone on a different device. The download button stays this-device-only,
  /// because that is the only build this machine can install.
  SharePointer? _all;
  bool _downloading = false;
  double _progress = 0;
  String? _savedPath;
  String? _error;
  bool _showAddresses = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // ONE fetch, both results. Calling the two resolvers separately ran the whole
    // network walk and the Ed25519 verification TWICE on a single screen open, which
    // produced an ANR on the emulator - and could also land on two different manifests
    // mid-release, leaving the button and the address list disagreeing on the version.
    final man = await UpdateService.fetchVerifiedManifest();
    final art = man == null ? null : await AppShare.localArtifact(manifest: man);
    final all = man == null ? null : await AppShare.compose(manifest: man);
    if (!mounted) return;
    setState(() {
      _art = art;
      _all = all;
      _noArtifact = art == null;
      _loading = false;
    });
  }

  Future<void> _download() async {
    final art = _art;
    if (art == null || _downloading) return;
    setState(() {
      _downloading = true;
      _progress = 0;
      _error = null;
      _savedPath = null;
    });
    // No URL is passed in or out of this call by us: the service resolves its own, published
    // mirrors first and then nodes this device discovered. Deliberately not surfaced.
    final path = await UpdateService.downloadVerifiedArtifact(
      art,
      onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      },
    );
    if (!mounted) return;
    setState(() {
      _downloading = false;
      _savedPath = path;
      // A null path means every source failed OR the hash did not match. Both are reported
      // the same way on purpose: a file that fails its hash is not a download that needs
      // retrying, it is one that must not be used.
      _error = path == null
          ? 'Could not get a copy that matches the signed manifest. Nothing was saved.'
          : null;
    });
  }


  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _gold.withAlpha(10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _gold.withAlpha(45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(children: [
            Icon(Icons.download_outlined, color: _gold, size: 20),
            SizedBox(width: 8),
            Text('Get SOV from the network',
                style: TextStyle(
                    color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 6),
          const Text(
            'Served by the nodes themselves, not by any company. '
            'Every copy is checked against the signed release before it counts.',
            style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 12),
          if (_loading)
            const _Line('Checking the signed release…')
          else if (_noArtifact)
            const _Line(
                'There is no installable copy for this device. On iPhone, apps can only '
                'come from the App Store — share the addresses below with someone on '
                'Android, Windows, macOS or Linux.')
          else ...[
            _Line('Version ${_art!.version}'
                '${_art!.sizeBytes > 0 ? '  ·  ${(_art!.sizeBytes / 1048576).round()} MB' : ''}'),
            const SizedBox(height: 10),
            if (_downloading) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _progress > 0 ? _progress : null,
                  minHeight: 6,
                  backgroundColor: Colors.white12,
                  valueColor: const AlwaysStoppedAnimation<Color>(_gold),
                ),
              ),
              const SizedBox(height: 6),
              _Line(_progress > 0
                  ? '${(_progress * 100).round()}%  ·  verifying on completion'
                  : 'Starting…'),
            ] else
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _download,
                  icon: const Icon(Icons.download, size: 18),
                  label: Text(_savedPath == null ? 'Download' : 'Download again'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _gold,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            if (_savedPath != null) ...[
              const SizedBox(height: 8),
              const Row(children: [
                Icon(Icons.verified_outlined, color: _gold, size: 16),
                SizedBox(width: 6),
                Expanded(
                  child: Text('Saved and verified against the signed release.',
                      style: TextStyle(color: _gold, fontSize: 12)),
                ),
              ]),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: const TextStyle(color: Color(0xFFE57373), fontSize: 12)),
            ],
          ],
          const SizedBox(height: 10),
          InkWell(
            onTap: () => setState(() => _showAddresses = !_showAddresses),
            child: Row(children: [
              Icon(_showAddresses ? Icons.expand_less : Icons.expand_more,
                  color: Colors.white54, size: 18),
              const SizedBox(width: 4),
              const Text('Verify this yourself, or pass it on',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
            ]),
          ),
          if (_showAddresses) _addresses(),
        ],
      ),
    );
  }

  Widget _addresses() {
    final all = _all;
    if (all == null) {
      return const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text(
          'Addresses appear once the signed release has been read.',
          style: TextStyle(color: Colors.white38, fontSize: 11),
        ),
      );
    }

    final me = UpdateService.thisPlatform();
    final rows = <Widget>[];

    for (final a in all.artifacts) {
      // Through AppShare so the host-address guard runs on anything heading for the screen.
      final lines = AppShare.displayAddresses(a, _fileNameFor(a.platform));
      final mine = a.platform == me || a.platform.startsWith(me);
      rows.add(Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 2),
        child: Row(children: [
          Text(_label(a.platform),
              style: TextStyle(
                  color: mine ? _gold : Colors.white60,
                  fontSize: 11.5,
                  fontWeight: FontWeight.bold)),
          if (mine) ...[
            const SizedBox(width: 6),
            const Text('this device',
                style: TextStyle(color: Colors.white38, fontSize: 10)),
          ],
        ]),
      ));
      for (final l in lines) {
        rows.add(Padding(
          padding: const EdgeInsets.only(bottom: 5),
          child: InkWell(
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: l));
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Copied')),
              );
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(l,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 10.5, fontFamily: 'monospace')),
            ),
          ),
        ));
      }
    }

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'These name the file itself, not a website or a machine. Anyone can serve them, '
            'and there is nothing here to report or shut down. Every platform is listed so you '
            'can pass on the one someone else needs.',
            style: TextStyle(color: Colors.white38, fontSize: 11, height: 1.4),
          ),
          ...rows,
        ],
      ),
    );
  }

  static String _label(String platform) {
    switch (platform) {
      case 'android':
        return 'Android';
      case 'windows':
        return 'Windows';
      case 'linux':
        return 'Linux';
      case 'macos_arm64':
        return 'macOS (Apple Silicon)';
      case 'macos_x64':
        return 'macOS (Intel)';
      case 'macos':
        return 'macOS';
      default:
        return platform;
    }
  }

  static String _fileNameFor(String platform) {
    switch (platform) {
      case 'android':
        return 'sovnode-android.apk';
      case 'windows':
        return 'sovnode-windows-x64.zip';
      case 'linux':
        return 'sovnode-linux-x64.AppImage';
      case 'macos_arm64':
        return 'sovnode-macos-arm64.tar.gz';
      case 'macos_x64':
        return 'sovnode-macos-x64.tar.gz';
      default:
        return 'sovnode-$platform';
    }
  }
}

class _Line extends StatelessWidget {
  const _Line(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(color: Colors.white70, fontSize: 12, height: 1.4));
}
