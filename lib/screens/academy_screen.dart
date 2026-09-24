// lib/screens/academy_screen.dart
// ─────────────────────────────────────────────────────────────────────────────
// S7 — SOV Academy
//
// Three certification tracks + static Knowledge Bank (civic education) +
// live Community Articles (relay-native, citizen-published).
//
// The Knowledge Bank is static — it contains articles extracted from the
// SOV Protocol Book that are safe to publish (see the project content policy).
// Community Articles are dynamic — citizens publish via ACADEMY_PUBLISH for
// a bond of academy_article_bond SOV. Cross-relay via ACADEMY_ARTICLE_BROADCAST.
// ─────────────────────────────────────────────────────────────────────────────
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:shared_preferences/shared_preferences.dart';
import '../sov_node_sdk/relay_connector.dart';
import '../widgets/academy_visuals.dart';
import '../widgets/academy_operator_visuals.dart';
import '../widgets/academy_shot.dart';
import 'pioneer_screen.dart';

class AcademyScreen extends StatefulWidget {
  final String sovereignId;
  const AcademyScreen({super.key, required this.sovereignId});

  @override
  State<AcademyScreen> createState() => _AcademyScreenState();
}

class _AcademyScreenState extends State<AcademyScreen> {
  static const _navy   = Color(0xFF0A1628);
  static const _gold   = Color(0xFFD4AF37);
  static const _cardBg = Color(0xFF0D1F3A);

  // ── Certification state ────────────────────────────────────────────────────
  bool _loading = true;
  Map<String, bool> _certs = {
    'relay_engineer':      false,
    'enrollment_agent':    false,
    'protocol_specialist': false,
  };

  // ── Community articles state ───────────────────────────────────────────────
  List<Map<String, dynamic>> _articles = [];
  bool _articlesLoading = false;
  String _articlesError = '';
  String _filterCategory = 'all';

  // Set of article_ids this citizen has already upvoted (persisted locally)
  Set<String> _myUpvotes = {};

  // Palm name cache for article authors — filled asynchronously.
  final Map<String, String> _authorNames = {};
  bool _fabVisible = true; // Write Article button hides while scrolling down

  // Course definitions
  static const _courses = [
    (
      spec:       'relay_engineer',
      label:      'Node Operator',
      shortLabel: 'OP',
      icon:       Icons.router_outlined,
      selIcon:    Icons.router,
      desc:       'Learn how the SOV Network operates, how nodes keep the shared ledger in sync, and how to run the infrastructure that powers every transaction — a service you can charge for.',
    ),
    (
      spec:       'enrollment_agent',
      label:      'Enrollment Helper',
      shortLabel: 'EH',
      icon:       Icons.person_add_outlined,
      selIcon:    Icons.person_add,
      desc:       'Master the citizen onboarding process, wallet setup, and recovery options so you can guide new citizens onto the network with confidence — as a paid service.',
    ),
    (
      spec:       'protocol_specialist',
      label:      'Protocol Expert',
      shortLabel: 'PX',
      icon:       Icons.hub_outlined,
      selIcon:    Icons.hub,
      desc:       'Understand the full SOV economy — the fixed supply, one-human-one-vote governance, the peer exchange, and how platforms and businesses integrate — and advise them for a fee you set.',
    ),
  ];

