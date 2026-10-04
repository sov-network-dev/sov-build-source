// lib/widgets/academy_visuals.dart
// ─────────────────────────────────────────────────────────────────────────────
// ACADEMY VISUAL GUIDES — self-contained instructional diagrams.
//
// Built from composed Flutter widgets (rounded chips, icon arrows, proportional
// bars, two-column compares) — NOT bundled images and NOT hand-painted canvas —
// so they:
//   • ship inside the app with zero external hosts (CLAUDE.md self-contained law),
//   • add no new packages and no asset weight,
//   • render predictably (each is standard layout, no pixel guesswork).
// Each guide is a titled "at a glance" diagram that makes a protocol legible in
// seconds. Add a new one to [AcademyVisuals.byKey] and reference it from a
// knowledge-bank card's `visual:` key.
// ─────────────────────────────────────────────────────────────────────────────
import 'package:flutter/material.dart';

class AcademyVisuals {
  static const _gold  = Color(0xFFD4AF37);
  static const _navy  = Color(0xFF0A1B33);
  static const _green = Color(0xFF4CAF7D);
  static const _dim   = Colors.white54;

  /// Returns the visual for [key], or null if none.
  static Widget? byKey(String key) {
    switch (key) {
      case 'one_human':      return const _Frame(title: 'One human → one identity', child: _OneHumanDiagram());
      case 'transfer_fee':   return const _Frame(title: 'Where your transfer fee goes', child: _TransferFeeDiagram());
      case 'no_center':      return const _Frame(title: 'A network with no centre', child: _NoCenterDiagram());
      case 'sov_link':       return const _Frame(title: 'Signing in with SOV', child: _SovLinkDiagram());
      case 'sov_link_flow':  return const _Frame(title: 'How a SOV Link login works', child: _SovLinkFlowDiagram());
      case 'supply':         return const _Frame(title: 'The fixed 50,000,000 supply', child: _SupplyDiagram());
      case 'run_node':       return const _Frame(title: 'Running a home node', child: _RunNodeDiagram());
      case 'operator_income':return const _Frame(title: 'How operators earn', child: _OperatorIncomeDiagram());
    }
    return null;
  }

  // ── shared building blocks ─────────────────────────────────────────────────

  static Widget _chip(IconData icon, String label, {Color? tint, Color? border}) {
    final t = tint ?? Colors.white.withOpacity(0.06);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: t,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: border ?? Colors.white.withOpacity(0.12)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: border ?? Colors.white70, size: 22),
        const SizedBox(height: 4),
        SizedBox(
          width: 78,
          child: Text(label, textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 10, height: 1.2)),
        ),
      ]),
    );
  }

  static Widget _arrow({bool down = false, String? label}) {
    final a = Icon(down ? Icons.arrow_downward_rounded : Icons.arrow_forward_rounded,
        color: _gold, size: 20);
    if (label == null) return Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: a);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        a,
        Text(label, style: const TextStyle(color: _gold, fontSize: 9)),
      ]),
    );
  }
}

// ── outer frame with a caption ────────────────────────────────────────────────
class _Frame extends StatelessWidget {
  final String title;
  final Widget child;
  const _Frame({required this.title, required this.child});
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 10, bottom: 4),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF0A1B33).withOpacity(0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFD4AF37).withOpacity(0.25)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.auto_awesome_rounded, color: Color(0xFFD4AF37), size: 13),
          const SizedBox(width: 5),
          // Flexible so a long caption wraps/ellipsizes instead of overflowing on
          // narrow (≤320px) phones — was the cause of the transfer_fee/supply overflow.
          Flexible(
            child: Text(title, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFFD4AF37), fontSize: 11, fontWeight: FontWeight.w700)),
          ),
        ]),
        const SizedBox(height: 10),
        SingleChildScrollView(scrollDirection: Axis.horizontal, child: child),
      ]),
    );
  }
}

// ── 1. one human → one identity ───────────────────────────────────────────────
class _OneHumanDiagram extends StatelessWidget {
  const _OneHumanDiagram();
  @override
  Widget build(BuildContext context) {
    return Row(children: [
      AcademyVisuals._chip(Icons.back_hand_outlined, 'Your palm\n(either hand)', border: AcademyVisuals._gold),
      AcademyVisuals._arrow(label: 'becomes'),
      AcademyVisuals._chip(Icons.vpn_key_rounded, 'Your private key'),
      AcademyVisuals._arrow(),
      AcademyVisuals._chip(Icons.account_balance_wallet_rounded, 'ONE wallet', border: AcademyVisuals._green),
      const SizedBox(width: 10),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: AcademyVisuals._green.withOpacity(0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AcademyVisuals._green.withOpacity(0.4)),
        ),
        child: const SizedBox(
          width: 96,
          child: Text('Your face locks it — even the other hand can\'t make a 2nd account.',
              style: TextStyle(color: Colors.white70, fontSize: 9, height: 1.3)),
        ),
      ),
    ]);
  }
}

