// lib/screens/pioneer_screen.dart — Session H: Pioneer Certification System
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../sov_node_sdk/relay_connector.dart';

// ── State machine ─────────────────────────────────────────────────────────────
enum _PState { loading, choosing, guide, assessment, results }

// ── Guide section ─────────────────────────────────────────────────────────────
class _Section {
  final String title;
  final String body;
  const _Section(this.title, this.body);
}

// ── Knowledge guides ─────────────────────────────────────────────────────────
const _guides = <String, List<_Section>>{
  'relay_engineer': [
    _Section('What is a SOV Relay?',
        'A SOV relay is a lightweight server node that stores the SOV disc — the distributed ledger of all citizen identities and balances. Each relay holds a full copy of the disc and processes incoming transactions in real time.\n\nRelays communicate with each other through the SOV native protocol over a persistent mesh connection. The SOV Node app connects to the relay over a WebSocket link. The relay also serves a discovery page so citizens can find it.'),
    _Section('How a Transaction Confirms',
        'When a citizen sends a transaction, it goes to the node they are connected to. That node validates it — checking the sender\'s nonce chain and reserving the amount with a spend lock so it cannot be double-spent — and applies it immediately. The change then spreads across the mesh as nodes reconcile with each other.\n\nThere is no single point of failure and no mining: if one node is down, citizens simply use another, and confirmation is near-instant. The offline node catches up automatically when it returns.'),
    _Section('How Nodes Stay in Sync',
        'Nodes do not push the whole ledger around. Instead, each node advertises a compact fingerprint of its state a few times a minute; a node that is behind asks a peer for just the missing pieces and applies them, with the highest-version balance winning.\n\nThis background reconciliation is self-healing: a node that was switched off for a week catches up the instant it reconnects, with no operator action and no central authority to ask. It is what keeps every independent node showing the same balances.'),
    _Section('Why Lookups Stay Fast at Scale',
        'Every citizen\'s balance is stored under their Sovereign ID, so a node can look up any citizen\'s balance instantly — no matter how many citizens exist — without scanning or searching. That is what lets the network stay fast as it grows toward millions of citizens.\n\nEach node holds the current state, not an ever-growing chain of history, which keeps a node compact. History that a citizen wants to keep lives on their own device.'),
    _Section('Running a Relay Node',
        'The minimum hardware is a VPS with 1 GB RAM and 30 GB storage running Ubuntu 22.04 or later. Install the SOV relay using the Snap package with one command. The relay auto-connects to the peer mesh using embedded bootstrap relay addresses.\n\nThe relay manages all data storage internally — no manual database setup required. Process management and auto-restart are handled automatically by the Snap runtime.'),
    _Section('Discovery Page and Snap Downloads',
        'Each relay serves a human-readable discovery page listing its current status and connection details. It also hosts the relay Snap package so new operators can download and install a relay node directly.\n\nWhen the citizen count passes a growth threshold, operators receive a signal to regenerate and re-upload their hosted Snap so the latest version is always available to new operators joining the network.'),
    _Section('Relay Database Recovery',
        'If a relay\'s database is wiped accidentally, it can recover by requesting a full disc sync from any healthy peer relay. The peer sends the entire current disc state, which the recovering relay applies to rebuild its database.\n\nThis recovery process is automatic. The relay detects an empty database on startup and initiates recovery before accepting citizen connections. No manual intervention is required.'),
    _Section('Staying Connected and Self-Healing',
        'Nodes stay connected to their neighbours continuously, so updates flow the instant they happen — no polling, no delay. Each node also watches those links: if a connection goes silently dead, the node notices the silence, drops the dead link, and reconnects on its own.\n\nThis self-watching is why the mesh keeps converging even as nodes come and go — a home node that loses power and returns simply rejoins and catches up. Operators do not manage any of this by hand; the node keeps itself healthy.'),
  ],
  'enrollment_agent': [
    _Section('The Biometric Commitment',
        'When a citizen enrolls, their palm scan is processed on-device into a biometric commitment — a cryptographic value that can verify palm ownership without storing the palm image anywhere.\n\nOnly the commitment data is sent to the relay. The relay can verify a future palm scan against the stored commitment without ever seeing the actual palm image. Your biometric never leaves your device.'),
    _Section('Sovereign ID Structure',
        'A Sovereign ID takes the form SOV- followed by a string of characters, derived directly from your palm identity — two different palms always produce different IDs, and no two people can share one.\n\nThe ID also carries a small country marker, which the network uses to keep every citizen\'s record fast to find as it grows. Your Sovereign ID is public and safe to share — it is how others send you SOV or message you — and it reveals nothing about who you are or about your palm.'),
    _Section('Enrollment Reward Tiers',
        'The first 1,000 enrolled citizens each receive 1,000 SOV as their enrollment reward — the highest tier, to reward early network builders. Subsequent tiers offer smaller rewards as the network grows, following a graduated schedule.\n\nThis is a FAIR LAUNCH — no founder allocation, no premine, no team tokens. Citizens earn SOV through their own enrollment reward, by running network infrastructure, by serving on justice juries, and by providing genuine goods and services to one another — never by recruiting or referring other people.'),
    _Section('Seed Phrase and Wallet Backup',
        'During enrollment, the app generates a 12-word seed phrase. This phrase is the master key to the citizen\'s wallet. Citizens must write it down and store it in a safe physical location — no one else has a copy.\n\nThe app also offers an encrypted wallet backup file. This file can be saved to cloud storage or shared via email. It contains the Sovereign ID, seed phrase, and public key, all encrypted with a citizen-chosen password.'),
    _Section('Wallet Recovery Methods',
        'Three recovery methods exist. Seed phrase recovery: the citizen types their 12 words and the wallet is restored. File recovery: the citizen opens their .sov backup file and enters the password. Guardian recovery: 2 of 3 nominated guardians approve the restoration using their own palm scans.\n\nGuardians are trusted citizens nominated by the wallet owner. They do not have access to funds — they can only approve or reject a recovery request.'),
    _Section('SOV Vault Allocation',
        'A SOV Vault allows citizens to allocate SOV to a beneficiary. When created, the allocated amount is immediately locked in escrow and removed from the spendable balance. The beneficiary can claim it after the release date using the claim key.\n\nStage 1 claim requires the direct claim key — a passphrase set by the creator. Stage 2 is a fallback for when the claim key is lost: the claimant provides family keywords and a statement, and a randomly selected justice council of active citizens votes on approval.'),
    _Section('The Liveness Check',
        'The liveness check is a periodic proof that a citizen is still alive and active. The app uses on-device biometric analysis to verify that the user performs a real-time gesture — preventing a photo or recording from passing the check.\n\nEach successful liveness check resets the deadman switch countdown. The deadman switch automatically reclaims abandoned balances after 15 years of complete inactivity — protecting against lost wallets accumulating permanently locked supply.'),
    _Section('Palm Duplicate Prevention',
        'Before enrollment completes, the relay checks the new palm against every existing record. If a match is found above the verification threshold, enrollment is rejected.\n\nThis ensures one human, one wallet — the core principle of the SOV Network. No citizen can enroll twice with a different Sovereign ID.'),
    _Section('Enrollment Recovery Screen',
        'Android can kill the app process at any time. If the app is killed after the palm is captured but before the relay registration completes, the next launch detects the interrupted state automatically.\n\nThe recovery screen allows the citizen to retry the relay registration using the cached palm data. Without this, a citizen whose phone ran out of battery mid-enrollment would need to start over from scratch.'),
  ],
  'protocol_specialist': [
    _Section('SOV Token Economics',
        'The total fixed supply of SOV is 50 million tokens, split across protocol-managed pools. The largest — about 30 million — funds citizen enrollment rewards. A second large pool of about 20 million pays relay operators; every transfer fee and every platform connection fee flows into it, so the network funds its own infrastructure. A Community Contributors pool starts at zero and can be filled only by a citizen governance vote once the network grows.\n\nThis is a fair launch: no founder allocation, no premine, no team tokens. Allocations — enrollment rewards and operator income — are executed by the network at enrollment or transaction time. No central authority controls issuance after launch, and no SOV is ever paid for recruiting or referring other citizens.'),
    _Section('One Human One Vote Governance',
        'Every enrolled citizen gets exactly one vote on governance proposals, regardless of their SOV balance. Governance proposals are created and voted on by all active citizens. A passing threshold of more than 50% of participating citizens activates a proposal. Relay operators have no special voting weight.\n\nThe Governance screen has three tabs: Justice Protocol for dispute cases, Network Constitution for protocol proposals, and Votes for all active and completed decisions.'),
    _Section('Network Constitution',
        'The Network Constitution is the list of SOV protocols that citizens can vote to activate. Each item in the list has a "Propose Vote" button. When a citizen proposes a vote, a poll opens for all citizens to participate in.\n\nProtocols on the constitution list include SOV Request payment links, SOV Login for platforms, forum, privacy balance toggle, relay staking, merit pool, escrow API, and NFC identity. Each protocol becomes part of the network only after a citizen majority vote.'),
    _Section('SOV Value Protocol',
        'The ⟡ symbol on the balance card represents the citizen-voted SOV reference rate — the agreed guide price of one SOV in local currency. The first vote opens when 5,000 citizens have enrolled. Citizens submit a proposed rate and the median of all submissions becomes the official reference rate.\n\nSubsequent votes happen every 10,000 new enrollments. A single vote cannot move the rate by more than 50% in either direction. The rate is advisory — it guides the peer exchange market but is not enforced by the relay. Before any vote has taken place, the balance card shows enrollment progress toward the threshold.'),
    _Section('Justice Protocol',
        'The Justice Protocol allows citizens to file formal disputes about transactions they believe were fraudulent. A bond of 10 SOV is required to file a case — this discourages frivolous claims.\n\nFive citizens are randomly selected from the active citizen pool to serve as jurors. They have 72 hours to review the evidence and vote. If the majority upholds the case, the transaction is reversed, funds are returned to the sender, and the bond is returned to the complainant. If the case is dismissed, the transaction stands and the bond is burned. Citizens can attach up to three photos as evidence when filing.'),
    _Section('SOV Speak Messaging',
        'SOV Speak is the network\'s built-in encrypted messaging system. Messages show a live delivery status: Sending, Sent, Delivered, and Read. The app detects dropped connections within 16 seconds and updates the status immediately.\n\nCitizens can attach images, videos, and files to messages. A payment can be sent directly inside a conversation — it appears as a receipt in the chat thread showing the amount, timestamp, and transaction reference. Messages sent to offline citizens are stored on the relay and delivered automatically when they reconnect.'),
    _Section('SOV Login Protocol',
        'Third-party platforms can accept "Sign in with SOV" as a login. The platform shows the citizen a short pairing code; the citizen approves it in their SOV app, which signs the confirmation on their device; the platform verifies it. Because the SOV identity layer guarantees one account per real human, the platform gets a bot-proof, one-person-one-account user base with no captchas, SMS codes, or KYC.\n\nNo API key or company sign-up is needed — any platform connects directly on the network. And citizens NEVER pay to sign in anywhere: the only cost sits with the platform, which pays a small yearly connection fee.'),
    _Section('Platform Connection Fee',
        'A platform pays a small ANNUAL fee (currently 10 SOV per year, set by citizen vote) to keep its "Sign in with SOV" connection active. The fee is paid by the business, once a year — individual citizens are never charged for logging in.\n\nThe fee flows into the operator reward pool that pays the citizens running the network, so the total SOV supply never changes. As more platforms connect, the network funds its own operators. Legacy platforms connected before the annual model are grandfathered.'),
    _Section('The P2P Exchange',
        'The SOV exchange is fully peer-to-peer within the network. Citizens list sell orders specifying an amount of SOV, a price in fiat or other currency, and a payment method. Buyers fill orders by transferring the payment off-network and the seller confirms delivery on the network.\n\nThere is no intermediary, no custody, and no central order book. Open orders are held on the network, which facilitates the confirmation and releases the escrowed SOV when the seller confirms. The ⟡ reference rate set by citizen vote acts as a price guide for exchange listings.'),
    _Section('Fair Launch (no founder allocation)',
        'The SOV Network launches with no founder allocation, no premine, and no team tokens. The protocol developer enrolls as simply citizen #1 and receives the standard tier-1 1,000 SOV reward, same as the next 999 citizens. The previous 5M founder_allocation pool was REMOVED in the 2026-05-27 refactor; its cap was redistributed to the witness_operator pool (which now grows by every transfer fee + every 10 SOV platform-registration fee). This is the same fair-distribution model that Bitcoin and Monero used.\n\nThe protocol developer earns SOV only through the same channels available to any citizen: the one-time enrollment reward, operator income (a share of transaction + platform fees for running infrastructure), and P2P exchange (selling SOV for fiat or services). There is no reward for recruiting or referring other citizens.'),
    _Section('Certification and Providing Services',
        'An SOV certification proves you have mastered a part of the network well enough to provide services to other citizens. It requires passing an 85% threshold assessment in one or more tracks: Node Operator, Enrollment Helper, or Protocol Expert.\n\nA citizen can earn all three certifications. Certification is recognition of expertise — it lets you help others run nodes, onboard, and use the network correctly, and you set your own price for that help. Citizens earn SOV by providing genuine services, running infrastructure, and trading value — never by recruiting or referring other people.'),
    _Section('Double-Spend Prevention',
        'SOV prevents double-spending without mining or staking, using three guards on every transfer. First, each wallet\'s transfers form a NONCE CHAIN — a strictly increasing counter — so a node rejects any transfer that reuses or skips a number, which blocks replaying an old signed transfer. Second, a SPEND LOCK reserves the exact amount the instant a transfer is accepted, so the same balance cannot be spent twice even from two devices at once. Third, a VERSION GATE gives every balance a version number that only ever increases.\n\nNodes then keep each other honest by continuously comparing a compact fingerprint of their balances and pulling any differences, with the highest-version balance winning. So all nodes converge on one shared truth with no energy race, no miners, and no central sequencer.'),
  ],
};