  // Static Knowledge Bank articles — safe civic education content
  static const _knowledgeBank = [
    (icon: Icons.info_outline_rounded,       title: 'What SOV is, and what it is not',
     body: 'SOV is not a blockchain. There is no chain of blocks, no mining race, and no '
           'company, foundation or operator standing behind the network. Your identity is not '
           'an account someone issues you and can take away: it is a palm read on your own '
           'device, which never leaves it. One living human, one wallet, proven without a '
           'name, an email or a phone number. Anyone can run a node, and the nodes are run by '
           'citizens, not by us.'),
    (icon: Icons.public_rounded,             title: 'The world needed something new',
     body: 'Bitcoin proved that money does not need a bank. But Bitcoin never solved identity, communication, or justice. The SOV Network was built to go further — a single network where you own your identity, your money, your messages, and your voice in how the rules are written. Not controlled by any company. Not dependent on any government. Built to outlast them both.'),
    (icon: Icons.hub_outlined,               title: 'Not a blockchain — a Sovereign Mesh',
     body: 'SOV is NOT a blockchain. There are no blocks, no chain of blocks, no mining race, and no global queue every payment must wait in. SOV is a SOVEREIGN MESH: self-contained nodes that gossip peer-to-peer, each holding the shared ledger, confirming transactions by witnessing them rather than by burning energy. It is called a "mesh" because the nodes form a web with no centre — any node can leave or join and the network carries on; and "sovereign" because YOU — not a company, not a chain — own your identity, your money, and your voice. Its one genuinely new idea is PROOF OF PERSONHOOD: one human, one wallet, proven by your own biometrics on your own device. That is what no blockchain has — the network knows you are a real, unique person without knowing who you are. So when you describe SOV, don\'t reach for "crypto" or "blockchain". Say what it actually is: a sovereign, proof-of-personhood mesh — self-contained nodes, one human one wallet, no central operator, and no app store.'),
    (icon: Icons.fingerprint_rounded,        title: 'Your identity is your key — nothing else',
     body: 'Every other network asks you to trust a company with your password, your phone number, or your email. SOV asks for none of those. Your palm is your key. It cannot be stolen, guessed, or reset by a corporation. When you enroll, your biometric is processed on your device and never sent to any server. Your Sovereign ID is yours permanently — no account to be banned, no service to be shut down.'),
    (icon: Icons.currency_bitcoin,           title: 'Everything Bitcoin is — and everything it is not',
     body: 'Bitcoin is digital gold — scarce, decentralized, and unstoppable. SOV respects that design. But Bitcoin has no identity layer, no messaging, no governance, no justice system, and no built-in community. It cannot tell who is human and who is a bot. SOV solves all of that. One human, one wallet. The network knows you are real — and that changes everything.'),
    (icon: Icons.security_rounded,           title: 'The last network that can be built this way',
     body: 'Governments are moving fast to regulate digital identity and digital money. The window to build a truly free, sovereign network is closing. SOV was designed from the ground up to operate behind firewalls, survive hostile infrastructure, and resist seizure — because citizens in many countries cannot afford to wait for permission. Every citizen who joins today makes it harder to stop tomorrow.'),
    (icon: Icons.wifi_off_rounded,           title: 'Works behind firewalls and in blackouts',
     body: "SOV Speak routes messages through relay nodes that operate on standard ports. Even in countries that block popular apps, SOV messages get through. When a recipient is offline, the message stays in the sender's outbox on their own device — the relay stores nothing. The moment the recipient reconnects, the network broadcasts their presence and the sender's device automatically delivers. No message content ever touches a relay. No conversation can be intercepted."),
    (icon: Icons.account_balance_wallet_outlined, title: 'How SOV works',
     body: 'SOV is a peer-validated digital currency secured by biometric identity. Every citizen gets a wallet, a Sovereign ID, and a permanent place on the shared ledger. No bank account required. No minimum balance. No credit check. If you are human and you have a phone, you qualify.'),
    (icon: Icons.people_outline_rounded,     title: 'One human, one wallet', visual: 'one_human',
     body: 'The SOV Network allows exactly one wallet per person, enforced by biometric identity. There are no bots, no fake accounts, and no whales who joined 100 times. Every citizen has equal weight in governance. Every new citizen gets the same fresh start. The network is designed for people — not corporations, not algorithms.'),
    (icon: Icons.gavel_rounded,              title: 'Justice without courts',
     body: 'On the SOV Network, citizens have a real dispute process — no lawyers, no fees, no waiting months for a ruling. If a transaction is disputed, five citizens selected at random review the evidence and vote. The majority decides. Funds move according to the verdict within 72 hours. This is the first digital economy where justice is built into the protocol.'),
    (icon: Icons.how_to_vote_outlined,       title: 'Your vote actually changes the rules',
     body: 'The Network Constitution is not a document written by a company and handed to you. It is a living set of protocols that citizens vote to activate. Every enrolled citizen votes equally — your balance does not change your weight. If 5,000 citizens vote to enable a new feature, it activates for the whole network. The citizens own the rules.'),
    (icon: Icons.monetization_on_outlined,   title: 'SOV Value and the ⟡ symbol',
     body: 'The ⟡ symbol represents the SOV reference rate — the citizen-voted guide price of 1 SOV. Once 5,000 citizens enroll, the network holds its first value vote. Citizens propose a price. The median of all proposals becomes the rate. It updates every 10,000 new enrollments. No exchange sets this number. No company owns it. Citizens decide the value of what they built.'),
    (icon: Icons.work_outline_rounded,       title: 'A real economy — not a speculation game',
     body: 'SOV is not designed to be traded on exchanges and pumped by speculators. It is designed to be earned, spent, and saved by real citizens doing real things. Node Operators earn for running the infrastructure that carries every transaction. Justice jurors earn for resolving disputes fairly. Citizens earn by providing genuine goods and services to one another. The SOV economy rewards real participation, not speculation and not recruitment.'),
    (icon: Icons.swap_horiz_rounded,         title: 'Sending and receiving SOV', visual: 'transfer_fee',
     body: "Send SOV to any citizen using their Sovereign ID. Transactions confirm in seconds across the relay network. The only cost is a tiny network fee — a fraction of a percent of the amount you send, capped so no transfer ever costs more than a small fixed ceiling (current defaults set by citizen vote). That fee is not taken by any company: it flows into the operator reward pool that pays the citizens hosting the network. No intermediaries, no waiting for business hours. Recent transactions sync to your device automatically every time you connect — so anything that arrived while you were offline is waiting for you. Your wallet is your own record; use the Backup & Restore feature to back up your history and keep it safe."),
    (icon: Icons.chat_bubble_outline_rounded, title: 'SOV Speak — messaging with receipts',
     body: 'SOV Speak lets you send messages, voice notes, photos, and files to any citizen on the network. Every message shows a delivery status: Sending → Delivered → Read. You can send SOV directly inside a conversation — the payment appears as a receipt in the chat thread. No phone number required. No SIM card. Just your Sovereign ID.'),
    (icon: Icons.shield_outlined,            title: 'Protecting your wallet',
     body: 'Your wallet is secured by your 12-word seed phrase, an optional 6-digit PIN, and guardian recovery. Write your seed phrase on paper and store it safely — it is the only way to restore your wallet if your phone is lost or stolen. No central authority can freeze your funds, reset your access, or demand your keys. This is what it means to truly own your money.'),
    (icon: Icons.lan_outlined,               title: 'Running the network', visual: 'no_center',
     body: 'The SOV Network runs on nodes operated by certified Node Operators around the world. Relays keep the shared ledger in sync, deliver messages, and witness transactions. The more operators there are, the stronger, faster, and more resilient the network becomes. Any citizen with a server can become a relay operator. This is infrastructure owned by the people who use it.'),
    (icon: Icons.verified_user_outlined,     title: 'SOV Link — sign into any website as a verified human', visual: 'sov_link',
     body: 'SOV Link lets any website or app accept your Sovereign ID as a login. It works in two phases. The FIRST time you visit a SOV-enabled site, you tap "Sign in with SOV", and the browser shows you a 6-digit pairing code. You open your SOV app, tap Settings → Connect to External Site, type the code, confirm the site name, and choose a password just for that site. Your SOV app signs the link on the device — your seed phrase never enters the browser, never reaches the external site, and never touches the network in readable form. EVERY TIME after that, the site shows a normal username + password form. You type your Sovereign ID (or palm name) and the password you created for that site. The site checks the password locally on its own server — the SOV network is not contacted at all on repeat logins. This means your day-to-day sign-ins are instant and work even when the SOV network is busy or offline. The password is bound to that specific site, so if one site is breached the credential cannot be reused anywhere else.'),
    (icon: Icons.qr_code_2_outlined,         title: 'Why SOV Link does not use QR codes',
     body: 'Many login systems use a QR code on the desktop that you scan with your phone. SOV Link deliberately does NOT do this. A photographed or screenshotted QR code is a fully valid login token — anyone who captures the picture could log in as you before you do. SOV Link uses a short 6-digit numeric pairing code instead. The code is one-use, expires in 90 seconds, and is bound to the specific website domain you are trying to sign in to. Even if someone watches you type it, it has already been consumed by the time they could try to use it, and it only works for one site anyway. This is a deliberate design choice — small operational friction (typing 6 digits) traded for a meaningful improvement in phishing resistance.'),
    (icon: Icons.menu_book_outlined,         title: 'SOV Link — full protocol walkthrough', visual: 'sov_link_flow',
     body: 'For a detailed end-to-end walkthrough showing what every actor does — a developer connecting a website, a citizen signing in for the first time, and that citizen returning a week later — see the SOV Link Guide, published with the SOV software as a PDF. It explains the two-phase model (a one-time link, then relay-free repeat logins), why SOV Link uses a short pairing code instead of a QR code, and what guarantees the protocol delivers versus what it does NOT do. Written so a non-technical reader can follow it straight through.'),
    (icon: Icons.code_outlined,              title: 'SOV Link — developer guide', visual: 'sov_link_flow',
     body: 'If you build the website side, the SOV Link Developer Guide (a PDF published with the SOV software) walks you from "I have heard of SOV Link" to "my site accepts SOV Link logins" in about half an hour. It gives ready-to-use example code for the two small pieces your server needs — one that starts a sign-in, and one that receives the confirmation when the citizen approves it — plus a simple login page and a testing checklist. It assumes you know a common web language but assumes nothing about SOV. In short: the walkthrough tells you WHAT happens during a SOV Link sign-in; the developer guide gives you the working example that makes it happen on your own site.'),
    (icon: Icons.integration_instructions_outlined, title: 'For platform builders — connect in 15 minutes', visual: 'sov_link_flow',
     body: 'If you run a website or app and want one-human-one-account, SOV Login is the easiest way to add it. You do three things: connect your platform once on the network, add a "Sign in with SOV" button that shows the citizen a 6-digit pairing code (the citizen approves it inside their SOV app under "Connect to External Site" — no seed phrase is ever typed into a browser and there is no login page hosted by anyone else), and accept the signed confirmation when the citizen returns. On your side you simply keep one account per Sovereign ID — the SOV identity layer already guarantees one person per ID, so you get a bot-proof, one-person-one-account user base with no captchas, no SMS codes, and no KYC paperwork. The SOV Link Developer Guide (PDF) has copy-paste examples.'),
    (icon: Icons.app_registration_outlined, title: 'Connecting a new platform to the network',
     body: 'Before a website can offer "Sign in with SOV", it has to be connected to the network — and there is no admin office, no corporate sign-up, and no key handed out by a company. It is done by an enrolled SOV citizen who approves the request with their own identity and pays a small one-time SOV fee (currently 10 SOV, set by citizen vote). That fee flows into the operator reward pool that pays the people running the network — the total SOV supply never changes. The network keeps no special administrative override: by design, only a real, biometrically verified human can add a platform. The connection tool is served by every node on the network, so any builder can get it directly from a node and run it themselves — no app store, no central download server, no third party. Running it generates the platform\'s own keys, signs the request, and returns a private confirmation secret only that platform can read. From that moment the platform is live. Because the same tool ships inside the node software, the ability to connect new platforms spreads with the network itself.'),
    (icon: Icons.checklist_rounded, title: 'Add "Sign in with SOV" — the exact steps',
     body: 'This is the complete, do-it-today setup — no PDF needed. It is two short jobs: the OWNER registers the site from their wallet, then a developer drops one file in place.\n\n'
         'PART 1 — THE OWNER (2 minutes, inside the SOV app):\n'
         '1. Open Profile → tap "Register a Platform".\n'
         '2. Type your website domain (e.g. myshop.com).\n'
         '3. Type your Callback URL — the page on your site that will receive the signed login result (e.g. https://myshop.com/api/auth/sov-callback). If you are not sure, your developer will tell you; you can re-register later.\n'
         '4. Tap "Register & Pay Fee". Your wallet signs it and the one-time 10 SOV fee goes to the node-operator pool. No servers, no command line.\n'
         '5. The app then hands you a DOWNLOAD: a small .zip (sov-login-<yourdomain>.zip). Inside are just two files — "sov-login.php" (your ready-to-use plugin, with your platform ID, your private callback secret and the node list already baked in) and "README.txt".\n\n'
         'PART 2 — HAND IT TO YOUR DEVELOPER (or do it yourself):\n'
         'Send them that .zip. It already contains your keys — there is nothing to configure. Tell them: "keep sov-login.php on the server, never put it in a public code repo — it holds our login secret." Then they do three things:\n'
         '  • Step 1: Upload sov-login.php into the web root, next to the login page.\n'
         '  • Step 2: On the "Sign in with SOV" button, add:  require_once "sov-login.php"; SovLogin::initiate();  — that starts the sign-in and returns the 6-digit pairing code to show the visitor.\n'
         '  • Step 3: On the callback page (the URL from step 3 above), add:  require_once "sov-login.php"; \$data = SovLogin::handleCallback();  — the plugin verifies the network\'s signature for you, and \$data["sovereign_id"] is the verified citizen. Start their session and you are done.\n\n'
         'That is the whole integration. Because SOV already guarantees one human per identity, keeping one account per sovereign_id gives you a bot-proof, one-person-one-account user base with no passwords to store, no captcha, no SMS codes and no KYC paperwork. Repeat logins after the first are checked on your own server, so they are instant and keep working even if the network is busy.'),
    // ── Protocol Book chapters — the Academy teaches the protocols in plain
    //    language so citizens can study, qualify, and provide services.
    (icon: Icons.badge_outlined,             title: 'Protocol: Why SOV has no usernames',
     body: 'SOV deliberately has no usernames, no @handles and no display names you can choose. That is a privacy decision, not a missing feature. The moment citizens can type their own name, some of them will type their REAL name — and a network that promised no personal data would be quietly leaking it, permanently and publicly. So the protocol never offers the field at all. Instead every citizen gets a nickname the network derives from their Sovereign ID: the same ID always produces the same nickname, on every device, with no lookup and nothing stored. It is generated on your own device, so it never travels anywhere and no server holds a name table. Your Sovereign ID remains the only network identity; the nickname exists purely so humans can recognise a contact at a glance instead of reading a 20-character string. Nobody can buy, squat, transfer or impersonate one, because nobody chooses one — including you.'),
    (icon: Icons.lock_person_rounded,        title: 'Protocol: The Sealed-Launch Invariant (§905)',
     body: 'Once the network ships its first signed release, the code has NO special admin key — every privileged action must be authorised by a real biometrically enrolled citizen, approving it with their own on-device key and paying any fee from their own wallet. There is no admin token, no super-user key, no founder override, and no hidden "administrator" flag anywhere. Connecting a platform, creating a poll, filing a petition, opening a dispute, publishing an Academy article — all follow the same rule: the citizen approves the action on their own device (the private key never leaves it), the network confirms it really came from that enrolled citizen and is fresh (not a replay), takes any required fee, and performs it. This is why SOV cannot be centralised by anyone — not a founder, not an operator coalition, not a state: the only way to act for a citizen is to BE that citizen, holding their key.'),
    (icon: Icons.draw_rounded,               title: 'Protocol: Petitions — the off-cadence governance path',
     body: 'A petition lets any enrolled citizen propose changing a governance parameter without waiting for a formal poll cycle. Fellow citizens SIGN it (one signature per citizen, enforced at the database layer). If signatures cross the supermajority threshold (default 67% of enrolled citizens) the change activates immediately — no poll needed. If they cross the lower threshold (default 33%) a normal governance poll is created automatically for the rest of the network to vote on. If neither threshold is met before expiry, the petition is rejected by silence. Petitions are the escape hatch alongside paced polls: a clear supermajority skips debate; a significant minority escalates to a vote; weak support simply lapses. Both thresholds are themselves citizen-tunable.'),
    (icon: Icons.tune_rounded,               title: 'Protocol: How citizens govern every value (4-part contract)',
     body: 'Every value citizens can vote on follows a mandatory four-part contract so there are NO hidden hardcoded constants after launch: (1) the parameter is declared with its range, (2) seeded with a sensible default on first boot, (3) read from the governance table at runtime (never a baked-in number), and (4) given a pre-built poll in the app Constitution tab. There are dozens of such parameters today — poll durations, fee rates, jury sizes, retention windows, fee rates, and more — and the registry grows as new features land via the same contract. A critical rule: governance values are always read as strings and compared exactly (a binary protocol gate checks == "1"), because a number cast silently breaks the gate. If citizens should be able to vote on it, it must pass through all four parts — no exceptions. This is the §905 invariant made concrete: the way a feature is written determines whether citizens can adjust it.'),
    // ── Economy / fee protocols (added 2026-07-19 as these shipped) ───────────
    (icon: Icons.receipt_long_outlined,      title: 'Protocol: Network fees — small, capped, and paid to the people who run it', visual: 'transfer_fee',
     body: 'SOV charges small, citizen-voted fees on a few actions, and none of it goes to a founder or gets burned into nothing — every fee flows into the operator reward pool that funds the citizens hosting the network. THE TRANSFER FEE is a fraction of a percent of the amount you send (a current default set by vote), and it is CAPPED so no single transfer — however large — ever costs more than a small fixed ceiling. That makes SOV cheaper than Bitcoin at every size: sending a tiny amount costs a fraction of a cent, and a whale settlement is capped at the ceiling. THE EXCHANGE FEE is a small percentage of a completed trade. THE PLATFORM FEE is paid once a year by a business that wants to accept "Sign in with SOV" — ordinary citizens NEVER pay to log in anywhere. All three fee rates and the transfer cap are governance parameters: citizens can vote them up, down, or to zero. This is the SOV economy in one sentence — the cut a bank would keep is instead a citizen-set, capped contribution that circulates straight back to the people doing the work.'),
    (icon: Icons.lan_outlined,               title: 'Protocol: Operator income — earning by keeping the network alive', visual: 'operator_income',
     body: 'Citizens who run relay nodes earn SOV for the real work of keeping the network running: witnessing transactions and staying online. A node must be CONTINUOUSLY up for a qualifying period (a current default of about three weeks) before it earns — sleeping or shutting the machine down breaks the streak, so payouts reward genuine uptime, not machines that are mostly off. Payment is a fixed reward per relay per month (governance-set), with a deliberately steep anti-monopoly curve: your first relay earns the full reward, a second and third earn a small fraction, and a fourth or beyond earns nothing but recognition — so running a farm of nodes gives you no advantage, keeping the network spread across many independent operators. Crucially, operators are paid FROM THE FEES that flow in first, and only then, capped, from the genesis reserve — so as the network grows and fees rise, it funds its own operators and the reserve becomes a long-term runway rather than a pot that drains. You can watch every fee flow into the pool and every payout leave it on the live SOV Economy screen — the ledger is public.'),
    (icon: Icons.balance_outlined,           title: 'Protocol: Why a second node earns less than your first',
     body: 'Running more machines does not multiply your income, and that is deliberate. Your first '
           'relay earns the full reward. Your second and third each earn a quarter of it. Your fourth '
           'and every one after that earn NOTHING - they still serve the network, still carry traffic, '
           'still hold the ledger, but they are infrastructure credit only. The most any single '
           'operator can earn is one and a half times the base rate, no matter how many machines they '
           'run. This is the anti-centralisation guarantee: there is no reward for filling a data '
           'centre with nodes, so the network cannot be captured by whoever can afford the most '
           'hardware. These multipliers are locked in the protocol itself and are not something '
           'citizens can vote to change.'),
    (icon: Icons.verified_user_outlined, title: 'Protocol: How a new node is let in',
     body: 'Anyone may run a node, but no node lets itself in. When a new node first meets the network it announces itself, and the peers that hear it check three things against their own copy of the ledger: that the operator gave a Sovereign ID at all, that the ID belongs to a genuinely enrolled citizen, and that this citizen is not already running more nodes than the rules allow. A node offering no operator ID is refused outright. That is not bureaucracy — a network that accepts anonymous nodes can be flooded by one person running thousands of them, and every vote and every payout after that is meaningless. The question is not put to the whole network. Asking every node would get slower each time the network grew, and it would also be weaker than it sounds: if any single node\'s approval were enough, one dishonest node could wave in anything it liked. Instead a small random sample of peers is asked, and a majority of that sample must agree. The cost of admitting a node stays the same whether the network has ten nodes or ten thousand, and an attacker has to control most of a group they cannot choose and cannot predict. Checking costs the network nothing. Every node already holds the full enrollment ledger, so "is this a real citizen?" is answered on the spot, from local data, without asking anyone. How many peers are sampled and how many must agree are both citizen-governed values, so the network can tighten or loosen its own front door by vote as it grows.'),
    (icon: Icons.face_retouching_natural_outlined, title: 'Protocol: One human, one identity — the face lock',
     body: 'SOV guarantees one account per living person, and it now enforces that across BOTH hands. Your palm is your key, and for accessibility you may enroll with either hand — but a single person could otherwise try to register their left palm as one identity and their right as another, because two palms of the same person look unrelated to a palm scanner. The face lock closes that gap. During the liveness check the app already looks at your face; from that it computes a private mathematical fingerprint (never a photo, and it cannot be turned back into your face) and the network checks it against everyone already enrolled. If your face already has an identity, a second enrollment is refused — you are told to recover your existing wallet instead. The check happens on the network side, so it cannot be skipped by a modified app. Identical twins are the one natural limit every face system shares. This is what keeps one-human-one-vote and one-human-one-wallet true, no matter which hand you scan.'),
    // ── Run a node — operator onboarding (2026-07-20) ────────────────────────
    //    A start-to-finish path for any citizen, future operator, or network
    //    engineer who wants to host a SOV node. Each card carries a step-by-step
    //    visual (widgets/academy_operator_visuals.dart).
    (icon: Icons.dns_rounded,                title: 'Run a node — where to host it (free or paid)', visual: 'op_providers',
     body: 'Anyone can run a SOV node and earn the operator payout — the hardware bar is deliberately low, so "a person with a small free VPS" qualifies. You have four easy paths. ORACLE CLOUD "Always Free" is the top pick: it is free forever with no 12-month expiry, and the shape VM.Standard.E2.1.Micro (AMD) is eligible. GOOGLE CLOUD offers an always-free e2-micro in us-west1/us-central1/us-east1 — free, but keep a billing alert on. AMAZON AWS free tier (t3.micro / t2.micro) is only free for 12 months, so it is best for learning rather than a permanent node. And your own WINDOWS PC at home can be a full node with zero VPS — just install the app and toggle it on. THE ONE HARD RULE: choose an x86_64 (Intel/AMD) machine, never ARM (Oracle Ampere A1, AWS Graviton) — the node ships an x86_64 runtime and native crypto module and will not start on ARM. Any provider works — paid droplets, a home server, anything with a public IPv4 and openable ports.'),
    (icon: Icons.security_rounded,           title: 'Run a node — opening the firewall (the part that blocks people)', visual: 'op_firewall',
     body: 'The single most common reason a new node "installs fine but nobody can reach it" is the firewall. Cloud providers block inbound ports in TWO separate places, and you must open BOTH. DOOR 1 is the cloud firewall in the provider console — called a Security List on Oracle, a Security Group on AWS, or a VPC firewall rule on Google. DOOR 2 is the machine\'s own firewall (Ubuntu iptables/ufw) — Oracle images in particular ship this closed, which is the classic "the console says the port is open but it still drops". Open these inbound TCP ports from source 0.0.0.0/0: 443 (citizens connect here — the main one), 7771 (peer mesh, node-to-node), 80 (snap download + health), and 22 for SSH (tighten this one to your own IP). Leave port 8080 CLOSED to the internet — it is the private node dashboard and is meant to stay on localhost. Get these ports right and the rest of running a node is easy.'),
    (icon: Icons.cloud_rounded,              title: 'Google Cloud — stand up a free node', visual: 'op_gcp',
     body: 'On Google Cloud, create a VM in Compute Engine: region us-west1, us-central1 or us-east1, machine type e2-micro (always-free-eligible), boot disk Ubuntu 22.04 LTS. Copy the external IP once it is running. Then open the ports under VPC network → Firewall → Create firewall rule: Direction Ingress, Targets All instances, Source ranges 0.0.0.0/0, Protocols and ports TCP 443,7771,80,22. GCP\'s Ubuntu images do not add an extra host firewall, so Door 2 is usually already open — but verify you can reach 443 after installing. Important: GCP free instances have been terminated over billing disputes before, so set a Budget alert (e.g. at \$1) so nothing can silently run up a charge. This is the fallback if you do not want Oracle; otherwise Oracle Always Free is the safer permanent home.'),
    (icon: Icons.shopping_cart_rounded,      title: 'Amazon AWS — stand up a node', visual: 'op_aws',
     body: 'On AWS, launch an EC2 instance: AMI Ubuntu 22.04 LTS (64-bit x86), type t3.micro or t2.micro (free-tier eligible). Create or choose a key pair and download the .pem file — that is your SSH key. Note the Public IPv4 once it launches. Open the ports on the instance\'s Security Group: EC2 → Security Groups → select the group → Inbound rules → Edit → Add rule → Custom TCP, port 443, source Anywhere-IPv4 (0.0.0.0/0); repeat for 7771 and 80. Keep the SSH (22) rule but tighten its source to "My IP". Save. One caveat: the AWS free tier lasts only 12 months and then bills — it is excellent to learn on, but for a node you intend to keep running for years, Oracle Always Free (no expiry) is the better choice.'),
    (icon: Icons.verified_rounded,           title: 'Oracle Cloud — free-forever node (recommended)', visual: 'op_oracle',
     body: 'Oracle Cloud Infrastructure "Always Free" is the recommended host: free forever with no 12-month expiry, and it is the same provider running the network\'s longest-lived node. Create an instance: image Canonical Ubuntu 22.04, then Change shape → AMD → VM.Standard.E2.1.Micro (Always-Free-eligible). DO NOT pick Ampere A1 — that is ARM and the node will not run on it. Assign a public IPv4 and paste your SSH public key. Oracle is the one provider where the two-firewall-layers rule really bites. DOOR 1: Networking → Virtual Cloud Networks → your VCN → Security Lists → Default → Add Ingress Rules for 22, 80, 443, 7771 (source 0.0.0.0/0, TCP). DOOR 2: SSH into the box and open the same ports in iptables (Oracle images block them by default), then run netfilter-persistent save so they survive a reboot. Skipping Door 2 is the number-one Oracle mistake — the console shows the ports open while the box still silently drops them.'),
    (icon: Icons.download_rounded,           title: 'Installing the node software (the snap)', visual: 'op_snap',
     body: 'The node software is distributed by the network itself — there is no GitHub repo and no app store to trust. You download it straight from a running node, and you verify it yourself. STEP 1: download the node software straight from any live node on the network. STEP 2: prove it is authentic by downloading the SAME file from a second, independent node and checking that the two copies are identical — if they match, no one tampered with your copy in transit. STEP 3: install snapd if needed, then sudo snap install --dangerous --devmode sov-relay.snap (the flags mean "not from the Snap Store" and "unconfined sandbox" — both intentional for now). STEP 4: edit /var/snap/sov-relay/current/.env to set RELAY_ID (a name you choose) and RELAY_IP (your public IP), leaving RELAY_POOL_IPS as the live nodes so you discover the mesh on first boot. STEP 5: follow the boot log with snap logs -f and watch it load its identity, bind the ports, and connect to peers. Once it converges and stays continuously up for the qualifying period (about three weeks), your node begins earning the operator payout.'),
    (icon: Icons.devices_rounded, title: 'Run a node on macOS or Linux',
     body: 'The SOV desktop wallet is the same application on Windows, macOS and Linux, and on all three it is also a full node — the node is not a separate download. What differs between them is only how you get Tailscale, and Tailscale is needed ONLY if your connection cannot accept incoming traffic. START HERE, on any of the three: install the wallet, sign in, open the Node tab, leave Reachability on Auto and switch Run a Node ON. On ordinary home broadband the app opens your router itself, or relays through the mesh if your network is awkward, and you configure nothing at all. When it shows "Reachable at: …" you are serving, and uptime is what earns. Most people never need anything below this paragraph. IF AUTO CANNOT GET THROUGH — mobile hotspot, CGNAT, student or office Wi-Fi, any network where you cannot forward a port — you use Tailscale Funnel, which gives your node a stable public address over an outbound-only connection, for free. You install Tailscale yourself and sign in to YOUR OWN Tailscale account. The SOV network never provisions it for you and never sees your tailnet. ON WINDOWS the wallet can install Tailscale for you: press Enable Tailscale Funnel and accept the normal Windows prompt, then sign in through your browser once. ON macOS you install it yourself first — from tailscale.com/download, or with "brew install --cask tailscale" if you use Homebrew. Open Tailscale once and sign in. The wallet then finds it automatically, including the App Store version, whose command-line tool lives inside the application bundle rather than on your PATH. ON LINUX install it with your package manager — "sudo apt install tailscale" on Debian or Ubuntu, "sudo dnf install tailscale" on Fedora, "sudo pacman -S tailscale" on Arch — then "sudo tailscale up" and sign in. Linux needs ONE extra command that Windows and macOS do not: "sudo tailscale set --operator=\$USER". Without it the wallet cannot talk to the Tailscale service, because that service is owned by root. Run it once and you are done; the wallet will tell you if you forgot. Then on any OS: set Reachability to Tailscale Funnel, switch Run a Node ON, and the first time only, approve the Funnel link in your browser. Citizens reach you on the standard secure port with no port-forwarding anywhere. A note on Linux desktops: the wallet needs a few system libraries that some minimal installations leave out, and a keyring to store your keys in. The download page lists the exact packages. If the wallet will not start on a server or inside a container, that is expected — it is a desktop application, and a machine with no screen should run the node software directly instead.'),
    (icon: Icons.desktop_windows_rounded,    title: 'Run a node on Windows — no VPS, no Linux', visual: 'op_windows',
     body: 'You do not need a VPS, Linux, or any firewall edits to be an operator — the SOV Windows app is itself a full node. PATH A (normal home broadband): install the app, sign in, open the Node tab, leave Reachability on Auto, and toggle Run a Node → ON. Behind the scenes it opens your router with UPnP, or falls back to relaying through the SOV mesh if your network is difficult — you configure nothing. When it is serving it shows "Reachable at: …". For most people that is the entire setup; just keep the PC on, because uptime is what earns. PATH B (mobile hotspot, CGNAT, student/office Wi-Fi, "can\'t port-forward"): make a free Tailscale account and install Tailscale for Windows (one browser login — Tailscale uses SSO, there is no in-app password by design), then in the SOV app set Reachability = Tailscale Funnel and toggle ON. The first time only, tap "Enable Tailscale Funnel" and click Approve in the browser. Tailscale Funnel then gives your node a stable public HTTPS address for free, over an outbound-only connection, and citizens reach you on 443 with no port-forwarding at all.'),
    // ── Marketplace + one-truth mesh (added 2026-07-22 as these shipped) ──────
    (icon: Icons.storefront_outlined,        title: 'Protocol: The Exchange — turning your SOV into real value', visual: 'transfer_fee',
     body: 'SOV gets its exchange value the honest way: person to person, with no company setting the price. On the Exchange a citizen who wants cash LISTS some of their SOV for sale and states how they take payment (bank transfer, mobile money, whatever they choose). The moment they list, that SOV is locked in escrow on the network — it cannot be spent or double-sold. A buyer browses the open listings, opens a private negotiation chat with the seller RIGHT ON THE LISTING — you do not have to commit first, you can ask "what price per SOV?" before anything — and the two agree a number. Offers ride inside the chat as tappable cards: the seller sends an offer, the buyer taps Accept, and a "Fill at agreed terms" button appears. The buyer pays the agreed money OFF the platform (SOV never touches a bank), and when the seller confirms the money arrived, the network releases the escrowed SOV to the buyer, minus a small citizen-voted exchange fee that goes to the operator pool. Every listing, trade and fee is public on the SOV Economy screen. Because citizens set their own prices with no middleman, free price discovery is exactly how SOV earns a real, market-set value.'),
    (icon: Icons.hub_rounded,                title: 'Protocol: One truth on every node — how the mesh heals itself', visual: 'no_center',
     body: 'SOV has no central server, yet every node — whether it is a data-centre relay or a laptop at home — must show you the SAME balances, the same messages, the same votes, the same everything. It stays that way through a quiet background process called anti-entropy. Every node keeps a tiny fingerprint of its own copy of the shared state and gossips that fingerprint to its neighbours a few times a minute. If two neighbours\' fingerprints differ, the one that is behind simply asks the other for the missing pieces and folds them in — balances by "newest wins", and records like guardians, trades, group messages and platform registrations by "keep everything, never lose a fact". So if your node was switched off for a week, or a home node was unreachable during a storm, the instant it comes back it catches up automatically — no operator action, no re-sync button, no central authority to ask. It also watches its own links: if a connection to a peer goes silently dead, the node notices the silence, drops the dead link and reconnects — which is why the network keeps converging even as nodes come and go. This is what lets SOV be a million independent nodes that all see, hear and speak one truth: not because a company keeps them in line, but because the protocol reconciles itself, forever, with nobody watching.'),
    // ── DEVELOPER TRACK: the SOV CLI, in five parts (expanded 2026-07-30) ────
    // Was a single article; expanded into a curriculum because the CLI is the whole
    // automation surface and one article could not carry it. Command syntax below is
    // taken from lib/sov_cli/cli_runner.dart — keep them in sync when commands change.
    (icon: Icons.terminal_rounded,           title: 'CLI 1 of 5 — why SOV ships no SDK, and does not need one',
     body: 'Most networks hand developers a library, then ask you to trust it. SOV does something simpler: the desktop app IS the developer tool. SovNode.exe runs headless — the same binary a citizen double-clicks will, given "--cli", act as a scriptable wallet that speaks JSON. There is nothing extra to install, no API key to request, no package to audit, and no company in the middle. Run "SovNode.exe --cli --help" and you have the entire surface. Why this matters: an SDK is a dependency, and a dependency is a party who can change the rules, break your build, or be pressured. The CLI is just your own wallet, operated by a script instead of a finger. It signs with the key already sealed in your operating system\'s credential store, talks to the same relays your app talks to, and obeys exactly the same protocol rules. Nothing about automation makes you a second-class citizen on the network — a script and a human are indistinguishable to the protocol, because both are the same signed identity.'),
    (icon: Icons.list_alt_rounded,           title: 'CLI 2 of 5 — the complete command surface',
     body: 'Everything begins with "SovNode.exe --cli". MONEY: "balance" shows what you hold; "send --to <sovereign-id> --amount 10 [--memo \\"text\\"]" transfers; "history [--limit 50]" lists past transactions; "contacts" lists saved citizens. MESSAGES: "msg --to <id> \\"hello\\"" sends; "msg --list [--with <id>] [--limit 20]" reads. NODE: "node status|on|off" starts or stops the bundled full node on this machine. EXCHANGE: "exchange orders" browses the book; "exchange mine" shows yours; "exchange create --amount 100 --memo \\"...\\" [--price 950 --currency NGN]" lists SOV for sale; "exchange chat --order <id>" and "exchange chat-send --order <id> --to <sid> \\"...\\"" negotiate directly on the listing; "exchange fill --order <id>", "exchange confirm --order <id>", "exchange cancel --order <id>" complete or withdraw. SECURITY: "spendlock status|enable|disable --pin <code>", "hwlock status|enable|disable [--hello]", "automation status|set|allow|deny|off|cancel". GLOBAL FLAGS: "--json" makes any command emit machine-readable output — this is what turns the CLI into an API; "--pin <code>" supplies the PIN so a script never stalls waiting for input; "--node <wss://...>" pins a specific relay. Every command returns a meaningful exit code, so shell scripts can branch on success or failure without parsing text.'),
    (icon: Icons.shield_moon_outlined,       title: 'CLI 3 of 5 — the four security tiers (read this before automating money)',
     body: 'Automation that can spend money deserves more care than automation that reads it, and SOV gives you four escalating tiers. TIER 0 — PIN GATE: the PIN stops a casual passer-by, nothing more. Anyone who can run the executable as you can move your SOV. Never run the CLI on a shared, hosted, or borrowed machine. TIER 1 — SPEND-LOCK ("spendlock enable --pin <code>"): the private key is no longer stored in the clear at all; only a PIN-encrypted blob is kept, hardened with Argon2id, which is memory-hard and therefore brutally slow to brute-force even though a PIN is short. The decrypted key lives in memory for a bounded session only — the same idea as Bitcoin Core\'s walletpassphrase timeout, so automation unlocks once instead of re-prompting per transfer. TIER 2 — HARDWARE-LOCK ("hwlock enable [--hello]"): the seed is sealed by your machine\'s security chip — TPM on Windows, Secure Enclave on Mac — with a key that cannot be exported. Copying the file to another computer gains an attacker nothing, because only that physical chip can unseal it. Add "--hello" and every unseal additionally demands your fingerprint or face. TIER 3 — NETWORK-ENFORCED CAPS ("automation set --per-tx 5 --daily 20 --allow id1,id2"): the previous tiers protect the key; this one protects you from your own script. Limits are enforced by the NETWORK, not by your code, so a runaway loop or a compromised script still cannot exceed them. IMPORTANT: your seed phrase always restores the wallet, so a dead TPM or a forgotten PIN is never lost funds — hardware sealing is at-rest hardening, never the root of custody.'),
    (icon: Icons.smart_toy_outlined,         title: 'CLI 4 of 5 — building an agent that runs your wallet',
     body: 'Because every command speaks JSON, a working agent is remarkably short. The loop is: poll "msg --list --json" for new messages, decide what to do, then act with "msg --to" or "send --to". That is genuinely the whole architecture — a reference implementation lives in the project at tools/cli_automation/, where a single decision function sits between reading and acting. Swap that one function for a call to an AI model and your wallet answers its own messages in your voice; leave it as simple rules and it is a predictable bot. Useful shapes: an auto-responder that replies while you sleep; a payment watcher that notices incoming SOV and confirms delivery; an OTC desk that quotes prices in the exchange chat and fills orders at terms you set; a monitor that reports your balance to your own dashboard. THE RULES THAT KEEP THIS SAFE: put a hard spend cap in the code AND in the network ("automation set"), so a bug cannot drain you. Keep an allow-list of recipients — never let the agent pay an address it learned from a message it just received, which is exactly how a prompt-injection attack would try to rob you. Never commit your PIN to source or paste it in a screenshot. Remember it polls rather than streams, so build for eventual consistency, not instant reaction. And understand that you are responsible for everything your automation signs, because to the network it is you.'),
    (icon: Icons.lock_person_outlined,       title: 'CLI 5 of 5 — what the CLI deliberately cannot do',
     body: 'A tool is defined as much by its refusals as its features. THE CLI CANNOT ENROLL YOU. There is no headless account creation, and this is deliberate rather than unfinished: enrollment requires a live palm-and-face scan proving a real, unique human is present. If a script could enroll, one person could mint thousands of identities and one-human-one-wallet — the single idea SOV is built on — would collapse overnight. So the CLI only ever operates an identity that already exists, created by a human with a camera. THE CLI CANNOT READ OTHER PEOPLE\'S MESSAGES. Message bodies stay end-to-end encrypted; the CLI decrypts only your side, using your key. THE CLI CANNOT FORGE A RELEASE, appoint itself an operator, or vote twice — every action carries your signature and is checked by the network exactly as the app\'s actions are. WHAT THIS MEANS FOR YOU: the CLI is a key-holder\'s tool, not a skeleton key. It makes an existing citizen faster; it cannot manufacture citizens. That boundary is why automation can be handed this much power safely — the scarce thing on SOV was never compute or code, it is verified personhood, and no amount of scripting creates more of it.'),
    // Legacy single-article version, retained below for continuity.
    (icon: Icons.terminal_rounded,           title: 'For developers: automate your wallet with the CLI (no SDK needed)',
     body: 'SOV ships no developer SDK — and does not need one. The desktop app, SovNode.exe, doubles as a headless command-line wallet that runs on your ALREADY-SIGNED wallet and speaks JSON, so any program (or an AI assistant) can do everything you do by hand. Run "SovNode.exe --cli --help" to see it: check balance ("--cli balance --json"), send SOV ("--cli send --to <sovereign-id> --amount 10"), read and send messages ("--cli msg --list --json" / "--cli msg --to <id> \'hello\'"), pull history, and even drive the P2P Exchange ("--cli exchange orders|create|fill|confirm"). Every command takes "--json" for scripting and "--pin <code>" so it never has to stop and ask. That is a complete automation surface: a short script can WATCH your inbox for new messages, AUTO-REPLY (or hand each message to an AI that answers on your behalf), forward, report your balance, or auto-pay a trusted contact within limits you set. THE LIMITS ARE THE SECURITY MODEL, not a footnote. (1) Private PC only — the CLI signs as YOU using the key sealed in your operating system\'s credential store, so anyone who can run the exe on your machine can move your SOV; never on a shared or hosted box. (2) A signed or restored wallet is required — there is deliberately no headless enrollment, because enrollment needs a live palm-and-face scan (proof of personhood) that cannot be scripted; the CLI only operates an identity that already exists. (3) Keep your PIN out of source and out of screenshots. (4) It polls rather than streams, and message bodies stay end-to-end encrypted — the CLI decrypts only for your side. (5) You are responsible for anything your automation sends, which is why auto-transfer should always sit behind an allow-list and a hard spend cap. Used this way, a citizen can point a personal AI at their own wallet — replying to SOV Speak messages, watching for payments, running an OTC exchange desk — entirely from their own machine, with no company, server, or API key in the middle. A ready-to-run reference agent lives in the project at tools/cli_automation/.'),
  ];

