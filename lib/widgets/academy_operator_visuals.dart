// Academy operator-onboarding illustrations — "how to run a SOV node".
//
// A parallel registry to widgets/academy_visuals.dart, focused on the operator
// path: choosing a host, opening the firewall (the part that actually blocks
// people), the per-provider console walkthroughs (Google Cloud / Amazon AWS /
// Oracle Cloud), installing the node snap, and the zero-VPS Windows path.
//
// Every fact here is distilled from the authoritative repo docs so operators can
// follow it literally:
//   - docs/NEW_VPS_ALWAYS_FREE_SETUP.md   (two-layer firewall, x86_64 rule, ports)
//   - docs/GENESIS_SNAP_INSTALL_PLAN.md   (snap download/verify/install)
//   - docs/OPERATOR_GUIDE_Windows_Tailscale.md (Path A auto / Path B Funnel)
//   - network_manager.js                  (SOV_PORT=443, SYNC_PORT=7771)
//
// Design constraint: these render inside a NARROW (~238px) Knowledge Bank card,
// so every layout is a vertical Column with wrapping (Expanded/Flexible) text —
// no horizontally-overflowing Rows. Verified by
// test/academy_operator_visuals_overflow_test.dart.
import 'package:flutter/material.dart';

// ── house palette (library-private) ──────────────────────────────────────────
const _gold  = Color(0xFFD4AF37);
const _navy  = Color(0xFF0A1B33);
const _green = Color(0xFF4CAF7D);
const _red   = Color(0xFFE0685A);
const _blue  = Color(0xFF5B8DEF);

class AcademyOperatorVisuals {
  /// Returns a self-contained diagram for [key], or null if unknown.
  static Widget? byKey(String key) {
    switch (key) {
      case 'op_providers': return const _OpFrame(title: 'Where to run your node', child: _ProvidersDiagram());
      case 'op_firewall':  return const _OpFrame(title: 'Two doors must open — the firewall', child: _FirewallDiagram());
      case 'op_gcp':       return const _OpFrame(title: 'Google Cloud — open the ports', child: _GcpDiagram());
      case 'op_aws':       return const _OpFrame(title: 'Amazon AWS — open the ports', child: _AwsDiagram());
      case 'op_oracle':    return const _OpFrame(title: 'Oracle Cloud — open BOTH layers', child: _OracleDiagram());
      case 'op_snap':      return const _OpFrame(title: 'Install the node software (snap)', child: _SnapDiagram());
      case 'op_windows':   return const _OpFrame(title: 'Run a node on Windows — no VPS', child: _WindowsDiagram());
    }
    return null;
  }
}

// ── shared building blocks ─────────────────────────────────────────────────

/// A gold numbered step: [n] + wrapping text (+ optional trailing badge).
Widget _step(int n, String text, {Widget? trailing, Color? accent}) {
  final c = accent ?? _gold;
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        width: 22, height: 22,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: c.withOpacity(0.15), shape: BoxShape.circle,
          border: Border.all(color: c.withOpacity(0.6)),
        ),
        child: Text('$n', style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w700)),
      ),
      const SizedBox(width: 9),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(text, style: const TextStyle(color: Colors.white70, fontSize: 11.5, height: 1.35)),
        ),
      ),
      if (trailing != null) ...[const SizedBox(width: 6), trailing],
    ]),
  );
}

/// A full-width callout box (warning / info / good).
Widget _note(IconData icon, String text, Color color) {
  return Container(
    margin: const EdgeInsets.only(top: 2, bottom: 8),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: color.withOpacity(0.10),
      borderRadius: BorderRadius.circular(9),
      border: Border.all(color: color.withOpacity(0.4)),
    ),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, color: color, size: 15),
      const SizedBox(width: 7),
      Expanded(
        child: Text(text, style: TextStyle(color: color, fontSize: 11, height: 1.35, fontWeight: FontWeight.w600)),
      ),
    ]),
  );
}

/// A monospace-ish command line, softly boxed. Scrolls horizontally if long
/// (a command must never wrap mid-flag).
Widget _cmd(String text) {
  return Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      color: Colors.black.withOpacity(0.30),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: Colors.white.withOpacity(0.10)),
    ),
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Text(text,
          style: const TextStyle(color: _green, fontSize: 10.5, height: 1.3, fontFamily: 'monospace')),
    ),
  );
}