// ── Spec metadata ─────────────────────────────────────────────────────────────
const _specMeta = {
  'relay_engineer': (
    label: 'Node Operator',
    shortLabel: 'OP',
    desc:
        'Master how to run a node, keep it healthy, and keep the network in sync. Help others run the infrastructure — and charge for it.',
    icon: Icons.dns_rounded,
  ),
  'enrollment_agent': (
    label: 'Enrollment Helper',
    shortLabel: 'EH',
    desc:
        'Master citizen onboarding, wallet setup, and recovery. Guide new citizens onto the network as a paid service.',
    icon: Icons.person_add_alt_1_rounded,
  ),
  'protocol_specialist': (
    label: 'Protocol Expert',
    shortLabel: 'PX',
    desc:
        'Master the full SOV economy, governance, exchange, and login. Advise platforms and businesses for a fee you set.',
    icon: Icons.account_tree_rounded,
  ),
};

// ═════════════════════════════════════════════════════════════════════════════
// Widget
// ═════════════════════════════════════════════════════════════════════════════

class PioneerScreen extends StatefulWidget {
  final String sovereignId;
  const PioneerScreen({super.key, required this.sovereignId});

  @override
  State<PioneerScreen> createState() => _PioneerScreenState();
}

class _PioneerScreenState extends State<PioneerScreen>
    with TickerProviderStateMixin {
  // Colours
  static const _navy   = Color(0xFF0A1628);
  static const _gold   = Color(0xFFB8960C);
  static const _cardBg = Color(0xFF0D1F3A);
  static const _teal   = Color(0xFF006B5E);
  static const _green  = Color(0xFF4CAF50);

  // State
  _PState _state = _PState.loading;
  String? _error;

  // Pioneer status
  Map<String, dynamic> _status = {};

  // Selected spec
  String? _selectedSpec;

  // Assessment
  int?                     _assessmentId;
  List<Map<String, dynamic>> _questions  = [];
  int                      _currentQ    = 0;
  Map<int, String>         _answers     = {};
  bool                     _submitting  = false;

  // Results
  Map<String, dynamic> _submitResult = {};

  // Badge animation
  late AnimationController _badgeAnim;
  late Animation<double>    _badgeScale;

  @override
  void initState() {
    super.initState();
    _badgeAnim = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 600));
    _badgeScale = CurvedAnimation(parent: _badgeAnim, curve: Curves.elasticOut);
    _loadStatus();
  }

  @override
  void dispose() {
    _badgeAnim.dispose();
    super.dispose();
  }

  // ── Data loading ─────────────────────────────────────────────────────────────

  Future<void> _loadStatus() async {
    setState(() { _state = _PState.loading; _error = null; });
    try {
      if (!RelayConnector.isConnected) await RelayConnector.connect();
      final resp = await RelayConnector.pioneerGetStatus(widget.sovereignId);
      if (!mounted) return;
      if (resp['success'] == true) {
        setState(() { _status = resp; _state = _PState.choosing; });
      } else {
        setState(() {
          _error = resp['error']?.toString() ?? 'Could not load pioneer status';
          _state = _PState.choosing;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _state = _PState.choosing; });
    }
  }

  // ── Assessment flow ──────────────────────────────────────────────────────────

  Future<void> _startAssessment(String spec) async {
    setState(() { _error = null; _submitting = true; });
    try {
      if (!RelayConnector.isConnected) await RelayConnector.connect();
      final resp = await RelayConnector.pioneerStartAssessment(widget.sovereignId, spec);
      if (!mounted) return;
      if (resp['success'] == true) {
        final rawQ = (resp['questions'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        setState(() {
          _assessmentId = (resp['assessment_id'] as num?)?.toInt();
          _questions    = rawQ;
          _currentQ     = 0;
          _answers      = {};
          _state        = _PState.assessment;
          _submitting   = false;
        });
      } else {
        final err = resp['error']?.toString() ?? 'Could not start assessment';
        if (err == 'COOLDOWN') {
          final until = (resp['cooldown_until'] as num?)?.toInt() ?? 0;
          final dt    = DateTime.fromMillisecondsSinceEpoch(until);
          final label = '${dt.day}/${dt.month} ${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';
          setState(() { _error = 'Cooldown active — 3 attempts used. Try again after $label'; _submitting = false; });
        } else if (err == 'ALREADY_CERTIFIED') {
          setState(() { _error = 'You are already certified in this specialisation'; _submitting = false; });
          _loadStatus();
        } else {
          setState(() { _error = err; _submitting = false; });
        }
      }
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _submitting = false; });
    }
  }

  Future<void> _submitAnswers() async {
    if (_assessmentId == null) return;
    setState(() { _submitting = true; _error = null; });
    try {
      final resp = await RelayConnector.pioneerSubmitAssessment(
          widget.sovereignId, _assessmentId!, _answers);
      if (!mounted) return;
      setState(() {
        _submitResult = resp;
        _state        = _PState.results;
        _submitting   = false;
      });
      if (resp['passed'] == true) {
        _badgeAnim.forward(from: 0);
        _loadStatus(); // refresh certifications
      }
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _submitting = false; });
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────────

  Map<String, dynamic> get _certs =>
      (_status['certifications'] as Map?)?.cast<String, dynamic>() ?? {};

  bool _isCertified(String spec) => _certs[spec] == true;

  Map<String, dynamic> _attemptsFor(String spec) {
    final m = (_status['attempts_by_spec'] as Map?)?.cast<String, dynamic>() ?? {};
    return (m[spec] as Map?)?.cast<String, dynamic>() ?? {};
  }

  int _failCount(String spec) =>
      (_attemptsFor(spec)['failed_count'] as num?)?.toInt() ?? 0;

  bool _isOnCooldown(String spec) => _failCount(spec) >= 3;

  // ── Back navigation ──────────────────────────────────────────────────────────

  void _goChoose() => setState(() { _state = _PState.choosing; _error = null; });

  void _goGuide(String spec) {
    setState(() { _selectedSpec = spec; _state = _PState.guide; _error = null; });
  }

  // ═════════════════════════════════════════════════════════════════════════════
  // BUILD
  // ═════════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_state == _PState.guide || _state == _PState.assessment ||
            _state == _PState.results) {
          _goChoose();
        } else {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: _navy,
        appBar: _buildAppBar(),
        body: _buildBody(),
      ),
    );
  }

  AppBar _buildAppBar() {
    String title;
    switch (_state) {
      case _PState.guide:
        title = _specMeta[_selectedSpec]?.label ?? 'Study Guide';
        break;
      case _PState.assessment:
        title = 'Assessment';
        break;
      case _PState.results:
        title = 'Results';
        break;
      default:
        title = 'SOV Certifications';
    }
    return AppBar(
      backgroundColor: _navy,
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
        onPressed: () {
          if (_state == _PState.guide || _state == _PState.assessment ||
              _state == _PState.results) {
            _goChoose();
          } else {
            Navigator.pop(context);
          }
        },
      ),
      title: Text(title,
          style: const TextStyle(
              color: Color(0xFFB8960C),
              fontWeight: FontWeight.bold,
              fontSize: 18)),
    );
  }

  Widget _buildBody() {
    switch (_state) {
      case _PState.loading:
        return const Center(child: CircularProgressIndicator(color: Color(0xFFB8960C)));
      case _PState.choosing:
        return _buildChoosing();
      case _PState.guide:
        return _buildGuide();
      case _PState.assessment:
        return _buildAssessment();
      case _PState.results:
        return _buildResults();
    }
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // STATE 1 — Choose Specialisation
  // ─────────────────────────────────────────────────────────────────────────────

  Widget _buildChoosing() {
    final certs     = _certs;
    final anyPioneer = certs.values.any((v) => v == true);

    return RefreshIndicator(
      onRefresh: _loadStatus,
      color: _gold,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Error banner
            if (_error != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withAlpha(26),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.withAlpha(77)),
                ),
                child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
              ),
              const SizedBox(height: 16),
            ],

            // Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _teal.withAlpha(26),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _teal.withAlpha(77)),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('SOV Certifications',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                  SizedBox(height: 8),
                  Text(
                    'Earn your certification and become a recognised expert who can provide '
                    'services to the network. Pass any of the three 15-question assessments at '
                    '85% or above. Three attempts per 48 hours. Badges live permanently on your record.',
                    style: TextStyle(color: Colors.white54, fontSize: 13, height: 1.5),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Spec cards
            ..._specMeta.entries.map((e) => _buildSpecCard(e.key, e.value)),

            // Pioneer stats (if any certified)
            if (anyPioneer) ...[
              const SizedBox(height: 24),
              _buildPioneerStats(),
            ],

            const SizedBox(height: 20),
            Center(
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Back to Home',
                    style: TextStyle(color: Colors.white38, fontSize: 14)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSpecCard(String spec, dynamic meta) {
    final certified  = _isCertified(spec);
    final fails      = _failCount(spec);
    final onCooldown = _isOnCooldown(spec);

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: certified ? _gold.withAlpha(100) : Colors.white.withAlpha(15),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Icon + title + badge chip
            Row(
              children: [
                Container(
                  width: 42, height: 42,
                  decoration: BoxDecoration(
                    color: certified ? _gold.withAlpha(30) : _teal.withAlpha(30),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(meta.icon,
                      color: certified ? _gold : _teal, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(meta.label,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 15)),
                      const SizedBox(height: 2),
                      _BadgeChip(label: '[${meta.shortLabel}]',
                          certified: certified),
                    ],
                  ),
                ),
                if (certified)
                  const Icon(Icons.verified_rounded, color: Color(0xFFB8960C), size: 22),
              ],
            ),
            const SizedBox(height: 10),
            Text(meta.desc,
                style: const TextStyle(
                    color: Colors.white54, fontSize: 13, height: 1.4)),
            const SizedBox(height: 14),

            // Status / action
            if (certified)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: _green.withAlpha(26),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _green.withAlpha(77)),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle_rounded, color: Color(0xFF4CAF50), size: 16),
                    SizedBox(width: 6),
                    Text('Certified', style: TextStyle(color: Color(0xFF4CAF50),
                        fontWeight: FontWeight.bold, fontSize: 13)),
                  ],
                ),
              )
            else if (onCooldown)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.orange.withAlpha(26),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.withAlpha(77)),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.timer_rounded, color: Colors.orangeAccent, size: 16),
                    SizedBox(width: 6),
                    Text('48hr cooldown — 3 attempts used',
                        style: TextStyle(color: Colors.orangeAccent, fontSize: 13)),
                  ],
                ),
              )
            else
              Row(
                children: [
                  ElevatedButton.icon(
                    icon: const Icon(Icons.menu_book_rounded, size: 15),
                    label: const Text('Study Guide'),
                    onPressed: _submitting ? null : () => _goGuide(spec),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _teal,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      elevation: 0,
                    ),
                  ),
                  const SizedBox(width: 10),
                  if (fails > 0)
                    Text('${3 - fails} attempt${3 - fails == 1 ? '' : 's'} left',
                        style: TextStyle(
                            color: Colors.white.withAlpha(50), fontSize: 12)),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPioneerStats() {
    // Certifications earned = truthy entries in the status certifications map.
    final certs = (_status['certifications'] as Map?) ?? const {};
    final certCount = certs.values.where((v) => v == true || v == 1).length;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _gold.withAlpha(18),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _gold.withAlpha(77)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.star_rounded, color: Color(0xFFB8960C), size: 18),
              const SizedBox(width: 8),
              const Text('Your Qualifications',
                  style: TextStyle(
                      color: Color(0xFFB8960C),
                      fontWeight: FontWeight.bold,
                      fontSize: 14)),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'Your certifications are professional qualifications. Use them to offer paid services to other citizens — you set the price. Advertise on the Exchange; your badges and reputation build client trust.',
            style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _StatChip(label: 'Certifications', value: '$certCount'),
            ],
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: widget.sovereignId));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Sovereign ID copied — share it with new citizens'),
                backgroundColor: Color(0xFF0D1F3A),
                behavior: SnackBarBehavior.floating,
                duration: Duration(seconds: 2),
              ));
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: _cardBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _gold.withAlpha(77)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.sovereignId,
                      style: const TextStyle(
                          color: Color(0xFFB8960C),
                          fontSize: 13,
                          fontFamily: 'monospace'),
                    ),
                  ),
                  const Icon(Icons.copy_rounded, color: Color(0xFFB8960C), size: 16),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // STATE 2 — Knowledge Guide
  // ─────────────────────────────────────────────────────────────────────────────

  Widget _buildGuide() {
    final spec     = _selectedSpec ?? '';
    final sections = _guides[spec] ?? [];
    final meta     = _specMeta[spec];
    final fails    = _failCount(spec);

    return Column(
      children: [
        // Header strip
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          color: _teal.withAlpha(40),
          child: Row(
            children: [
              Icon(meta?.icon ?? Icons.school_rounded, color: _teal, size: 18),
              const SizedBox(width: 8),
              Text(meta?.label ?? spec,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
              const Spacer(),
              Text('${sections.length} topics',
                  style: TextStyle(color: Colors.white.withAlpha(60), fontSize: 12)),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ...sections.asMap().entries.map((e) => _buildGuideSection(e.key + 1, e.value)),
                const SizedBox(height: 24),

                // Start assessment button
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _submitting ? null : () => _startAssessment(spec),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _gold,
                      disabledBackgroundColor: _gold.withAlpha(77),
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                      elevation: 0,
                    ),
                    child: _submitting
                        ? const SizedBox(
                            width: 22, height: 22,
                            child: CircularProgressIndicator(
                                color: Colors.black, strokeWidth: 2.5))
                        : Text(
                            'Start Assessment (${3 - fails} attempt${3 - fails == 1 ? '' : 's'} remaining)',
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.bold)),
                  ),
                ),

                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                        color: Colors.red.withAlpha(26),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red.withAlpha(77))),
                    child: Text(_error!,
                        style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
                  ),
                ],

                const SizedBox(height: 16),
                Center(
                  child: TextButton(
                    onPressed: _goChoose,
                    child: const Text('Back to Certifications',
                        style: TextStyle(color: Colors.white38, fontSize: 13)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildGuideSection(int num, _Section s) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 26, height: 26,
                margin: const EdgeInsets.only(right: 10, top: 1),
                decoration: BoxDecoration(
                  color: _gold.withAlpha(30),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Center(
                  child: Text('$num',
                      style: const TextStyle(
                          color: Color(0xFFB8960C),
                          fontSize: 11,
                          fontWeight: FontWeight.bold)),
                ),
              ),
              Expanded(
                child: Text(s.title,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(s.body,
              style: const TextStyle(
                  color: Colors.white60, fontSize: 13, height: 1.6)),
          const SizedBox(height: 8),
          Divider(color: Colors.white.withAlpha(12)),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // STATE 3 — Assessment
  // ─────────────────────────────────────────────────────────────────────────────

  Widget _buildAssessment() {
    if (_questions.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('No questions loaded',
                style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 16),
            TextButton(onPressed: _goChoose, child: const Text('Back')),
          ],
        ),
      );
    }

    final q         = _questions[_currentQ];
    final qId       = (q['id'] as num?)?.toInt() ?? _currentQ;
    final question  = q['question'] as String? ?? '';
    final opts      = (q['options'] as Map?)?.cast<String, String>() ?? {};
    final selected  = _answers[qId];
    final isLast    = _currentQ == _questions.length - 1;
    final progress  = (_currentQ + 1) / _questions.length;

    return Column(
      children: [
        // Progress bar
        LinearProgressIndicator(
          value: progress,
          backgroundColor: Colors.white.withAlpha(20),
          valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFB8960C)),
          minHeight: 3,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Row(
            children: [
              Text('Question ${_currentQ + 1} of ${_questions.length}',
                  style: const TextStyle(
                      color: Colors.white54, fontSize: 13, fontWeight: FontWeight.w500)),
              const Spacer(),
              Text('${_answers.length} answered',
                  style: TextStyle(color: Colors.white.withAlpha(50), fontSize: 12)),
            ],
          ),
        ),

        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Question card
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: _cardBg,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white.withAlpha(15)),
                  ),
                  child: Text(
                    question,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 15, height: 1.5),
                  ),
                ),
                const SizedBox(height: 16),

                // Options
                ...['A', 'B', 'C', 'D'].map((letter) {
                  final text     = opts[letter] ?? '';
                  if (text.isEmpty) return const SizedBox.shrink();
                  final isChosen = selected == letter;
                  return GestureDetector(
                    onTap: () => setState(() => _answers[qId] = letter),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: isChosen
                            ? _gold.withAlpha(40)
                            : _cardBg,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isChosen
                              ? _gold
                              : Colors.white.withAlpha(18),
                          width: isChosen ? 1.5 : 1,
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 26, height: 26,
                            decoration: BoxDecoration(
                              color: isChosen
                                  ? _gold
                                  : Colors.white.withAlpha(15),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Center(
                              child: Text(letter,
                                  style: TextStyle(
                                      color: isChosen ? Colors.black : Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12)),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(text,
                                style: TextStyle(
                                    color: isChosen ? Colors.white : Colors.white70,
                                    fontSize: 14,
                                    height: 1.4)),
                          ),
                        ],
                      ),
                    ),
                  );
                }),

                const SizedBox(height: 20),

                // Next / Submit
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    onPressed: (selected == null || _submitting)
                        ? null
                        : () {
                            if (isLast) {
                              _submitAnswers();
                            } else {
                              setState(() => _currentQ++);
                            }
                          },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _gold,
                      disabledBackgroundColor: _gold.withAlpha(60),
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                      elevation: 0,
                    ),
                    child: _submitting
                        ? const SizedBox(
                            width: 22, height: 22,
                            child: CircularProgressIndicator(
                                color: Colors.black, strokeWidth: 2.5))
                        : Text(
                            isLast ? 'Submit Assessment' : 'Next Question →',
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.bold)),
                  ),
                ),

                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                        color: Colors.red.withAlpha(26),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red.withAlpha(77))),
                    child: Text(_error!,
                        style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // STATE 4 — Results
  // ─────────────────────────────────────────────────────────────────────────────

  Widget _buildResults() {
    final passed     = _submitResult['passed'] == true;
    final score      = (_submitResult['score'] as num?)?.toInt() ?? 0;
    final spec       = _submitResult['specialisation']?.toString() ?? _selectedSpec ?? '';
    final badge      = _submitResult['badge_earned']?.toString() ?? spec;
    final rank       = _submitResult['rank']?.toString() ?? '';
    final message    = _submitResult['message']?.toString() ?? '';
    final attLeft    = (_submitResult['attempts_remaining'] as num?)?.toInt() ?? 0;
    final meta       = _specMeta[spec];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 20),

          if (passed) ...[
            // Gold badge animation
            ScaleTransition(
              scale: _badgeScale,
              child: Container(
                width: 110, height: 110,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _gold.withAlpha(30),
                  border: Border.all(color: _gold, width: 2.5),
                  boxShadow: [
                    BoxShadow(
                        color: _gold.withAlpha(80),
                        blurRadius: 24,
                        spreadRadius: 4),
                  ],
                ),
                child: Icon(meta?.icon ?? Icons.verified_rounded,
                    color: _gold, size: 54),
              ),
            ),
            const SizedBox(height: 24),
            const Text('Congratulations!',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('Score: $score% — Passed',
                style: const TextStyle(
                    color: Color(0xFF4CAF50),
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 20),

            // Badge earned
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _gold.withAlpha(18),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _gold.withAlpha(100)),
              ),
              child: Column(
                children: [
                  Text(meta?.label ?? badge.replaceAll('_', ' ').toUpperCase(),
                      style: const TextStyle(
                          color: Color(0xFFB8960C),
                          fontWeight: FontWeight.bold,
                          fontSize: 16)),
                  const SizedBox(height: 6),
                  _BadgeChip(label: '[${meta?.shortLabel ?? '??'}]', certified: true),
                  if (rank.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text('Rank: ${rank.toUpperCase()}',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 13)),
                  ],
                  const SizedBox(height: 8),
                  const Text(
                    'Badge added to your disc record permanently.\nVisible in all transactions and SOV Login responses.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.4),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4)),
            const SizedBox(height: 24),

            // Offer services — share your ID so clients can find and pay you
            _buildShareCard(),
          ] else ...[
            // Fail state
            Container(
              width: 90, height: 90,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.red.withAlpha(30),
                border: Border.all(color: Colors.redAccent.withAlpha(150), width: 2),
              ),
              child: const Icon(Icons.close_rounded, color: Colors.redAccent, size: 50),
            ),
            const SizedBox(height: 20),
            Text('Score: $score% — Not Passed',
                style: const TextStyle(
                    color: Colors.redAccent,
                    fontSize: 18,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('Pass mark: 85%',
                style: TextStyle(color: Colors.white54, fontSize: 14)),
            const SizedBox(height: 16),

            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _cardBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withAlpha(18)),
              ),
              child: Column(
                children: [
                  Text(message,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 13, height: 1.5)),
                  if (attLeft > 0) ...[
                    const SizedBox(height: 12),
                    Text('$attLeft attempt${attLeft == 1 ? '' : 's'} remaining this 48-hour window',
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 12)),
                  ] else ...[
                    const SizedBox(height: 12),
                    const Text('48-hour cooldown started. Come back and try again after reviewing the guide.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: Colors.orangeAccent, fontSize: 12, height: 1.4)),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Study Again button
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.menu_book_rounded, size: 18),
                label: const Text('Study Again',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                onPressed: () => _goGuide(spec),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _teal,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                  elevation: 0,
                ),
              ),
            ),
          ],

          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: OutlinedButton(
              onPressed: _goChoose,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white54,
                side: BorderSide(color: Colors.white.withAlpha(40)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text('Back to Certifications'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildShareCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _teal.withAlpha(26),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _teal.withAlpha(77)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Offer Your Services',
              style: TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 6),
          const Text(
            'Use your certifications to offer services to other citizens and charge for them — you set the price. Share your Sovereign ID so clients can find and pay you directly.',
            style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: widget.sovereignId));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Sovereign ID copied — share it with clients'),
                backgroundColor: Color(0xFF0D1F3A),
                behavior: SnackBarBehavior.floating,
                duration: Duration(seconds: 2),
              ));
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: _cardBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _gold.withAlpha(77)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.sovereignId,
                      style: const TextStyle(
                          color: Color(0xFFB8960C),
                          fontSize: 13,
                          fontFamily: 'monospace'),
                    ),
                  ),
                  const Icon(Icons.copy_rounded, color: Color(0xFFB8960C), size: 16),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Small reusable widgets ────────────────────────────────────────────────────

class _BadgeChip extends StatelessWidget {
  final String label;
  final bool   certified;
  const _BadgeChip({required this.label, required this.certified});

  @override
  Widget build(BuildContext context) {
    const gold = Color(0xFFB8960C);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: certified ? gold.withAlpha(30) : Colors.white.withAlpha(12),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
            color: certified ? gold.withAlpha(120) : Colors.white.withAlpha(25)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: certified ? gold : Colors.white38,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  const _StatChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1F3A),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withAlpha(20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  color: Colors.white.withAlpha(50),
                  fontSize: 10,
                  letterSpacing: 0.8)),
          const SizedBox(height: 2),
          Text(value,
              style: const TextStyle(
                  color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