  static const _categories = ['all', 'general', 'economy', 'governance', 'technology', 'justice', 'tutorial'];

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _loadStatus();
    _loadMyUpvotes();
    _loadArticles();
  }

  Future<void> _loadStatus() async {
    if (widget.sovereignId.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      if (!RelayConnector.isConnected) await RelayConnector.connect();
      final resp = await RelayConnector.pioneerGetStatus(widget.sovereignId);
      if (resp['success'] == true && mounted) {
        final m = (resp['certifications'] as Map?)?.cast<String, dynamic>() ?? {};
        setState(() {
          _certs = {
            'relay_engineer':      m['relay_engineer']      == true,
            'enrollment_agent':    m['enrollment_agent']    == true,
            'protocol_specialist': m['protocol_specialist'] == true,
          };
          _loading = false;
        });
      } else {
        if (mounted) setState(() => _loading = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMyUpvotes() async {
    final prefs = await SharedPreferences.getInstance();
    final list  = prefs.getStringList('academy_upvotes_${widget.sovereignId}') ?? [];
    if (mounted) setState(() => _myUpvotes = list.toSet());
  }

  Future<void> _saveMyUpvotes() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('academy_upvotes_${widget.sovereignId}', _myUpvotes.toList());
  }

  Future<void> _loadArticles({bool silent = false}) async {
    if (!mounted) return;
    if (!silent) setState(() { _articlesLoading = true; _articlesError = ''; });
    try {
      if (!RelayConnector.isConnected) await RelayConnector.connect();
      final list = await RelayConnector.listArticles(
        category: _filterCategory == 'all' ? null : _filterCategory,
        limit: 50,
      );
      if (mounted) {
        setState(() { _articles = list; _articlesLoading = false; });
        // Prefetch palm names for all unique article authors.
        final authorIds = list
            .map((a) => a['author_id'] as String? ?? '')
            .where((id) => id.isNotEmpty)
            .toSet();
        for (final authorId in authorIds) {
          RelayConnector.prefetchPalmName(authorId, onResolved: () {
            if (mounted) { setState(() {
              _authorNames[authorId] =
                  RelayConnector.cachedPalmNameFor(authorId);
            }); }
          });
        }
      }
    } catch (e) {
      if (mounted) { setState(() { _articlesError = e.toString(); _articlesLoading = false; }); }
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _navy,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async { await _loadStatus(); await _loadArticles(silent: true); },
          color: _gold,
          backgroundColor: _cardBg,
          child: NotificationListener<UserScrollNotification>(
            // Slide the Write Article button out of the way while reading /
            // scrolling down so it never covers the tour screenshots; it glides
            // back the moment the reader scrolls up.
            onNotification: (n) {
              if (n.direction == ScrollDirection.reverse && _fabVisible) {
                setState(() => _fabVisible = false);
              } else if (n.direction == ScrollDirection.forward && !_fabVisible) {
                setState(() => _fabVisible = true);
              }
              return false;
            },
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(child: _buildHeader()),
                if (_loading)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.all(40),
                      child: Center(child: CircularProgressIndicator(color: Color(0xFFD4AF37))),
                    ),
                  )
                else ...[
                  SliverToBoxAdapter(child: _buildCourseCards()),
                  SliverToBoxAdapter(child: _buildVisualTourSection()),
                  SliverToBoxAdapter(child: _buildCommunityArticles()),
                  SliverToBoxAdapter(child: _buildKnowledgeBankSection()),
                ],
                const SliverToBoxAdapter(child: SizedBox(height: 80)),
              ],
            ),
          ),
        ),
      ),
      floatingActionButton: widget.sovereignId.isNotEmpty
          ? AnimatedSlide(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              offset: _fabVisible ? Offset.zero : const Offset(0, 2),
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 180),
                opacity: _fabVisible ? 1 : 0,
                child: FloatingActionButton.extended(
                  heroTag: null,
                  onPressed: _openPublishSheet,
                  backgroundColor: _gold,
                  foregroundColor: Colors.black,
                  icon: const Icon(Icons.edit_rounded, size: 20),
                  label: const Text('Write Article', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            )
          : null,
    );
  }

  // ── HEADER ─────────────────────────────────────────────────────────────────

  Widget _buildHeader() {
    final anyEarned = _certs.values.any((v) => v);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('SOV Academy',
              style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text('Learn. Certify. Build the future.',
              style: TextStyle(color: Color(0xFFD4AF37), fontSize: 14, letterSpacing: 0.3)),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFFD4AF37).withAlpha(10),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFD4AF37).withAlpha(45)),
            ),
            child: const Text(
              'The SOV Network is not just an app — it is a new way of life. '
              'A parallel economy built by citizens, for citizens. '
              'The citizens who understand it first will lead it forever.',
              style: TextStyle(color: Colors.white60, fontSize: 12, height: 1.6),
            ),
          ),
          if (anyEarned) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: _gold.withAlpha(14),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _gold.withAlpha(55)),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.workspace_premium_rounded, color: Color(0xFFD4AF37), size: 16),
                  SizedBox(width: 8),
                  Text(
                    'Certified Service Provider — qualified to offer services',
                    style: TextStyle(color: Color(0xFFD4AF37), fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                'Offer your services on the SOV Exchange — list an offer with "[SERVICE]" in the '
                'memo. Your certification badges + reputation build client trust, and clients pay '
                'safely through Exchange escrow. The network does not pay you — you charge clients '
                'directly for your qualified service.',
                style: TextStyle(color: Colors.white54, fontSize: 11, height: 1.5),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── COURSE CARDS ───────────────────────────────────────────────────────────

  Widget _buildCourseCards() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(children: _courses.map(_buildCourseCard).toList()),
    );
  }

  Widget _buildCourseCard(dynamic c) {
    final certified = _certs[c.spec] == true;
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => PioneerScreen(sovereignId: widget.sovereignId)),
      ).then((_) => _loadStatus()),
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: _cardBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: certified ? _gold.withAlpha(80) : Colors.white.withAlpha(12),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 48, height: 48,
              decoration: BoxDecoration(
                color: certified ? _gold.withAlpha(25) : Colors.white.withAlpha(8),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: certified ? _gold.withAlpha(80) : Colors.white.withAlpha(15),
                ),
              ),
              child: Icon(certified ? c.selIcon : c.icon,
                  color: certified ? _gold : Colors.white54, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Text(c.label,
                        style: TextStyle(
                            color: certified ? _gold : Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 14)),
                    const SizedBox(width: 8),
                    if (certified)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                            color: _gold.withAlpha(25),
                            borderRadius: BorderRadius.circular(6)),
                        child: Text('[${c.shortLabel}]',
                            style: const TextStyle(
                                color: Color(0xFFD4AF37),
                                fontSize: 10,
                                fontWeight: FontWeight.bold)),
                      ),
                  ]),
                  const SizedBox(height: 6),
                  Text(c.desc,
                      style: const TextStyle(color: Colors.white54, fontSize: 12, height: 1.5)),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: certified ? _gold.withAlpha(18) : Colors.white.withAlpha(8),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      certified ? '✓ Certified' : 'Start course →',
                      style: TextStyle(
                          color: certified ? _gold : Colors.white54,
                          fontSize: 12,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── COMMUNITY ARTICLES (relay-native) ──────────────────────────────────────

  Widget _buildCommunityArticles() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Community Articles',
                      style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                  SizedBox(height: 2),
                  Text('Written by citizens, published on the relay',
                      style: TextStyle(color: Colors.white38, fontSize: 12)),
                ],
              ),
            ),
            IconButton(
              icon: _articlesLoading
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFD4AF37)))
                  : const Icon(Icons.refresh_rounded, color: Colors.white38, size: 20),
              onPressed: _articlesLoading ? null : () => _loadArticles(),
            ),
          ]),
          const SizedBox(height: 10),

          // Category filter chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: _categories.map((cat) {
                final selected = _filterCategory == cat;
                return GestureDetector(
                  onTap: () {
                    setState(() => _filterCategory = cat);
                    _loadArticles();
                  },
                  child: Container(
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(
                      color: selected ? _gold.withAlpha(25) : Colors.white.withAlpha(8),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: selected ? _gold.withAlpha(80) : Colors.white.withAlpha(15),
                      ),
                    ),
                    child: Text(
                      cat == 'all' ? 'All' : cat[0].toUpperCase() + cat.substring(1),
                      style: TextStyle(
                        color: selected ? _gold : Colors.white38,
                        fontSize: 11,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 12),

          if (_articlesError.isNotEmpty && _articles.isEmpty) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _cardBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withAlpha(10)),
              ),
              child: Row(children: [
                const Icon(Icons.cloud_off_rounded, color: Colors.white24, size: 20),
                const SizedBox(width: 10),
                const Expanded(child: Text('Could not reach relay', style: TextStyle(color: Colors.white38, fontSize: 12))),
                TextButton(onPressed: _loadArticles, child: const Text('Retry', style: TextStyle(color: Color(0xFFD4AF37), fontSize: 12))),
              ]),
            ),
          ] else if (_articles.isEmpty && !_articlesLoading) ...[
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: _cardBg,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white.withAlpha(10)),
              ),
              child: Column(
                children: [
                  const Icon(Icons.article_outlined, color: Colors.white24, size: 36),
                  const SizedBox(height: 10),
                  const Text('No articles yet', style: TextStyle(color: Colors.white54, fontSize: 14)),
                  const SizedBox(height: 4),
                  Text(
                    'Be the first citizen to publish in${_filterCategory == 'all' ? '' : ' the $_filterCategory'} category.',
                    style: const TextStyle(color: Colors.white24, fontSize: 11),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  TextButton.icon(
                    onPressed: _openPublishSheet,
                    icon: const Icon(Icons.edit_rounded, size: 16, color: Color(0xFFD4AF37)),
                    label: const Text('Write an article', style: TextStyle(color: Color(0xFFD4AF37), fontSize: 12)),
                  ),
                ],
              ),
            ),
          ] else ...[
            ..._articles.map((a) => _buildRelayArticleCard(a)),
          ],
        ],
      ),
    );
  }

  Widget _buildRelayArticleCard(Map<String, dynamic> article) {
    final articleId   = article['article_id'] as String? ?? '';
    final title       = article['title']       as String? ?? '';
    final authorId    = article['author_id']   as String? ?? '';
    final category    = article['category']    as String? ?? 'general';
    final upvotes     = (article['upvote_count'] as num?)?.toInt() ?? 0;
    final createdAt   = (article['created_at'] as num?)?.toInt() ?? 0;
    final alreadyUpvoted = _myUpvotes.contains(articleId);

    // Use palm name if available, otherwise short ID.
    final authorName = (_authorNames[authorId]?.isNotEmpty == true)
        ? _authorNames[authorId]!
        : RelayConnector.cachedPalmNameFor(authorId).isNotEmpty
            ? RelayConnector.cachedPalmNameFor(authorId)
            : (authorId.length > 14
                ? '${authorId.substring(0, 10)}…${authorId.substring(authorId.length - 4)}'
                : authorId);

    final dt = DateTime.fromMillisecondsSinceEpoch(createdAt);
    final dateStr = '${dt.day} ${_monthName(dt.month)} ${dt.year}';

    return GestureDetector(
      onTap: () => _openArticle(article),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _cardBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withAlpha(10)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text(title,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                    maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => _upvoteArticle(articleId),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: alreadyUpvoted ? _gold.withAlpha(25) : Colors.white.withAlpha(8),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: alreadyUpvoted ? _gold.withAlpha(80) : Colors.white.withAlpha(15),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.thumb_up_rounded,
                          size: 12,
                          color: alreadyUpvoted ? _gold : Colors.white38),
                      const SizedBox(width: 4),
                      Text('$upvotes',
                          style: TextStyle(
                              color: alreadyUpvoted ? _gold : Colors.white38,
                              fontSize: 11,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A3A5C),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(category[0].toUpperCase() + category.substring(1),
                    style: const TextStyle(color: Color(0xFF64B5F6), fontSize: 10, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 8),
              Text(authorName, style: const TextStyle(color: Colors.white38, fontSize: 10)),
              const Spacer(),
              Text(dateStr, style: const TextStyle(color: Colors.white24, fontSize: 10)),
            ]),
          ],
        ),
      ),
    );
  }

  Future<void> _openArticle(Map<String, dynamic> summary) async {
    // Show loading indicator then fetch full body
    Map<String, dynamic>? full;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator(color: Color(0xFFD4AF37))),
    );
    try {
      full = await RelayConnector.getArticle(summary['article_id'] as String);
    } catch (_) {}
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    if (!mounted) return;

    final article = full ?? summary;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0D1F3A),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _ArticleViewSheet(
        article: article,
        isUpvoted: _myUpvotes.contains(article['article_id'] as String? ?? ''),
        onUpvote: () => _upvoteArticle(article['article_id'] as String? ?? ''),
        sovereignId: widget.sovereignId,
      ),
    );
  }

  Future<void> _upvoteArticle(String articleId) async {
    if (articleId.isEmpty || _myUpvotes.contains(articleId)) return;
    if (widget.sovereignId.isEmpty) return;
    setState(() => _myUpvotes.add(articleId));
    await _saveMyUpvotes();
    try {
      final res = await RelayConnector.upvoteArticle(
        articleId: articleId,
        voterId:   widget.sovereignId,
      );
      if (res?['success'] == true) {
        // Update count in local list
        setState(() {
          final idx = _articles.indexWhere((a) => a['article_id'] == articleId);
          if (idx >= 0) {
            _articles[idx] = Map.from(_articles[idx])
              ..['upvote_count'] = (res!['upvote_count'] as num?)?.toInt() ?? ((_articles[idx]['upvote_count'] as num?)?.toInt() ?? 0) + 1;
          }
        });
      } else {
        // Relay rejected — roll back upvote record
        setState(() => _myUpvotes.remove(articleId));
        await _saveMyUpvotes();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(res?['error'] ?? 'Could not upvote'),
            backgroundColor: const Color(0xFF0D1F3A),
            behavior: SnackBarBehavior.floating,
          ));
        }
      }
    } catch (e) {
      setState(() => _myUpvotes.remove(articleId));
      await _saveMyUpvotes();
    }
  }

  // ── PUBLISH SHEET ──────────────────────────────────────────────────────────

  void _openPublishSheet() {
    if (widget.sovereignId.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0D1F3A),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _PublishArticleSheet(
        sovereignId: widget.sovereignId,
        categories: _categories.where((c) => c != 'all').toList(),
        onPublished: () => _loadArticles(),
      ),
    );
  }

  // ── VISUAL TOUR (real app screenshots + numbered indicators) ───────────────
  // Real, compressed screenshots of the live app with numbered dots + a legend
  // pointing at exactly what a new citizen taps. Same UI on phone and desktop —
  // the ONLY difference is the desktop (Windows/Mac) app can also run a Full Node.

  Widget _tourStage(String n, String title, String blurb) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: _gold.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(n, style: const TextStyle(color: _gold, fontWeight: FontWeight.bold, fontSize: 12)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text(blurb, style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 12.5, height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVisualTourSection() {
    const encAspect = 0.447; // enrollment shots (tall phone)
    const scr = 0.79;        // main app screens
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.tour_rounded, color: _gold, size: 22),
            const SizedBox(width: 8),
            const Text('A visual tour of the app',
                style: TextStyle(color: _gold, fontSize: 20, fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 4),
          Text(
            'Real screens from the SOV app. The numbered dots show exactly what to tap. '
            'The phone app and the desktop app look the same — only the desktop can also run a Full Node.',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 13, height: 1.4),
          ),

          _tourStage('1', 'Join in a few taps', 'Your palm is your key — no password, no username. One human, one wallet.'),
          const AcademyShot(
            asset: 'assets/academy_shots/apk_enroll_1_palmkey.jpg', aspect: encAspect,
            title: 'Your palm is your key', platformNote: 'Phone (APK)',
            subtitle: 'The onboarding explains it: your palm’s crease pattern is your unbreakable identity.'),
          const AcademyShot(
            asset: 'assets/academy_shots/apk_enroll_3_ownit.jpg', aspect: encAspect,
            title: 'Begin enrollment', platformNote: 'Phone (APK)',
            markers: [ShotMarker(0.5, 0.94, 'Tap "Begin Enrollment" to create your wallet')]),
          const AcademyShot(
            asset: 'assets/academy_shots/apk_enroll_4_camera.jpg', aspect: encAspect,
            title: 'Allow the camera', platformNote: 'Phone (APK)',
            markers: [ShotMarker(0.5, 0.79, 'Tap "While using the app" — needed for the liveness + palm scan')]),
          const AcademyShot(
            asset: 'assets/academy_shots/apk_enroll_5_liveness.jpg', aspect: encAspect,
            title: 'Prove you’re a live person', platformNote: 'Phone (APK)',
            markers: [ShotMarker(0.5, 0.16, 'Follow the on-screen challenge — turn your head the way the arrow points, so no photo or video can fake it')]),
          const AcademyShot(
            asset: 'assets/academy_shots/apk_enroll_8_palm_ok.jpg', aspect: encAspect,
            title: 'Scan your palm', platformNote: 'Phone (APK)',
            markers: [ShotMarker(0.5, 0.42, 'Hold your open palm inside the frame until it locks (green corners)')]),
          const AcademyShot(
            asset: 'assets/academy_shots/apk_enroll_7_dedup.jpg', aspect: encAspect,
            title: 'One human = one wallet', platformNote: 'Phone (APK)',
            markers: [ShotMarker(0.5, 0.62, 'If your palm is already enrolled, tap "Recover My Wallet" instead of making a second account')]),

          _tourStage('2', 'Lost your phone? Take your wallet back', 'Nothing from the old device is needed — your wallet is rebuilt from something only you hold.'),
          const AcademyShot(
            asset: 'assets/academy_shots/apk_restore_1_start.jpg', aspect: encAspect,
            title: 'Start on a new device', platformNote: 'Phone (APK)',
            markers: [ShotMarker(0.49, 0.79, 'On a fresh install tap "Recover My Wallet" — not "Join the Network", which would try to create a second account')]),
          const AcademyShot(
            asset: 'assets/academy_shots/apk_restore_2_method.jpg', aspect: encAspect,
            title: 'Prove the wallet is yours', platformNote: 'Phone (APK)',
            markers: [
              ShotMarker(0.53, 0.32, 'Seed phrase — your 12 words, or the .sov backup file you saved when you enrolled'),
              ShotMarker(0.40, 0.50, 'Guardians — last resort, for when the words and the file are both gone'),
            ]),
          const AcademyShot(
            asset: 'assets/academy_shots/apk_restore_3_options.jpg', aspect: encAspect,
            title: 'Words, or the file', platformNote: 'Phone (APK)',
            markers: [
              ShotMarker(0.45, 0.23, 'Type the 12 words yourself'),
              ShotMarker(0.50, 0.61, 'Or open the backup file. On some phones the file picker briefly closes the app — that is the system, not a crash'),
            ]),
          const AcademyShot(
            asset: 'assets/academy_shots/apk_restore_4_words.jpg', aspect: encAspect,
            title: 'Your 12 words', platformNote: 'Phone (APK)',
            markers: [
              ShotMarker(0.76, 0.16, '"Paste all words" fills every box at once if you copied them together'),
              ShotMarker(0.50, 0.70, 'Tap "Restore Wallet" — the words never leave the device, they rebuild the key here'),
            ]),
          const AcademyShot(
            asset: 'assets/academy_shots/apk_restore_5_password.jpg', aspect: encAspect,
            title: 'If you used the backup file', platformNote: 'Phone (APK)',
            markers: [
              ShotMarker(0.31, 0.52, 'Enter the password you set when you saved the file — the file is encrypted, so a stolen copy is useless without it'),
              ShotMarker(0.50, 0.64, 'Tap "Restore Wallet"'),
            ]),
          const AcademyShot(
            asset: 'assets/academy_shots/apk_restore_6_verifying.jpg', aspect: encAspect,
            title: 'Back in', platformNote: 'Phone (APK)',
            markers: [ShotMarker(0.44, 0.79, 'Your key is checked against the network and your balance, messages and history come back — nothing was ever held for you by a company')]),
          const AcademyShot(
            asset: 'assets/academy_shots/apk_restore_7_guardian.jpg', aspect: encAspect,
            title: 'Last resort: your guardians', platformNote: 'Phone (APK)',
            markers: [
              ShotMarker(0.50, 0.46, 'A recovery code appears (blurred here) — send it to your guardians; it is useless to anyone who is not one'),
              ShotMarker(0.50, 0.69, 'Two of your three must approve from their own wallets. No single person can do it for you'),
            ]),

          _tourStage('3', 'Your money', 'Send, receive and hold SOV. Your balance lives on your device.'),
          const AcademyShot(
            asset: 'assets/academy_shots/home.jpg', aspect: 0.561,
            title: 'Home', platformNote: 'Phone + Desktop',
            markers: [
              // Markers sit at the button EDGES so they never cover the labels.
              ShotMarker(0.10, 0.42, 'Send SOV to anyone by their Sovereign ID'),
              ShotMarker(0.90, 0.42, 'Receive — show a QR to get paid'),
              ShotMarker(0.90, 0.52, 'Exchange SOV for cash or services'),
            ]),
          const AcademyShot(
            asset: 'assets/academy_shots/send.jpg', aspect: 0.561,
            title: 'Send SOV', platformNote: 'Phone + Desktop',
            markers: [
              ShotMarker(0.85, 0.44, 'Paste the recipient’s Sovereign ID'),
              ShotMarker(0.85, 0.58, 'Enter the amount'),
              ShotMarker(0.5, 0.90, 'Tap "Send SOV" — it arrives in seconds'),
            ]),
          const AcademyShot(
            asset: 'assets/academy_shots/receive_qr.jpg', aspect: 0.561,
            title: 'Receive SOV', platformNote: 'Phone + Desktop',
            markers: [
              ShotMarker(0.5, 0.33, 'Your pay-to QR code — let anyone scan it to pay you'),
              ShotMarker(0.5, 0.66, 'Copy your ID, share it, or request a specific amount'),
            ]),

          _tourStage('4', 'The marketplace', 'Trade SOV peer-to-peer, or offer a service you’re certified for.'),
          const AcademyShot(
            asset: 'assets/academy_shots/exchange_browse.jpg', aspect: 0.561,
            title: 'Exchange — browse offers', platformNote: 'Phone + Desktop',
            markers: [ShotMarker(0.16, 0.075, 'Browse citizens’ offers and fill one — funds are escrowed until you confirm')]),
          const AcademyShot(
            asset: 'assets/academy_shots/exchange_myorders.jpg', aspect: 0.561,
            title: 'Exchange — sell or offer a service', platformNote: 'Phone + Desktop',
            markers: [
              ShotMarker(0.5, 0.15, 'List SOV for sale at your price'),
              ShotMarker(0.5, 0.24, 'Or list a paid service your certification qualifies you for'),
            ]),
          const AcademyShot(
            asset: 'assets/academy_shots/exchange_orderbook.jpg', aspect: 0.561,
            title: 'Exchange — order book', platformNote: 'Phone + Desktop',
            markers: [ShotMarker(0.84, 0.075, 'The live order book — open depth and recent fills, in the open')]),

          _tourStage('5', 'Messages — private chat + the public Enclave', 'Four tabs: encrypted 1-to-1 chat, your contacts, the public forum, and group chats.'),
          const AcademyShot(
            asset: 'assets/academy_shots/messages.jpg', aspect: 0.563,
            title: 'SOV Speak — encrypted messages', platformNote: 'Phone + Desktop',
            markers: [
              ShotMarker(0.20, 0.075, 'SOV Speak — private end-to-end encrypted chats'),
              ShotMarker(0.84, 0.86, 'Tap the pencil to start a new secure conversation'),
            ]),
          const AcademyShot(
            asset: 'assets/academy_shots/messages_contacts.jpg', aspect: 0.563,
            title: 'Contacts', platformNote: 'Phone + Desktop',
            markers: [ShotMarker(0.42, 0.075, 'Your saved citizens — message or pay them in a tap')]),
          const AcademyShot(
            asset: 'assets/academy_shots/messages_enclave.jpg', aspect: 0.563,
            title: 'SOV Enclave — the public town square', platformNote: 'Phone + Desktop',
            subtitle: 'The Enclave is citizen-governed: it goes live once citizens vote it on. Then any citizen can post — and any citizen can flag spam.',
            markers: [ShotMarker(0.66, 0.075, 'SOV Enclave — activated by a citizen vote in the Constitution tab')]),
          const AcademyShot(
            asset: 'assets/academy_shots/messages_groups.jpg', aspect: 0.563,
            title: 'Groups', platformNote: 'Phone + Desktop',
            markers: [ShotMarker(0.88, 0.075, 'Group chats — many citizens, one encrypted thread')]),

          _tourStage('6', 'Vault — your funds can never be lost', 'Lock SOV for your family, claim an inherited vault, or serve on a recovery jury.'),
          const AcademyShot(
            asset: 'assets/academy_shots/vault.jpg', aspect: 0.563,
            title: 'My Vaults', platformNote: 'Phone + Desktop',
            markers: [
              ShotMarker(0.18, 0.075, 'My Vaults — SOV you\'ve locked away'),
              ShotMarker(0.5, 0.9, 'Create a vault — a family claim key + keyword, recoverable by a citizen jury if the key is ever lost'),
            ]),
          const AcademyShot(
            asset: 'assets/academy_shots/vault_claim.jpg', aspect: 0.563,
            title: 'Claim a Vault', platformNote: 'Phone + Desktop',
            markers: [ShotMarker(0.45, 0.075, 'Claim a vault left to you — prove it with the family keyword')]),
          const AcademyShot(
            asset: 'assets/academy_shots/vault_justice.jpg', aspect: 0.563,
            title: 'Justice Council', platformNote: 'Phone + Desktop',
            markers: [ShotMarker(0.82, 0.075, 'If chosen, you help a family recover a vault — citizens protecting citizens')]),

          _tourStage('7', 'Governance — the citizen government', 'Four tabs: justice cases, the constitution, live votes, and petitions.'),
          const AcademyShot(
            asset: 'assets/academy_shots/governance.jpg', aspect: 0.563,
            title: 'Justice', platformNote: 'Phone + Desktop',
            markers: [
              ShotMarker(0.14, 0.075, 'Justice — cases you\'re a juror on'),
              ShotMarker(0.5, 0.7, 'File a dispute with a 10 SOV bond — a random jury reviews it within 72 hours'),
            ]),
          const AcademyShot(
            asset: 'assets/academy_shots/gov_constitution.jpg', aspect: 0.563,
            title: 'Constitution — turn protocols on', platformNote: 'Phone + Desktop',
            markers: [ShotMarker(0.32, 0.075, 'Vote protocols on or off — SOV Enclave, SOV Login, payment links and more')]),
          const AcademyShot(
            asset: 'assets/academy_shots/gov_votes.jpg', aspect: 0.563,
            title: 'Votes', platformNote: 'Phone + Desktop',
            markers: [ShotMarker(0.5, 0.075, 'Every open vote — one enrolled human, one vote')]),
          const AcademyShot(
            asset: 'assets/academy_shots/gov_petitions.jpg', aspect: 0.563,
            title: 'Petitions', platformNote: 'Phone + Desktop',
            markers: [ShotMarker(0.7, 0.075, 'Start or sign a petition to force a network-wide vote')]),

          _tourStage('8', 'Watch the network', 'Anyone can see the network is healthy and honest — nothing is hidden.'),
          const AcademyShot(
            asset: 'assets/academy_shots/node_status.jpg', aspect: 0.561,
            title: 'The live network — the nodes you’re connected to',
            platformNote: 'Phone + Desktop',
            markers: [
              ShotMarker(0.5, 0.14, 'Every node you’re connected to, live — a green dot means connected'),
              ShotMarker(0.85, 0.14, 'The count of nodes carrying the network right now'),
            ]),
          const AcademyShot(
            asset: 'assets/academy_shots/economy.jpg', aspect: 0.561,
            title: 'Economy — the 50M cap, in the open', platformNote: 'Phone + Desktop',
            markers: [ShotMarker(0.5, 0.14, 'Pools + wallets always add up to the 50,000,000 cap — verify it yourself')]),
          Container(
            margin: const EdgeInsets.only(bottom: 18),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF10231C),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF3DDC97).withValues(alpha: 0.35)),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.desktop_windows_rounded, color: Color(0xFF3DDC97), size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: RichText(text: TextSpan(
                  style: const TextStyle(color: Colors.white, fontSize: 13.5, height: 1.4),
                  children: [
                    const TextSpan(text: 'Phone vs desktop: ',
                        style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF3DDC97))),
                    TextSpan(
                      text: 'the two apps are the same, with one addition on the desktop (Windows / Mac): '
                          'a Full Node switch on this screen. Turn it on and your computer helps carry the '
                          'network and earns the operator payout. The phone app connects to nodes but does not run one.',
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.85)),
                    ),
                  ],
                )),
              ),
            ]),
          ),

          // ── The desktop Full Node card — Serving state (operator's payoff) ──
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft, end: Alignment.bottomRight,
                colors: [Color(0xFF1A1E14), Color(0xFF12160E)]),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFD4AF37).withValues(alpha: 0.6)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.dns_outlined, color: Color(0xFFF5C518), size: 22),
                const SizedBox(width: 10),
                const Expanded(child: Text('Full Node',
                    style: TextStyle(color: Color(0xFFF5C518), fontSize: 18, fontWeight: FontWeight.bold))),
                // toggle ON
                Container(
                  width: 46, height: 26,
                  decoration: BoxDecoration(color: const Color(0xFFB8912A), borderRadius: BorderRadius.circular(13)),
                  child: const Align(alignment: Alignment.centerRight,
                    child: Padding(padding: EdgeInsets.only(right: 3),
                      child: CircleAvatar(radius: 10, backgroundColor: Color(0xFFF5C518)))),
                ),
              ]),
              const SizedBox(height: 12),
              Text('This computer is serving the SOV network. Keep it on continuously (≥21 days) '
                  'to earn the monthly operator payout — credited to your wallet.',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.82), fontSize: 13.5, height: 1.5)),
              const SizedBox(height: 12),
              Row(children: const [
                Icon(Icons.bolt_rounded, color: Color(0xFF3DDC97), size: 18),
                SizedBox(width: 6),
                Text('Serving • uptime 6d 4h',
                    style: TextStyle(color: Color(0xFF3DDC97), fontSize: 14, fontWeight: FontWeight.w700)),
              ]),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: const [
                _NodePortChip(label: 'WSS :443'),
                _NodePortChip(label: 'mesh :7771'),
                _NodePortChip(label: 'dashboard :8080'),
              ]),
              const SizedBox(height: 10),
              Text('Operator dashboard: http://127.0.0.1:8080/dashboard',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 11.5)),
              const SizedBox(height: 10),
              Text('One switch. Turn it on and your PC carries the network and earns — the phone app connects to nodes but never runs one.',
                  style: TextStyle(color: const Color(0xFFF5C518).withValues(alpha: 0.85), fontSize: 12.5, height: 1.4)),
            ]),
          ),
          // Real screenshot: the reach-mode options a home operator picks
          const AcademyShot(
            asset: 'assets/academy_shots/win_reach_modes.jpg', aspect: 0.821,
            title: 'How citizens reach your home node',
            platformNote: 'Full node',
            subtitle: 'Behind home internet? Pick how people reach you — the node handles the rest.',
            markers: [
              ShotMarker(0.5, 0.60, 'Automatic — router or circuit-relay through a public node (zero setup)'),
              ShotMarker(0.5, 0.73, 'Tailscale Funnel — a free public address, no port-forwarding'),
              ShotMarker(0.5, 0.85, 'Static IP / port-forward — if you run your own server'),
            ]),

          // ── Operator firewall guidance — the Windows prompt every operator sees ──
          Container(
            margin: const EdgeInsets.only(bottom: 22),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF161F35),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFD4AF37).withValues(alpha: 0.3)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: const [
                Icon(Icons.shield_outlined, color: Color(0xFFD4AF37), size: 20),
                SizedBox(width: 8),
                Expanded(child: Text('When you turn the node ON, Windows will ask this',
                    style: TextStyle(color: Color(0xFFD4AF37), fontSize: 15, fontWeight: FontWeight.w700))),
              ]),
              const SizedBox(height: 12),
              // Faithful reproduction of the Windows Security firewall prompt.
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1B1B1B),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white12),
                ),
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Windows Security',
                      style: TextStyle(color: Colors.white54, fontSize: 11)),
                  const SizedBox(height: 8),
                  const Text('Do you want to allow public and private networks to access this app?',
                      style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600, height: 1.3)),
                  const SizedBox(height: 10),
                  Row(children: const [
                    Icon(Icons.hexagon, color: Color(0xFF6DBB4A), size: 20),
                    SizedBox(width: 8),
                    Text('Node.js JavaScript Runtime',
                        style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                  ]),
                  const SizedBox(height: 12),
                  Row(children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF3DDC97),
                        borderRadius: BorderRadius.circular(4),
                        boxShadow: [BoxShadow(color: const Color(0xFF3DDC97).withValues(alpha: 0.5), blurRadius: 12)],
                      ),
                      child: const Text('Allow',
                          style: TextStyle(color: Color(0xFF0B1120), fontSize: 13, fontWeight: FontWeight.w700)),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2A2A2A),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: const Text('Cancel', style: TextStyle(color: Colors.white70, fontSize: 13)),
                    ),
                    const Spacer(),
                    const Icon(Icons.arrow_back_rounded, color: Color(0xFF3DDC97), size: 18),
                    const SizedBox(width: 4),
                    const Text('click this', style: TextStyle(color: Color(0xFF3DDC97), fontSize: 11.5, fontWeight: FontWeight.w600)),
                  ]),
                ]),
              ),
              const SizedBox(height: 12),
              Text(
                'This is normal and safe. Node.js is the SOV node software running on your PC — clicking '
                '"Allow" lets other citizens reach your node so it can serve the network and earn your operator '
                'payout. It appears once per version. If you click Cancel, your node runs but stays invisible '
                'to other citizens.',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.78), fontSize: 13, height: 1.5),
              ),
            ]),
          ),

          _tourStage('9', 'Certify & stay secure', 'Turn knowledge into income, and lock your wallet down.'),
          const AcademyShot(
            asset: 'assets/academy_shots/academy.jpg', aspect: 0.561,
            title: 'Academy — learn & certify', platformNote: 'Phone + Desktop',
            markers: [ShotMarker(0.5, 0.30, 'Take a track, pass the test, earn a certification you can charge clients for')]),
          const AcademyShot(
            asset: 'assets/academy_shots/profile_security.jpg', aspect: 0.561,
            title: 'Profile & security', platformNote: 'Phone + Desktop',
            markers: [
              ShotMarker(0.85, 0.30, 'Set or require a PIN so no one else can open your wallet'),
              ShotMarker(0.85, 0.55, 'Proof of Life keeps your vaults sealed to you'),
            ]),

          _tourStage('10', 'Connect your website', 'Any website owner can add "Sign in with SOV" — registered straight from the wallet, no server setup.'),
          const AcademyShot(
            asset: 'assets/academy_shots/platform_register.jpg', aspect: 0.561,
            title: 'Register a Platform', platformNote: 'Phone + Desktop',
            subtitle: 'Profile → Register a Platform. Your registration is signed by your wallet; a one-time SOV fee goes to the node operator pool.',
            markers: [
              ShotMarker(0.5, 0.35, 'Enter your website\'s domain'),
              ShotMarker(0.5, 0.47, 'Your callback URL — where the network sends the signed login result'),
              ShotMarker(0.5, 0.56, 'Tap "Register & Pay Fee" — done. Citizens can now sign in to your site with their SOV ID'),
            ]),
          const AcademyShot(
            asset: 'assets/academy_shots/sov_link_verify.jpg', aspect: 0.561,
            title: 'Signing in to a website — what the citizen sees',
            platformNote: 'Phone + Desktop',
            subtitle: 'On the website they click "Sign in with SOV"; the wallet shows this. They type the 6-digit code from the site — one tap proves they are a real, unique human.',
            markers: [
              ShotMarker(0.5, 0.42, 'The website shows a 6-digit code — type it here'),
              ShotMarker(0.5, 0.60, 'It proves your personhood ONCE — the site never sees your wallet, messages, or anything else'),
              ShotMarker(0.5, 0.90, 'Tap Continue — you are signed in as a verified human, no password'),
            ]),
        ],
      ),
    );
  }

  // ── KNOWLEDGE BANK (static, civic education) ───────────────────────────────

  Widget _buildKnowledgeBankSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Knowledge Bank',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text('Why SOV exists and what it means for you',
              style: TextStyle(color: Colors.white38, fontSize: 12)),
          const SizedBox(height: 14),
          ..._knowledgeBank.map(_buildKnowledgeCard),
        ],
      ),
    );
  }

  Widget _buildKnowledgeCard(dynamic a) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withAlpha(10)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38, height: 38,
            decoration: BoxDecoration(
                color: Colors.white.withAlpha(8), borderRadius: BorderRadius.circular(10)),
            child: Icon(a.icon, color: Colors.white54, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(a.title,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
                const SizedBox(height: 4),
                Text(a.body,
                    style: const TextStyle(color: Colors.white54, fontSize: 12, height: 1.5)),
                // Optional visual guide: a card may carry a `visual:` key naming a
                // self-contained diagram (widgets/academy_visuals.dart). Records
                // without the field are read safely as no-visual.
                _visualFor(a),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Render a card's visual guide if it declares one. Records are `dynamic`;
  // only some carry a `visual` field, so we read it defensively.
  static Widget _visualFor(dynamic a) {
    String key = '';
    try { key = ((a as dynamic).visual as String?) ?? ''; } catch (_) {}
    if (key.isEmpty) return const SizedBox.shrink();
    // Two independent diagram registries: the civic-education set
    // (academy_visuals.dart) and the operator-onboarding set
    // (academy_operator_visuals.dart, `op_*` keys). Fall through to the second.
    final v = AcademyVisuals.byKey(key) ?? AcademyOperatorVisuals.byKey(key);
    return v ?? const SizedBox.shrink();
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  static String _monthName(int m) {
    const months = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return m >= 1 && m <= 12 ? months[m] : '';
  }
}

// ── Publish Article Bottom Sheet ──────────────────────────────────────────────

class _PublishArticleSheet extends StatefulWidget {
  final String sovereignId;
  final List<String> categories;
  final VoidCallback onPublished;
  const _PublishArticleSheet({required this.sovereignId, required this.categories, required this.onPublished});

  @override
  State<_PublishArticleSheet> createState() => _PublishArticleSheetState();
}

class _PublishArticleSheetState extends State<_PublishArticleSheet> {
  static const _gold   = Color(0xFFD4AF37);
  static const _cardBg = Color(0xFF0D1F3A);

  final _titleCtrl = TextEditingController();
  final _bodyCtrl  = TextEditingController();
  String _category = 'general';
  bool   _publishing = false;
  String _error = '';

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  Future<void> _publish() async {
    final title = _titleCtrl.text.trim();
    final body  = _bodyCtrl.text.trim();
    if (title.isEmpty) { setState(() => _error = 'Title is required'); return; }
    if (body.length < 50) { setState(() => _error = 'Article body must be at least 50 characters'); return; }

    setState(() { _publishing = true; _error = ''; });
    try {
      final articleId = 'ART-${widget.sovereignId.replaceAll('-', '')}-${DateTime.now().millisecondsSinceEpoch}';
      final res = await RelayConnector.publishArticle(
        articleId: articleId,
        authorId:  widget.sovereignId,
        title:     title,
        body:      body,
        category:  _category,
      );
      if (!mounted) return;
      if (res?['success'] == true) {
        Navigator.pop(context);
        widget.onPublished();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Article published to the network'),
          backgroundColor: Color(0xFF0D1F3A),
          behavior: SnackBarBehavior.floating,
        ));
      } else {
        setState(() { _error = res?['error'] ?? 'Publish failed'; _publishing = false; });
      }
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _publishing = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Drag handle
            Center(child: Container(width: 36, height: 4,
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 20),

            const Text('Write an Article',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text('Published to the SOV relay network for all citizens',
                style: TextStyle(color: Colors.white38, fontSize: 12)),
            const SizedBox(height: 16),

            // Bond notice
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _gold.withAlpha(10),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _gold.withAlpha(40)),
              ),
              child: const Row(children: [
                Icon(Icons.info_outline_rounded, color: Color(0xFFD4AF37), size: 16),
                SizedBox(width: 8),
                Expanded(child: Text(
                  'Publishing requires an academy_article_bond SOV deposit (governance-set, default 5 SOV). '
                  'Your article stays on the network permanently.',
                  style: TextStyle(color: Color(0xFFD4AF37), fontSize: 11, height: 1.4),
                )),
              ]),
            ),
            const SizedBox(height: 16),

            // Title
            TextField(
              controller: _titleCtrl,
              maxLength: 200,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                labelText: 'Title',
                labelStyle: const TextStyle(color: Colors.white38),
                filled: true, fillColor: const Color(0xFF0A1628),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: Colors.white.withAlpha(20))),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: Colors.white.withAlpha(20))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFD4AF37))),
                counterStyle: const TextStyle(color: Colors.white24),
              ),
            ),
            const SizedBox(height: 12),

            // Category dropdown
            DropdownButtonFormField<String>(
              initialValue: _category,
              dropdownColor: _cardBg,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                labelText: 'Category',
                labelStyle: const TextStyle(color: Colors.white38),
                filled: true, fillColor: const Color(0xFF0A1628),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: Colors.white.withAlpha(20))),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: Colors.white.withAlpha(20))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFD4AF37))),
              ),
              items: widget.categories.map((c) => DropdownMenuItem(
                value: c,
                child: Text(c[0].toUpperCase() + c.substring(1), style: const TextStyle(color: Colors.white)),
              )).toList(),
              onChanged: (v) { if (v != null) setState(() => _category = v); },
            ),
            const SizedBox(height: 12),

            // Body
            TextField(
              controller: _bodyCtrl,
              maxLines: 8,
              maxLength: 50000,
              style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.5),
              decoration: InputDecoration(
                labelText: 'Article body',
                alignLabelWithHint: true,
                labelStyle: const TextStyle(color: Colors.white38),
                filled: true, fillColor: const Color(0xFF0A1628),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: Colors.white.withAlpha(20))),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: Colors.white.withAlpha(20))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFD4AF37))),
                counterStyle: const TextStyle(color: Colors.white24),
              ),
            ),
            const SizedBox(height: 12),

            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(_error, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
              ),

            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: _publishing ? null : _publish,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _gold,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  elevation: 0,
                ),
                child: _publishing
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                    : const Text('Publish Article', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Article View Bottom Sheet ─────────────────────────────────────────────────

class _ArticleViewSheet extends StatelessWidget {
  final Map<String, dynamic> article;
  final bool isUpvoted;
  final VoidCallback onUpvote;
  final String sovereignId;

  const _ArticleViewSheet({
    required this.article,
    required this.isUpvoted,
    required this.onUpvote,
    required this.sovereignId,
  });

  static String _monthName(int m) {
    const months = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return m >= 1 && m <= 12 ? months[m] : '';
  }

  @override
  Widget build(BuildContext context) {
    final title    = article['title']      as String? ?? '';
    final body     = article['body']       as String? ?? '';
    final authorId = article['author_id']  as String? ?? '';
    final category = article['category']   as String? ?? 'general';
    final upvotes  = (article['upvote_count'] as num?)?.toInt() ?? 0;
    final createdAt = (article['created_at'] as num?)?.toInt() ?? 0;

    final cachedAuthorName = RelayConnector.cachedPalmNameFor(authorId);
    final shortAuthor = cachedAuthorName.isNotEmpty
        ? cachedAuthorName
        : (authorId.length > 14
            ? '${authorId.substring(0, 10)}…${authorId.substring(authorId.length - 4)}'
            : authorId);

    final dt = DateTime.fromMillisecondsSinceEpoch(createdAt);
    final dateStr = '${dt.day} ${_monthName(dt.month)} ${dt.year}';

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (_, controller) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF0D1F3A),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            // Drag handle
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Center(child: Container(width: 36, height: 4,
                  decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)))),
            ),
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold, height: 1.3)),
                  const SizedBox(height: 10),
                  Row(children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A3A5C), borderRadius: BorderRadius.circular(6)),
                      child: Text(category[0].toUpperCase() + category.substring(1),
                          style: const TextStyle(color: Color(0xFF64B5F6), fontSize: 10, fontWeight: FontWeight.w600)),
                    ),
                    const SizedBox(width: 8),
                    Text(shortAuthor, style: const TextStyle(color: Colors.white38, fontSize: 10, fontFamily: 'monospace')),
                    const Spacer(),
                    Text(dateStr, style: const TextStyle(color: Colors.white24, fontSize: 10)),
                    const SizedBox(width: 12),
                    GestureDetector(
                      onTap: isUpvoted ? null : onUpvote,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: isUpvoted ? const Color(0xFFD4AF37).withAlpha(25) : Colors.white.withAlpha(8),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: isUpvoted ? const Color(0xFFD4AF37).withAlpha(80) : Colors.white.withAlpha(15)),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.thumb_up_rounded, size: 12,
                              color: isUpvoted ? const Color(0xFFD4AF37) : Colors.white38),
                          const SizedBox(width: 4),
                          Text('$upvotes',
                              style: TextStyle(
                                  color: isUpvoted ? const Color(0xFFD4AF37) : Colors.white38,
                                  fontSize: 11, fontWeight: FontWeight.w600)),
                        ]),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 14),
                  Container(height: 1, color: Colors.white.withAlpha(15)),
                ],
              ),
            ),
            // Body
            Expanded(
              child: ListView(
                controller: controller,
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                children: [
                  Text(
                    body.isEmpty ? 'No content available.' : body,
                    style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.7),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Small teal port chip used in the reproduced desktop Full Node card.
class _NodePortChip extends StatelessWidget {
  final String label;
  const _NodePortChip({required this.label});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFF00C4B4).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: const Color(0xFF00C4B4).withValues(alpha: 0.35)),
      ),
      child: Text(label,
          style: const TextStyle(color: Color(0xFF3DDC97), fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}