/// A small labelled pill (e.g. a port or a tag).
Widget _pill(String text, Color color) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color.withOpacity(0.15),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withOpacity(0.55)),
    ),
    child: Text(text, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700)),
  );
}

/// One row of the port table: port + purpose + OPEN/CLOSED status.
Widget _portRow(String port, String purpose, {required bool open}) {
  final c = open ? _green : _red;
  return Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      SizedBox(
        width: 52,
        child: Text(port, style: const TextStyle(color: _gold, fontSize: 12, fontWeight: FontWeight.w800)),
      ),
      const SizedBox(width: 6),
      Expanded(
        child: Text(purpose, style: const TextStyle(color: Colors.white60, fontSize: 11, height: 1.25)),
      ),
      const SizedBox(width: 6),
      _pill(open ? 'OPEN' : 'CLOSED', c),
    ]),
  );
}

/// Section sub-heading inside a diagram.
Widget _head(String text, {Color? color}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 7, top: 2),
    child: Text(text.toUpperCase(),
        style: TextStyle(
            color: color ?? _gold, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.6)),
  );
}

// ── outer frame with a caption (matches academy_visuals house style) ──────────
class _OpFrame extends StatelessWidget {
  final String title;
  final Widget child;
  const _OpFrame({required this.title, required this.child});
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 10, bottom: 4),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: _navy.withOpacity(0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _gold.withOpacity(0.25)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.menu_book_rounded, color: _gold, size: 13),
          const SizedBox(width: 5),
          Flexible(
            child: Text(title, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _gold, fontSize: 11, fontWeight: FontWeight.w700)),
          ),
        ]),
        const SizedBox(height: 10),
        // Content is a bounded, wrapping Column — no horizontal overflow.
        child,
      ]),
    );
  }
}

// ── 1. providers — where to host ──────────────────────────────────────────────
class _ProvidersDiagram extends StatelessWidget {
  const _ProvidersDiagram();

  Widget _provider(IconData icon, String name, String cost, String note, Color tint) {
    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: tint.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tint.withOpacity(0.35)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: tint, size: 18),
        const SizedBox(width: 9),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(height: 1),
            Text(cost, style: TextStyle(color: tint, fontSize: 10.5, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(note, style: const TextStyle(color: Colors.white54, fontSize: 10.5, height: 1.3)),
          ]),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _provider(Icons.verified_rounded, 'Oracle Cloud — Always Free',
          'Free forever · recommended', 'No 12-month expiry. Pick shape VM.Standard.E2.1.Micro (AMD).', _green),
      _provider(Icons.cloud_rounded, 'Google Cloud — e2-micro',
          'Always-free tier · x86_64', 'Free in us-west1/central1/east1. Watch billing alerts.', _blue),
      _provider(Icons.shopping_cart_rounded, 'Amazon AWS — t3.micro',
          'Free 12 months only', 'Fine to learn on; becomes paid after a year. Not ideal for a permanent node.', _gold),
      _provider(Icons.desktop_windows_rounded, 'Your Windows PC — at home',
          'Free · no VPS · easiest', 'Install the SOV app, toggle Run-a-Node. See the Windows guide.', _green),
      _note(Icons.memory_rounded,
          'Pick an x86_64 (Intel/AMD) shape — NOT ARM (Oracle Ampere / AWS Graviton). The node ships an x86_64 runtime and will not start on ARM.',
          _red),
      _note(Icons.info_outline_rounded,
          'Any provider works (paid droplets, a home server, an x86 box) as long as it has a public IPv4 and you can open the ports.',
          _blue),
    ]);
  }
}

// ── 2. firewall — the two doors + port table ──────────────────────────────────
class _FirewallDiagram extends StatelessWidget {
  const _FirewallDiagram();