// ── 2. transfer fee flow ──────────────────────────────────────────────────────
class _TransferFeeDiagram extends StatelessWidget {
  const _TransferFeeDiagram();
  @override
  Widget build(BuildContext context) {
    return Row(children: [
      AcademyVisuals._chip(Icons.person_outline_rounded, 'You send'),
      AcademyVisuals._arrow(),
      AcademyVisuals._chip(Icons.person_pin_circle_outlined, 'Friend gets\nfull amount', border: AcademyVisuals._green),
      const SizedBox(width: 12),
      Column(mainAxisSize: MainAxisSize.min, children: [
        AcademyVisuals._chip(Icons.percent_rounded, 'Tiny fee\n(capped 1 SOV)', border: AcademyVisuals._gold),
        AcademyVisuals._arrow(down: true, label: 'funds'),
        AcademyVisuals._chip(Icons.lan_outlined, 'Node operators', border: AcademyVisuals._green),
      ]),
    ]);
  }
}

// ── 3. no centre (mesh vs bank) ───────────────────────────────────────────────
class _NoCenterDiagram extends StatelessWidget {
  const _NoCenterDiagram();
  @override
  Widget build(BuildContext context) {
    Widget node() => Container(
        margin: const EdgeInsets.all(3), width: 30, height: 30,
        decoration: BoxDecoration(
          color: AcademyVisuals._green.withOpacity(0.15), shape: BoxShape.circle,
          border: Border.all(color: AcademyVisuals._green.withOpacity(0.5)),
        ),
        child: const Icon(Icons.lan_outlined, color: Colors.white70, size: 15));
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      Column(children: [
        Row(children: [node(), node(), node()]),
        Row(children: [node(), node(), node()]),
        const SizedBox(height: 2),
        const Text('SOV: many equal nodes,\nno centre to shut down',
            textAlign: TextAlign.center, style: TextStyle(color: AcademyVisuals._green, fontSize: 9)),
      ]),
      const SizedBox(width: 16),
      Container(width: 1, height: 70, color: Colors.white24),
      const SizedBox(width: 16),
      Column(children: [
        Container(width: 34, height: 34,
            decoration: const BoxDecoration(color: Color(0x33FF6B6B), shape: BoxShape.circle),
            child: const Icon(Icons.account_balance_rounded, color: Colors.redAccent, size: 18)),
        const SizedBox(height: 6),
        const SizedBox(width: 96, child: Text('A bank: one centre —\nit can freeze or fail',
            textAlign: TextAlign.center, style: TextStyle(color: Colors.redAccent, fontSize: 9))),
      ]),
    ]);
  }
}

// ── 4. SOV Link ───────────────────────────────────────────────────────────────
class _SovLinkDiagram extends StatelessWidget {
  const _SovLinkDiagram();
  @override
  Widget build(BuildContext context) {
    return Row(children: [
      AcademyVisuals._chip(Icons.language_rounded, 'Website shows\n6-digit code'),
      AcademyVisuals._arrow(),
      AcademyVisuals._chip(Icons.smartphone_rounded, 'You confirm\nin SOV app', border: AcademyVisuals._gold),
      AcademyVisuals._arrow(label: 'signs'),
      AcademyVisuals._chip(Icons.verified_user_outlined, 'Logged in —\nno password sent', border: AcademyVisuals._green),
      const SizedBox(width: 10),
      const SizedBox(width: 92, child: Text('Your key never leaves your phone. One human, one account.',
          style: TextStyle(color: Colors.white54, fontSize: 9, height: 1.3))),
    ]);
  }
}

