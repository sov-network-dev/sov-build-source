// lib/screens/contacts_screen.dart
// ─────────────────────────────────────────────────────────────────────────────
// Contacts — auto-populated from every SOV Speak interaction and SOV transfer.
// ─────────────────────────────────────────────────────────────────────────────
import 'package:flutter/material.dart';
import '../sov_node_sdk/contacts_db.dart';
import '../sov_node_sdk/palm_name_engine.dart';
import 'sov_link_screen.dart';
import 'send_sov_screen.dart';

class ContactsScreen extends StatefulWidget {
  final String sovereignId;
  const ContactsScreen({super.key, required this.sovereignId});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  static const _navy   = Color(0xFF0A1628);
  static const _gold   = Color(0xFFD4AF37);
  static const _cardBg = Color(0xFF0D1F3A);
  static const _teal   = Color(0xFF006B5E);

  List<Contact> _contacts        = [];
  List<Contact> _blockedContacts = [];
  String _query   = '';
  bool   _loading = true;

  final _searchCtrl = TextEditingController();
  final _addCtrl    = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _addCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final contacts = await ContactsDb.getContacts(
        query: _query.isNotEmpty ? _query : null);
    final blocked  = _query.isEmpty
        ? await ContactsDb.getBlockedContacts()
        : <Contact>[];
    if (mounted) {
      setState(() {
        _contacts        = contacts;
        _blockedContacts = blocked;
        _loading         = false;
      });
    }
  }

  // ── Add contact manually ───────────────────────────────────────────────────

  void _showAddSheet() {
    _addCtrl.clear();
    final regex = RegExp(r'^SOV-[0-9A-F]{16}$');
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _cardBg,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            24, 24, 24, MediaQuery.of(ctx).viewInsets.bottom + 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Add Contact',
                style: TextStyle(color: Colors.white,
                    fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            TextField(
              controller: _addCtrl,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              style: const TextStyle(color: Colors.white,
                  fontFamily: 'monospace', fontSize: 13),
              decoration: InputDecoration(
                hintText: 'SOV-XXXXXXXXXXXXXXXX',
                hintStyle:
                    const TextStyle(color: Colors.white38, fontSize: 13),
                filled: true,
                fillColor: _navy,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide:
                        BorderSide(color: Colors.white.withAlpha(20))),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide:
                        BorderSide(color: Colors.white.withAlpha(20))),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide:
                        const BorderSide(color: _gold, width: 1.5)),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: () async {
                  final id = _addCtrl.text.trim().toUpperCase();
                  if (!regex.hasMatch(id)) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                            'Enter a valid Sovereign ID: '
                            'SOV-XXXXXXXXXXXXXXXX'),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                    return;
                  }
                  Navigator.pop(ctx);
                  await ContactsDb.recordInteraction(
                    sovereignId: id,
                    nickname:    PalmNameEngine.deriveName([], sovereignId: id),
                  );
                  _load();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: _gold,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('Save Contact',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Edit label ─────────────────────────────────────────────────────────────

  void _showEditLabelSheet(Contact contact) {
    final ctrl = TextEditingController(text: contact.customLabel ?? '');
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _cardBg,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            24, 24, 24, MediaQuery.of(ctx).viewInsets.bottom + 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Edit Label',
                style: TextStyle(color: Colors.white,
                    fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('Default: ${contact.nickname}',
                style: const TextStyle(
                    color: Colors.white38, fontSize: 12)),
            const SizedBox(height: 16),
            TextField(
              controller: ctrl,
              autofocus: true,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Custom label (optional)',
                hintStyle:
                    const TextStyle(color: Colors.white38, fontSize: 13),
                filled: true,
                fillColor: _navy,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide:
                        BorderSide(color: Colors.white.withAlpha(20))),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide:
                        const BorderSide(color: _gold, width: 1.5)),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      Navigator.pop(ctx);
                      await ContactsDb.updateContactLabel(
                          contact.sovereignId, null);
                      _load();
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white54,
                      side: const BorderSide(color: Colors.white24),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Clear'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () async {
                      Navigator.pop(ctx);
                      final label = ctrl.text.trim();
                      await ContactsDb.updateContactLabel(
                          contact.sovereignId,
                          label.isNotEmpty ? label : null);
                      _load();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _gold,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Save',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final favourites = _contacts.where((c) => c.isFavourite).toList();
    final others     = _contacts.where((c) => !c.isFavourite).toList();

    return Scaffold(
      key: const ValueKey('contactsScreenScaffold'),
      backgroundColor: _navy,
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _searchCtrl,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Search contacts\u2026',
                hintStyle:
                    const TextStyle(color: Colors.white38, fontSize: 14),
                prefixIcon: const Icon(Icons.search_rounded,
                    color: Colors.white38, size: 20),
                suffixIcon: _query.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded,
                            color: Colors.white38, size: 18),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _query = '');
                          _load();
                        },
                      )
                    : null,
                filled: true,
                fillColor: _cardBg,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 10),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none),
              ),
              onChanged: (v) {
                setState(() => _query = v);
                _load();
              },
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(color: _gold))
                : (_contacts.isEmpty && _blockedContacts.isEmpty)
                    ? _buildEmpty()
                    : ListView(
                        padding: const EdgeInsets.only(bottom: 80),
                        children: [
                          if (favourites.isNotEmpty) ...[
                            _buildSectionHeader(
                                'Favourites', Icons.star_rounded),
                            ...favourites.map(_buildContactCard),
                          ],
                          if (others.isNotEmpty) ...[
                            _buildSectionHeader(
                                'All Contacts',
                                Icons.people_outline_rounded),
                            ...others.map(_buildContactCard),
                          ],
                          if (_blockedContacts.isNotEmpty)
                            _buildBlockedSection(),
                        ],
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: null,
        backgroundColor: _gold,
        foregroundColor: Colors.black,
        onPressed: _showAddSheet,
        child: const Icon(Icons.person_add_rounded),
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 72, height: 72,
              decoration: BoxDecoration(
                color: _cardBg,
                shape: BoxShape.circle,
                border:
                    Border.all(color: Colors.white.withAlpha(18)),
              ),
              child: const Icon(Icons.contacts_outlined,
                  color: Colors.white38, size: 34),
            ),
            const SizedBox(height: 18),
            const Text('No contacts yet',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text(
              'Contacts are added automatically when you\n'
              'message or send SOV to another citizen.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Colors.white38,
                  fontSize: 12,
                  height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Row(
        children: [
          Icon(icon, color: Colors.white38, size: 14),
          const SizedBox(width: 6),
          Text(title.toUpperCase(),
              style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 11,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _buildBlockedSection() {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
        leading: const Icon(Icons.block_rounded, color: Colors.redAccent, size: 18),
        title: Text(
          'BLOCKED (${_blockedContacts.length})',
          style: const TextStyle(
              color: Colors.redAccent,
              fontSize: 11,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w600),
        ),
        iconColor:        Colors.redAccent,
        collapsedIconColor: Colors.redAccent,
        children: _blockedContacts.map(_buildBlockedCard).toList(),
      ),
    );
  }

  Widget _buildBlockedCard(Contact contact) {
    final initial = contact.displayName.isNotEmpty
        ? contact.displayName[0].toUpperCase()
        : '?';
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.redAccent.withAlpha(40)),
      ),
      child: Row(
        children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: Colors.redAccent.withAlpha(20),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.redAccent.withAlpha(60)),
            ),
            child: Center(
              child: Text(initial,
                  style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(contact.displayName,
                    style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 14,
                        fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(_truncateId(contact.sovereignId),
                    style: const TextStyle(
                        color: Colors.white24,
                        fontSize: 10,
                        fontFamily: 'monospace')),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: () async {
              await ContactsDb.unblockContact(contact.sovereignId);
              _load();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text('${contact.displayName} unblocked.'),
                  backgroundColor: _teal,
                  behavior: SnackBarBehavior.floating,
                ));
              }
            },
            icon: const Icon(Icons.lock_open_rounded,
                color: Colors.greenAccent, size: 16),
            label: const Text('Unblock',
                style: TextStyle(color: Colors.greenAccent, fontSize: 12)),
            style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4)),
          ),
        ],
      ),
    );
  }

  Widget _buildContactCard(Contact contact) {
    final initial = contact.displayName.isNotEmpty
        ? contact.displayName[0].toUpperCase()
        : '?';
    final lastSeen = _relativeTime(contact.lastContactAt);

    return GestureDetector(
      onLongPress: () => _showLongPressMenu(contact),
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _cardBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withAlpha(10)),
        ),
        child: Row(
          children: [
            // Avatar
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: _teal.withAlpha(40),
                shape: BoxShape.circle,
                border: Border.all(color: _teal.withAlpha(80)),
              ),
              child: Center(
                child: Text(initial,
                    style: const TextStyle(
                        color: _teal,
                        fontSize: 18,
                        fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(width: 12),
            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(contact.displayName,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis),
                      ),
                      if (contact.isFavourite)
                        const Icon(Icons.star_rounded,
                            color: _gold, size: 14),
                    ],
                  ),
                  if (contact.customLabel != null) ...[
                    const SizedBox(height: 1),
                    Text(contact.nickname,
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 11)),
                  ],
                  const SizedBox(height: 2),
                  Text(
                    _truncateId(contact.sovereignId),
                    style: const TextStyle(
                        color: Colors.white24,
                        fontSize: 10,
                        fontFamily: 'monospace'),
                  ),
                  if (lastSeen.isNotEmpty)
                    Text('Last contact $lastSeen',
                        style: const TextStyle(
                            color: Colors.white24, fontSize: 10)),
                ],
              ),
            ),
            // Action buttons
            Column(
              children: [
                _actionIcon(
                  icon: Icons.chat_bubble_outline_rounded,
                  color: _teal,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SovLinkScreen(
                          mySovId: widget.sovereignId,
                          participantId: contact.sovereignId),
                    ),
                  ),
                  tooltip: 'Message',
                ),
                const SizedBox(height: 4),
                _actionIcon(
                  icon: Icons.arrow_upward_rounded,
                  color: _gold,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SendSovScreen(
                        sovereignId:  widget.sovereignId,
                        seeds:        0,
                        lockedSeeds:  0,
                        initialRecipientId: contact.sovereignId,
                      ),
                    ),
                  ),
                  tooltip: 'Send SOV',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionIcon({
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
    required String tooltip,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 34, height: 34,
        decoration: BoxDecoration(
          color: color.withAlpha(20),
          shape: BoxShape.circle,
          border: Border.all(color: color.withAlpha(60)),
        ),
        child: Icon(icon, color: color, size: 16),
      ),
    );
  }

  void _showLongPressMenu(Contact contact) {
    showModalBottomSheet(
      context: context,
      backgroundColor: _cardBg,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(height: 16),
            Text(contact.displayName,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            _menuTile(
              ctx: ctx,
              icon: Icons.label_outline_rounded,
              label: 'Edit label',
              onTap: () => _showEditLabelSheet(contact),
            ),
            _menuTile(
              ctx: ctx,
              icon: contact.isFavourite
                  ? Icons.star_rounded
                  : Icons.star_outline_rounded,
              label: contact.isFavourite
                  ? 'Remove from favourites'
                  : 'Add to favourites',
              color: _gold,
              onTap: () async {
                await ContactsDb.toggleFavourite(contact.sovereignId);
                _load();
              },
            ),
            _menuTile(
              ctx: ctx,
              icon: Icons.block_rounded,
              label: 'Block contact',
              color: Colors.redAccent,
              onTap: () async {
                await ContactsDb.blockContact(contact.sovereignId);
                _load();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('${contact.displayName} has been blocked.'),
                    backgroundColor: const Color(0xFF7B1A1A),
                    behavior: SnackBarBehavior.floating,
                  ));
                }
              },
            ),
            _menuTile(
              ctx: ctx,
              icon: Icons.delete_outline_rounded,
              label: 'Remove contact',
              color: Colors.redAccent,
              onTap: () async {
                await ContactsDb.removeContact(contact.sovereignId);
                _load();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _menuTile({
    required BuildContext ctx,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? color,
  }) {
    return ListTile(
      leading: Icon(icon, color: color ?? Colors.white70, size: 22),
      title: Text(label,
          style: TextStyle(color: color ?? Colors.white, fontSize: 14)),
      onTap: () {
        Navigator.pop(ctx);
        onTap();
      },
    );
  }

  String _truncateId(String id) {
    if (id.length <= 18) return id;
    return '${id.substring(0, 12)}\u2026${id.substring(id.length - 6)}';
  }

  String _relativeTime(int ms) {
    final diff = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (diff.inMinutes < 60)  return '${diff.inMinutes}m ago';
    if (diff.inHours   < 24)  return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}