  Widget _door(String n, IconData icon, String title, String sub) => Container(
    margin: const EdgeInsets.only(bottom: 7),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
    decoration: BoxDecoration(
      color: _gold.withOpacity(0.08),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: _gold.withOpacity(0.4)),
    ),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, color: _gold, size: 18),
      const SizedBox(width: 9),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$n  $title', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(sub, style: const TextStyle(color: Colors.white54, fontSize: 10.5, height: 1.3)),
        ]),
      ),
    ]),
  );

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Most clouds block ports in TWO places. Open both or citizens cannot reach your node.',
          style: TextStyle(color: Colors.white70, fontSize: 11.5, height: 1.4)),
      const SizedBox(height: 10),
      _door('Door 1', Icons.cloud_outlined, 'Cloud firewall',
          'Security List (Oracle) · Security Group (AWS) · VPC firewall rule (Google). Set in the provider console.'),
      _door('Door 2', Icons.dns_outlined, 'Machine firewall',
          'Ubuntu iptables / ufw on the box itself. Oracle images ship this closed — the #1 "why can nobody reach me" cause.'),
      const SizedBox(height: 2),
      _head('Open these ports inbound (TCP, source 0.0.0.0/0)'),
      _portRow('443', 'Citizens connect here (main)', open: true),
      _portRow('7771', 'Peer mesh — node to node', open: true),
      _portRow('80', 'Snap download + health', open: true),
      _portRow('22', 'SSH — admin (limit to your IP)', open: true),
      _portRow('8080', 'Dashboard — LOCAL only', open: false),
      _note(Icons.lock_outline_rounded,
          'Never expose 8080 to the internet — it is the private node dashboard and is meant to stay on localhost.',
          _red),
    ]);
  }
}

// ── 3. Google Cloud ───────────────────────────────────────────────────────────
class _GcpDiagram extends StatelessWidget {
  const _GcpDiagram();
  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _head('Create the instance'),
      _step(1, 'Compute Engine → VM instances → Create. Region us-west1 / us-central1 / us-east1, machine type e2-micro (always-free).'),
      _step(2, 'Boot disk: Ubuntu 22.04 LTS (x86_64). Allow HTTP/HTTPS if asked. Create — copy the External IP.'),
      _head('Open the ports (VPC firewall)'),
      _step(3, 'VPC network → Firewall → Create firewall rule.'),
      _step(4, 'Direction Ingress · Targets: All instances · Source IPv4 ranges 0.0.0.0/0.'),
      _step(5, 'Protocols/ports → TCP → type: 443,7771,80,22 → Create.'),
      _step(6, 'GCP Ubuntu images do not ship an extra host firewall, so Door 2 is usually already open — verify you can reach port 443 after installing.'),
      _note(Icons.warning_amber_rounded,
          'GCP free instances have been billing-terminated before — set a Budget alert at \$1 so an accident cannot silently run up a bill.',
          _gold),
    ]);
  }
}

// ── 4. Amazon AWS ─────────────────────────────────────────────────────────────
class _AwsDiagram extends StatelessWidget {
  const _AwsDiagram();
  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _head('Launch the instance'),
      _step(1, 'EC2 → Launch instance. AMI: Ubuntu 22.04 LTS (64-bit x86). Type: t3.micro or t2.micro (free-tier eligible).'),
      _step(2, 'Create/choose a key pair (download the .pem — it is your SSH key). Launch — note the Public IPv4.'),
      _head('Open the ports (Security Group)'),
      _step(3, 'EC2 → Network & Security → Security Groups → select this instance\'s group → Inbound rules → Edit.'),
      _step(4, 'Add rule → Custom TCP → Port 443 → Source Anywhere-IPv4 (0.0.0.0/0). Repeat for 7771 and 80.'),
      _step(5, 'Keep the SSH (22) rule; tighten its source to My IP. Save rules.'),
      _note(Icons.schedule_rounded,
          'AWS free tier is only 12 months — great to learn on, but for a permanent node prefer Oracle Always Free (no expiry).',
          _gold),
    ]);
  }
}