// ── SOV Link — the full two-phase login flow (app-side, step by step) ─────────
class _SovLinkFlowDiagram extends StatelessWidget {
  const _SovLinkFlowDiagram();
  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('First time — you link the site once',
          style: TextStyle(color: AcademyVisuals._gold, fontSize: 10, fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Row(children: [
        AcademyVisuals._chip(Icons.language_rounded, 'Site: tap\n"Sign in\nwith SOV"'),
        AcademyVisuals._arrow(),
        AcademyVisuals._chip(Icons.pin_rounded, 'shows a\n6-digit code', border: AcademyVisuals._gold),
        AcademyVisuals._arrow(label: 'you read it'),
        AcademyVisuals._chip(Icons.smartphone_rounded, 'SOV app:\nConnect to\nExternal Site'),
        AcademyVisuals._arrow(),
        AcademyVisuals._chip(Icons.password_rounded, 'type code,\nconfirm site,\nset password'),
        AcademyVisuals._arrow(label: 'signs'),
        AcademyVisuals._chip(Icons.check_circle_rounded, 'Linked —\nseed never\nleft phone', border: AcademyVisuals._green),
      ])),
      const SizedBox(height: 12),
      const Text('Every time after — instant, no network needed',
          style: TextStyle(color: AcademyVisuals._gold, fontSize: 10, fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Row(children: [
        AcademyVisuals._chip(Icons.login_rounded, 'Site: your ID\n+ that site\npassword'),
        AcademyVisuals._arrow(label: 'checked\non the site'),
        AcademyVisuals._chip(Icons.bolt_rounded, 'Signed in\ninstantly', border: AcademyVisuals._green),
        const SizedBox(width: 10),
        const SizedBox(width: 104, child: Text('The SOV network is not contacted on repeat logins — so it works even offline.',
            style: TextStyle(color: Colors.white54, fontSize: 9, height: 1.3))),
      ])),
    ]);
  }
}

// ── 5. fixed supply split ─────────────────────────────────────────────────────
class _SupplyDiagram extends StatelessWidget {
  const _SupplyDiagram();
  @override
  Widget build(BuildContext context) {
    Widget seg(int flex, Color c, String label) => Expanded(
      flex: flex,
      child: Column(children: [
        Container(height: 20, decoration: BoxDecoration(color: c.withOpacity(0.6),
            border: Border.all(color: c))),
        const SizedBox(height: 3),
        Text(label, textAlign: TextAlign.center, style: TextStyle(color: c, fontSize: 8)),
      ]),
    );
    return SizedBox(
      width: 320,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          seg(30, AcademyVisuals._green, '30M\nEnrollment\nrewards'),
          const SizedBox(width: 3),
          seg(20, AcademyVisuals._gold, '20M\nOperator\npool'),
          const SizedBox(width: 3),
          seg(6, Colors.white, 'Citizen\nwallets'),
        ]),
        const SizedBox(height: 6),
        const Text('Fixed forever at 50,000,000 SOV. Every SOV is in a pool or a wallet — '
            'no one can mint more. You can verify it live on the Economy screen.',
            style: TextStyle(color: Colors.white54, fontSize: 9, height: 1.3)),
      ]),
    );
  }
}

// ── 6. run a home node ────────────────────────────────────────────────────────
class _RunNodeDiagram extends StatelessWidget {
  const _RunNodeDiagram();
  @override
  Widget build(BuildContext context) {
    return Row(children: [
      AcademyVisuals._chip(Icons.desktop_windows_outlined, 'Your PC\n(bundled node)'),
      AcademyVisuals._arrow(label: 'via'),
      AcademyVisuals._chip(Icons.vpn_lock_outlined, 'Tailscale\nFunnel (free)', border: AcademyVisuals._gold),
      AcademyVisuals._arrow(),
      AcademyVisuals._chip(Icons.public_rounded, 'Reachable\nworldwide', border: AcademyVisuals._green),
      AcademyVisuals._arrow(label: 'earns'),
      AcademyVisuals._chip(Icons.savings_outlined, 'SOV for\nuptime', border: AcademyVisuals._green),
    ]);
  }
}

// ── 7. operator income tiers ──────────────────────────────────────────────────
class _OperatorIncomeDiagram extends StatelessWidget {
  const _OperatorIncomeDiagram();
  @override
  Widget build(BuildContext context) {
    Widget tier(String n, String pct, Color c) => Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(9),
          border: Border.all(color: c.withOpacity(0.5))),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(n, style: const TextStyle(color: Colors.white70, fontSize: 10)),
        const SizedBox(height: 2),
        Text(pct, style: TextStyle(color: c, fontSize: 13, fontWeight: FontWeight.bold)),
      ]),
    );
    return Row(children: [
      tier('1st node', '100%', AcademyVisuals._green),
      tier('2nd', '25%', AcademyVisuals._gold),
      tier('3rd', '25%', AcademyVisuals._gold),
      tier('4th+', '0%', Colors.redAccent),
      const SizedBox(width: 6),
      const SizedBox(width: 92, child: Text('Diminishing on purpose — nobody can farm nodes to dominate.',
          style: TextStyle(color: Colors.white54, fontSize: 9, height: 1.3))),
    ]);
  }
}
