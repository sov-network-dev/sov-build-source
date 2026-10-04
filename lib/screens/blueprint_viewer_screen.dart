import 'package:flutter/material.dart';

/// SOV Network Blueprint — in-app, citizen-readable protocol documentation.
/// Replaces the old dead "opens in browser" stub. Everything is shown in-app
/// (the wallet never opens external URLs — IP-only, no DNS, per architecture law).
class BlueprintViewerScreen extends StatelessWidget {
  const BlueprintViewerScreen({super.key});

  static const _navy   = Color(0xFF0A1628);
  static const _gold   = Color(0xFFB8960C);
  static const _cardBg = Color(0xFF0D1F3A);
  static const _teal   = Color(0xFF006B5E);

  static const List<List<String>> _sections = [
    [
      '🌍  What SOV Is',
      'SOV is a sovereign money network owned by its citizens — no bank, no '
          'company, no government can freeze, seize, or inflate it. You hold your '
          'own keys on your own device. The network is run by independent nodes '
          'that anyone can operate and earn from.',
    ],
    [
      '🪙  Fixed Supply — 50,000,000 SOV',
      'The total supply is fixed forever at 50 million SOV. There is no premine, '
          'no founder allocation, and no team tokens — a true fair launch. Every '
          'SOV is either held in a citizen wallet or in a transparent network pool '
          'you can inspect live in the Economy view.',
    ],
    [
      '✋  Your Palm Is Your Identity',
      'You enroll with your palm — one real human, one account. No passwords, no '
          'usernames, no duplicates, no bots. Your biometric never leaves your '
          'device as raw data; only a private mathematical key derived from it is '
          'used to sign your transactions.',
    ],
    [
      '⚡  Sending & Receiving',
      'Pay anyone in seconds — by tapping phones together, scanning a QR code, or '
          'sending to their SOV ID. Transfers are signed on your device and settle '
          'across the node mesh at close to the speed of light.',
    ],
    [
      '🛡️  Funds That Can Never Be Lost',
      'Lock SOV for your family in a Vault with a claim key and private clues. '
          'While you stay active it is untouchable. If you are ever gone for 20 '
          'years with no proof-of-life, the network helps your family find and '
          'claim it. Return any time and your funds are instantly yours again — '
          'even idle funds are only ever stewarded, never burned.',
    ],
    [
      '🕵️  Private By Design',
      'Citizen traffic is wrapped in TLS and a 2-character dictionary protocol, so '
          'an observer on the wire cannot tell what operation you are performing. '
          'The network is identified by node addresses only — no central servers, '
          'no DNS trail.',
    ],
    [
      '🗳️  Governed By Citizens',
      'Every adjustable network parameter — fees, limits, durations, which features '
          'are active — is decided by citizen vote. There is no admin key and no '
          'back door: changes happen through governance polls, not by decree.',
    ],
    [
      '⚖️  Citizen Justice',
      'Disputes are resolved by randomly selected citizen juries who stake a bond '
          'and vote. No central authority decides — the community does, by a '
          'super-majority threshold the citizens themselves set.',
    ],
    [
      '🌐  The Network Runs Itself',
      'Anyone can run a node, serve the network, and earn SOV for proof of service. '
          'New nodes sync the full shared ledger automatically and converge on one '
          'identical state. The more citizens and operators join, the stronger and '
          'more decentralized it becomes.',
    ],
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _navy,
      appBar: AppBar(
        backgroundColor: _navy,
        foregroundColor: _gold,
        title: const Text('SOV Network Blueprint'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _teal.withAlpha(28),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _teal.withAlpha(90)),
            ),
            child: const Text(
              'How the SOV protocol works — the principles that make this network '
              'sovereign, fair, and impossible to capture.',
              style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.45),
            ),
          ),
          const SizedBox(height: 20),
          ..._sections.map((s) => Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: _cardBg,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _gold.withAlpha(40)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s[0],
                          style: const TextStyle(
                              color: _gold, fontSize: 15.5, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Text(s[1],
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 13, height: 1.5)),
                    ],
                  ),
                ),
              )),
          const SizedBox(height: 8),
          const Center(
            child: Text('One human · one account · one shared truth',
                style: TextStyle(color: Colors.white30, fontSize: 12, fontStyle: FontStyle.italic)),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