// ── 5. Oracle Cloud ───────────────────────────────────────────────────────────
class _OracleDiagram extends StatelessWidget {
  const _OracleDiagram();
  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _note(Icons.star_rounded, 'Recommended host: free forever, no 12-month expiry.', _green),
      _head('Create the instance'),
      _step(1, 'Compute → Instances → Create. Image: Canonical Ubuntu 22.04.'),
      _step(2, 'Change shape → AMD → VM.Standard.E2.1.Micro (Always-Free-eligible). Do NOT pick Ampere A1 — that is ARM.', accent: _red),
      _step(3, 'Assign a public IPv4 = Yes. Paste your SSH public key. Create — copy the Public IP.'),
      _head('Door 1 — cloud Security List'),
      _step(4, 'Networking → Virtual Cloud Networks → your VCN → Security Lists → Default → Add Ingress Rules.'),
      _step(5, 'For each of 22, 80, 443, 7771: Source 0.0.0.0/0 · IP Protocol TCP · that Destination Port.'),
      _head('Door 2 — the box\'s own firewall'),
      _step(6, 'SSH in, then run (Oracle images block these by default):'),
      _cmd('sudo iptables -I INPUT 6 -p tcp --dport 443 -j ACCEPT'),
      _cmd('sudo iptables -I INPUT 6 -p tcp --dport 7771 -j ACCEPT'),
      _cmd('sudo iptables -I INPUT 6 -p tcp --dport 80 -j ACCEPT'),
      _cmd('sudo netfilter-persistent save'),
      _note(Icons.priority_high_rounded,
          'Skipping Door 2 is the classic Oracle mistake — the console shows the ports "open" but the box still drops them.',
          _red),
    ]);
  }
}

// ── 6. Snap install ───────────────────────────────────────────────────────────
class _SnapDiagram extends StatelessWidget {
  const _SnapDiagram();
  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _head('Download from a live node'),
      _step(1, 'The node software is served by the network itself — no GitHub, no app store. Pull it from a running node:'),
      _cmd('curl -O http://203.0.113.10/sov-relay.snap'),
      _head('Verify it is authentic'),
      _step(2, 'Download the SAME file from a second node and compare hashes — they must match, which proves no one tampered with it:'),
      _cmd('curl -o b.snap http://203.0.113.12/sov-relay.snap'),
      _cmd('sha256sum sov-relay.snap b.snap'),
      _head('Install'),
      _step(3, 'Install snapd if missing, then install the snap (--dangerous = not from the Store, by design; --devmode = unconfined for now):'),
      _cmd('sudo apt-get install -y snapd'),
      _cmd('sudo snap install --dangerous --devmode sov-relay.snap'),
      _head('Configure your node identity'),
      _step(4, 'Stop it, edit the .env, then start again:'),
      _cmd('sudo nano /var/snap/sov-relay/current/.env'),
      _step(5, 'Set RELAY_ID (a name you choose), RELAY_IP (this box\'s public IP), and leave RELAY_POOL_IPS as the live nodes so you find the mesh on first boot.'),
      _head('Watch it join'),
      _step(6, 'Follow the boot log — you want to see it load identity, bind the ports, and connect to peers:'),
      _cmd('sudo snap logs -f sov-relay.sov-relay'),
      _note(Icons.savings_outlined,
          'Once it converges and stays continuously up for the qualifying period (~3 weeks), your node starts earning the operator payout.',
          _green),
    ]);
  }
}

// ── 7. Windows (no VPS) ───────────────────────────────────────────────────────
class _WindowsDiagram extends StatelessWidget {
  const _WindowsDiagram();
  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('No VPS, no Linux, no firewall edits — the SOV app is itself a full node.',
          style: TextStyle(color: Colors.white70, fontSize: 11.5, height: 1.4)),
      const SizedBox(height: 10),
      _head('Path A — normal home broadband'),
      _step(1, 'Install the SOV app (SovNode.exe) and sign in / restore your wallet.'),
      _step(2, 'Open the Node tab → the "Run a Node" card. Leave Reachability = Auto.'),
      _step(3, 'Toggle Run a Node → ON. It opens your router by UPnP, or relays through the mesh if it can\'t. When live it shows "Reachable at: …".'),
      _note(Icons.bolt_rounded, 'That is the whole setup for most people. Keep the PC on — uptime is what earns.', _green),
      _head('Path B — hotspot / CGNAT / can\'t port-forward'),
      _step(1, 'Make a free Tailscale account (login.tailscale.com/start) and install Tailscale for Windows; log in once.', accent: _blue),
      _step(2, 'In the SOV app: Node tab → set Reachability = Tailscale Funnel → toggle ON.', accent: _blue),
      _step(3, 'First time only, tap "Enable Tailscale Funnel" and click Approve in the browser. The app then serves at wss://<your-pc>.ts.net.', accent: _blue),
      _note(Icons.public_rounded,
          'Funnel gives you a stable public HTTPS address for free, over an outbound-only connection — citizens reach you on 443 with no port-forward.',
          _blue),
    ]);
  }
}
