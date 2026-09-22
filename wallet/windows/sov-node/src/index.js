// ─────────────────────────────────────────────────────────────────────────────
// SOV NODE — Entry Point
// ─────────────────────────────────────────────────────────────────────────────
// This is the sovereign infrastructure software. A citizen installs this once.
// Their computer becomes a permanent SOV Network node. No VPS. No corporate
// dependency. Citizens own the infrastructure.
//
// Boot sequence:
//   1. Integrity check  — verify all source files against signed manifest
//   2. Identity         — load or generate node Ed25519 keypair (TPM if available)
//   3. Storage          — open SQLite database (node.db)
//   4. Network          — UPnP port forward, detect NAT type, join peer mesh
//   5. Peer mesh        — connect to bootstrap seeds, gossip node registry
//   6. Phone mesh       — fragment routing layer for phones behind firewalls
//   7. Transfer engine  — SOV coin transfer with 3-guard double-spend prevention
//   8. Citizen gateway  — WebSocket server accepting citizen app connections
//   9. System tray      — desktop UI icon with live status
// ─────────────────────────────────────────────────────────────────────────────

'use strict';

require('dotenv').config();
const path = require('path');
const os   = require('os');
const fs   = require('fs');

// ── Logger ─────────────────────────────────────────────────────────────────
const winston = require('winston');
const DATA_DIR = process.env.SOV_DATA_DIR || path.join(os.homedir(), '.sov-node');
fs.mkdirSync(DATA_DIR, { recursive: true });

const log = winston.createLogger({
  level: process.env.LOG_LEVEL || 'info',
  format: winston.format.combine(
    winston.format.timestamp({ format: 'HH:mm:ss' }),
    winston.format.printf(({ timestamp, level, message }) =>
      `[${timestamp}] [${level.toUpperCase().padEnd(5)}] ${message}`)
  ),
  transports: [
    new winston.transports.Console(),
    new winston.transports.File({
      filename: path.join(DATA_DIR, 'logs', 'sov-node.log'),
      maxsize:  10 * 1024 * 1024, // 10 MB per file
      maxFiles: 3,
    })
  ]
});

global.sovLog = log;

// ── Boot sequence ──────────────────────────────────────────────────────────
async function boot() {
  fs.mkdirSync(path.join(DATA_DIR, 'logs'), { recursive: true });

  log.info('');
  log.info('══════════════════════════════════════════════════════════');
  log.info('   SOV Node  —  Sovereign Citizen Infrastructure');
global.sovLog.info(`      [VERSION] sov-relay v${process.env.SOV_RELAY_VERSION || 'dev'} — started ${new Date().toISOString()} // SOV_RELAY_VERSION_PRINT`);
  log.info('══════════════════════════════════════════════════════════');
  log.info('');

  // ── Step 1 — Integrity check ──────────────────────────────────────────────
  log.info('[1/9] Verifying software integrity...');
  const { IntegrityChecker } = require('./security/integrity');
  await IntegrityChecker.verify();
  log.info('      ✓ Source files verified');

  // Fingerprint of the source this node is actually running. Two nodes holding
  // identical source produce an identical root on any OS, so an operator can
  // compare theirs against what the network reports without trusting us. Purely
  // informational today; the acceptance rule that consumes it comes later.
  try {
    const { sourceRoot } = require('./release/source_root');
    const sr = sourceRoot(require('path').join(__dirname, '..'));
    log.info(`      ✓ Source root: ${sr.root.slice(0, 16)}... (${sr.fileCount} files)`);
    global.sovSourceRoot = sr.root;
  } catch (e) {
    log.warn('      ! Could not compute source root: ' + e.message);
  }

  // ── Step 2 — Node identity ────────────────────────────────────────────────
  log.info('[2/9] Loading node identity...');
  const { NodeIdentity } = require('./security/node_identity');
  const fsOp = require('fs');
  const pathOp = require('path');
  const dataDirOp = process.env.SOV_DATA_DIR ||
    pathOp.join(require('os').homedir(), '.sov-node');
  // First run = no node key on disk yet. Only then is a missing operator ID fatal.
  const firstRunOp = !fsOp.existsSync(pathOp.join(dataDirOp, 'node_identity.enc'));

  // Genesis intent = a FIRST run with NO bootstrap configured. The operator is
  // starting the network, not joining it, so they cannot have a Sovereign ID yet
  // (the app needs a live node to enrol a palm against). A blank operator ID is then
  // expected, not fatal — the node comes up, serves, the founder enrols as citizen
  // #1, then sets OPERATOR_SOVEREIGN_ID and restarts. A joining node (bootstrap set)
  // still requires the ID up front, and the network interrogates it on join.
  const _bootEnvOp = (process.env.SOV_BOOTSTRAP_NODES || '').trim();
  let _bootFileOp = false;
  try {
    const _bjOp = pathOp.join(dataDirOp, 'bootstrap.json');
    if (fsOp.existsSync(_bjOp)) {
      const _pOp = JSON.parse(fsOp.readFileSync(_bjOp, 'utf8'));
      const _listOp = Array.isArray(_pOp) ? _pOp : ((_pOp && _pOp.nodes) || []);
      _bootFileOp = Array.isArray(_listOp) && _listOp.length > 0;
    }
  } catch (_) {}
  const genesisIntentOp = firstRunOp && _bootEnvOp === '' && !_bootFileOp;

  const opCheck = NodeIdentity.assertOperatorId({ firstRun: firstRunOp, genesis: genesisIntentOp });
  if (!opCheck.ok) {
    log.error('');
    log.error('  ==============================================================');
    log.error('   CANNOT START — operator Sovereign ID problem');
    log.error('  ==============================================================');
    for (const line of opCheck.reason) log.error('      ' + line);
    log.error('');
    process.exit(1);
  }

  const identity = await NodeIdentity.load();
  if (opCheck.warn) {
    if (opCheck.genesis) {
      log.warn('      ! GENESIS start with no operator ID — this is expected.');
      log.warn('        Enrol your palm in the app first (you become citizen #1),');
      log.warn('        then set OPERATOR_SOVEREIGN_ID in your .env and restart to earn.');
    } else {
      log.warn('      ! No OPERATOR_SOVEREIGN_ID set — this node earns nothing.');
      log.warn('        Set it in your .env to receive proof-of-service payouts.');
    }
  } else {
    log.info(`      ✓ Operator: ${opCheck.id}`);
  }
  log.info(`      ✓ Node ID: ${identity.nodeId}`);
  log.info(`      ✓ Key: ${identity.storageMethod}`);

  // ── Step 3 — Storage ──────────────────────────────────────────────────────
  log.info('[3/9] Opening node database...');
  const { NodeDB } = require('./storage/db');
  const db = new NodeDB();

  // ── One-shot mesh fork-heal (gated by env) ──────────────────────────────
  // Bumps sov_disc.version for the given sovereign_id(s) so the canonical
  // balance on THIS node propagates to peers via higher-version-wins. Heals
  // same-version balance forks left by the legacy transfer-fee bug.
  // Set SOV_FORK_HEAL="SOV-AAA,SOV-BBB" then restart once; clear it after.
  if (process.env.SOV_FORK_HEAL) {
    for (const sid of process.env.SOV_FORK_HEAL.split(',').map(s => s.trim()).filter(Boolean)) {
      try {
        const r = db._db.prepare('UPDATE sov_disc SET version = version + 1 WHERE sovereign_id = ?').run(sid);
        const row = db._db.prepare('SELECT balance_seeds, version FROM sov_disc WHERE sovereign_id = ?').get(sid);
        log.info(`[FORK-HEAL] ${sid}: changes=${r.changes} now bal=${row ? row.balance_seeds : 'NA'} v=${row ? row.version : 'NA'}`);
      } catch (e) { log.warn(`[FORK-HEAL] ${sid} error: ${e.message}`); }
    }
  }

  // ── Read-only sov_disc fingerprint (gated by env) — mesh divergence forensics.
  // Dumps count, balance sum, and a sha256 over all sorted id:balance:version rows
  // (the exact merkle leaf inputs) so node ledgers can be diffed without opening a
  // 2nd DB connection. Also prints version-distribution. Set SOV_DISC_FINGERPRINT=1.
  if (process.env.SOV_DISC_FINGERPRINT) {
    try {
      const rows = db._db.prepare('SELECT sovereign_id, balance_seeds, version FROM sov_disc ORDER BY sovereign_id ASC').all();
      const concat = rows.map(r => `${r.sovereign_id}:${r.balance_seeds}:${r.version}`).join('|');
      const fp = require('crypto').createHash('sha256').update(concat).digest('hex').slice(0, 16);
      const sum = rows.reduce((a, r) => a + Number(r.balance_seeds), 0);
      const idfp = require('crypto').createHash('sha256').update(rows.map(r => r.sovereign_id).join(',')).digest('hex').slice(0, 16);
      log.info(`[DISC-FP] count=${rows.length} sum=${sum} fullfp=${fp} idsetfp=${idfp} root=${db.computeMerkleRoot().slice(0,16)}`);
    } catch (e) { log.warn(`[DISC-FP] error: ${e.message}`); }
  }

  // ── Genesis founder seeding ─────────────────────────────────────────────
  // If FOUNDER_SOVEREIGN_ID is set in snap.env, pre-seed the disc with the
  // founder's allocation before any citizen connects. This is the "build and
  // forget" design — every fresh node install immediately knows the founder.
  if (process.env.FOUNDER_SOVEREIGN_ID) {
    db.seedGenesisFounder();
  } else if (db.citizenCount() === 0) {
    log.info('      ℹ  Disc empty. Set FOUNDER_SOVEREIGN_ID in snap.env to pre-seed founder balance.');
    log.info('      ℹ  Or enroll your phone — the first citizen on an empty disc receives genesis allocation.');
  }

  log.info(`      ✓ Citizens on disc: ${db.citizenCount()}`);

  // ── Step 4 — Network ──────────────────────────────────────────────────────
  log.info('[4/9] Configuring network reachability...');
  const { NetworkManager } = require('./network/network_manager');
  const network = await NetworkManager.start(identity);
  log.info(`      ✓ Public IP:     ${network.publicAddress}`);
  log.info(`      ✓ NAT type:      ${network.natType}`);
  log.info(`      ✓ Reachability:  ${network.reachabilityMethod}`);

  // ── Step 5a — Relay pool (node discovery) ────────────────────────────────
  log.info('[5/9] Loading node discovery pool...');
  const { RelayPool, createDiscoveryServer } = require('./network/relay_pool');
  const relayPool = new RelayPool(identity, db);
  log.info(`      ✓ Known nodes in pool: ${relayPool.size()}`);

  // A fresh install knows nobody. Ask the pointer mirrors where the network is,
  // exactly as the client app does, so an operator only ever has to supply their
  // Sovereign ID — not hunt for an address to type in.
  //
  // Only when nothing local already knows one. The mirrors host a JSON list and
  // nothing more: whatever comes back still has to pass the joining checks, so a
  // wrong or hostile answer costs a failed connection and nothing else.
  try {
    const { bootstrapNodes, discoverFromPointers } = require('./network/bootstrap');
    if (bootstrapNodes(db).length === 0) {
      log.info('      No known peers — asking the pointer mirrors...');
      const found = await discoverFromPointers();
      if (found.length) {
        // Deliberately NOT added to the pool. A pointer suggests where to look; it
        // does not attest that a node exists. Registering it under an invented id
        // would leave a phantom entry that outlives the real peer we then meet.
        // The peer mesh dials these directly and the pool records only what answers.
        log.info(`      ✓ Learned ${found.length} address(es) from the pointer mirrors`);
      } else {
        log.warn('      ! Pointer mirrors gave nothing — set SOV_BOOTSTRAP_NODES or use an invite.');
      }
    }
  } catch (e) {
    log.warn('      pointer discovery skipped: ' + e.message);
  }

  // Start discovery HTTP server — serves /relay-pool and /download
  const discoveryServer = createDiscoveryServer(identity, db, relayPool, network);

  // ── DHT — find and be found without depending on anyone ──────────────────
  // Mirrors and domains can be pressured or withdrawn. The public BitTorrent DHT
  // cannot: we do not run it, so it cannot be taken from us. Once a node has an
  // address it announces there, and from that moment anything looking for the
  // network can find it without a relationship with any node — which is what
  // keeps the mirrors as plain file hosts that know nothing worth compelling.
  let dhtAnnouncer = null;
  try {
    const { DhtAnnouncer } = require('./network/dht_announce');
    // Publish to the public DHT only once something has actually reached us.
    dhtAnnouncer = new DhtAnnouncer(
      parseInt(process.env.SYNC_PORT || '7771'),
      // FAIL OPEN when the node has no proof system at all: a build without
      // reachability-proof has `inboundVerified` undefined, and treating that as
      // "unproven" silenced a genuinely reachable bootstrap node the moment this
      // gate shipped (VPS1, 2026-08-02). Only an explicit false withholds.
      () => !(network && network.inboundVerified === false));
    await dhtAnnouncer.start();
    global.sovDht = dhtAnnouncer;      // peer mesh reads dial targets from here
  } catch (e) {
    log.warn('      DHT announcer skipped: ' + e.message);
  }

  // ── Step 5b — Peer mesh ───────────────────────────────────────────────────
  log.info('      Joining peer mesh...');
  const { PeerMesh } = require('./network/peer_mesh');
  const peerMesh = await PeerMesh.start(identity, network, db, relayPool);

  // PI-13: pool mutations propagate at the PRIMITIVE layer, so every future
  // pool-touching feature replicates automatically instead of each one having
  // to remember to mirror itself.
  try {
    const { PoolDeltaSync } = require('./storage/pool_delta_sync');
    const poolDeltaSync = new PoolDeltaSync(db, peerMesh, identity);
    poolDeltaSync.start();
    global.sovLog.info('      ✓ Pool delta propagation active (PI-13)');
  } catch (e) {
    global.sovLog.warn(`      Pool delta sync unavailable: ${e.message}`);
  }

  // ── Fee history replication ───────────────────────────────────────────────
  // Balances already replicate; the RECORD OF HOW THEY GOT THERE did not, so a
  // citizen querying one node saw a correct balance beside an empty fee history
  // and no two nodes could be reconciled on flows. Absolute totals + max-merge,
  // so redelivery and reordering — both normal in gossip — are harmless.
  db.setInflowBroadcaster((poolId, periodId, totalSeeds) => {
    try {
      peerMesh.broadcast('POOL_INFLOW_SYNC', {
        pool_id: poolId, period_id: periodId, seeds_total: totalSeeds,
        node_id: identity.nodeId,
      });
    } catch (_) { /* a peer being unreachable must not fail the fee itself */ }
  });
  peerMesh.on('POOL_INFLOW_SYNC', (msg) => {
    try { db.mergePoolInflow(msg.pool_id, msg.period_id, Number(msg.seeds_total)); }
    catch (_) {}
  });
  if (discoveryServer && typeof discoveryServer.setPeerMesh === "function") discoveryServer.setPeerMesh(peerMesh);
  // Let the relay pool read true liveness from the mesh so the citizen-facing
  // node list only ever advertises nodes that are alive right now.
  if (typeof relayPool.setMesh === "function") relayPool.setMesh(peerMesh);

  // ── Step 6 — Phone mesh ───────────────────────────────────────────────────
  log.info('[6/9] Starting phone mesh fragment router...');
  const { PhoneMesh } = require('./network/phone_mesh');
  const phoneMesh = await PhoneMesh.start(identity, peerMesh, db);
  log.info('      ✓ Fragment routing ready (K=3 of N=5)');

  // ── Step 7 — Transfer engine ──────────────────────────────────────────────
  log.info('[7/9] Starting SOV transfer engine...');
  const { TransferEngine } = require('./protocol/transfer_engine');
  const transferEngine = new TransferEngine(identity, db, peerMesh, null);
  log.info('      ✓ Guard 1 (nonce chain)    active');
  log.info('      ✓ Guard 2 (spend lock)     active');
  log.info('      ✓ Guard 3 (version gate)   active');

  // ── Step 7b — Protocol engines ────────────────────────────────────────────
  const { EnrollmentEngine } = require('./protocol/enrollment_engine');
  const enrollmentEngine = new EnrollmentEngine(identity, db, peerMesh);

  const { MessageEngine } = require('./protocol/message_engine');
  const messageEngine = new MessageEngine(identity, db, peerMesh);

  const { GroupEngine } = require('./protocol/group_engine');
  const groupEngine = new GroupEngine(identity, db, peerMesh);

  const { FinancialEngine } = require('./protocol/financial_engine');
  const financialEngine = new FinancialEngine(identity, db, peerMesh);

  const { GovernanceEngine } = require('./protocol/governance_engine');
  const governanceEngine = new GovernanceEngine(identity, db, peerMesh);

  const { JusticeEngine } = require('./protocol/justice_engine');
  const justiceEngine = new JusticeEngine(identity, db, peerMesh);

  const { ExchangeEngine } = require('./protocol/exchange_engine');
  const exchangeEngine = new ExchangeEngine(identity, db, peerMesh);

  const { SocialEngine } = require('./protocol/social_engine');
  const socialEngine = new SocialEngine(identity, db, peerMesh);

  const { OperatorEngine } = require('./protocol/operator_engine');
  const operatorEngine = new OperatorEngine(identity, db, peerMesh);
  // Layer 2: give the mesh the earned-source_root ratifier so the PEER_HELLO
  // interrogation (Check 5) can verify a joining node runs recognised source.
  peerMesh.setOperatorEngine(operatorEngine);

  // Monthly operator payout — checks hourly, fires once per 30-day period.
  // Anti-monopoly tier multipliers locked in protocol (1.0/0.5/0.25/0).
  setInterval(() => operatorEngine._runMonthlyOperatorPayout(), 3600 * 1000);
  // First check 60s after boot
  setTimeout(() => operatorEngine._runMonthlyOperatorPayout(), 60 * 1000);

  // Peer broadcast — record payouts fired by other nodes
  peerMesh.on('OPERATOR_PAYOUT_BROADCAST', (msg) => operatorEngine._handleOperatorPayoutBroadcast(msg));

  // TIER 2 — any GitHub account can build for SOV, and no single account can stop the
  // network shipping. Builders never hold the signing key: they return CONTENT, quorum
  // agrees on a digest, and only an agreed digest is ever signed (king, 2026-08-26).
  // Inert until a builder is registered, and a release with no reachable builder falls
  // through to the node's own build (tier 3) rather than stalling.
  const { BuilderRegistry } = require('./protocol/builder_registry');
  const builderRegistry = new BuilderRegistry(identity, db, peerMesh, operatorEngine);


  const { CallsEngine } = require('./protocol/calls_engine');
  const callsEngine = new CallsEngine(identity, db, peerMesh);

  const { PioneerEngine } = require('./protocol/pioneer_engine');
  const pioneerEngine = new PioneerEngine(identity, db);

  const { AllocationEngine } = require('./protocol/allocation_engine');
  const allocationEngine = new AllocationEngine(identity, db);

  // ── Step 8 — Citizen gateway ──────────────────────────────────────────────
  log.info('[8/9] Opening citizen gateway...');
  const { CitizenGateway } = require('./network/citizen_gateway');
  const gateway = await CitizenGateway.start(
    identity, db, peerMesh, phoneMesh, transferEngine
  );
  transferEngine.setGateway(gateway);
  transferEngine.setFinancialEngine(financialEngine);
  enrollmentEngine.setGateway(gateway);
  messageEngine.setGateway(gateway);
  groupEngine.setGateway(gateway);
  gateway.setEnrollmentEngine(enrollmentEngine);
  gateway.setMessageEngine(messageEngine);
  gateway.setGroupEngine(groupEngine);
  gateway.setFinancialEngine(financialEngine);
  financialEngine.setGateway(gateway);
  gateway.setExchangeEngine(exchangeEngine);
  exchangeEngine.setGateway(gateway);
  gateway.setJusticeEngine(justiceEngine);
  justiceEngine.setGateway(gateway);
  gateway.setGovernanceEngine(governanceEngine);
  governanceEngine.setGateway(gateway);
  gateway.setSocialEngine(socialEngine);
  socialEngine.setGateway(gateway);
  operatorEngine.setGateway(gateway);
  gateway.setOperatorEngine(operatorEngine);
  gateway.setCallsEngine(callsEngine);
  gateway.setRelayPool(relayPool);   // phones use RELAY_LIST_REQUEST to discover all nodes for failover
  peerMesh.setGateway(gateway);      // peer_mesh pushes RELAY_ANNOUNCE to phones when new nodes join
  callsEngine.setGateway(gateway);
  gateway.setPioneerEngine(pioneerEngine);
  gateway.setAllocationEngine(allocationEngine);
  log.info(`      ✓ Listening for SOV app connections`);

  // ── Step 9 — System tray + Operator dashboard ────────────────────────────
  log.info('[9/9] Starting system tray and operator dashboard...');
  // SOV_NO_TRAY=1 — set by the desktop app when it runs the node as an embedded
  // sidecar: the Flutter app already owns the system-tray icon, so the node must
  // NOT add a second (icon-less, blank-on-Windows) tray entry of its own.
  let tray = null;
  if (process.env.SOV_NO_TRAY !== '1') {
    const { TrayUI } = require('./ui/tray');
    // Pass a reference object the tray can query for live stats
    const nodeRef = { identity, peerMesh, citizenGateway: gateway };
    tray = await TrayUI.start(nodeRef);
  } else {
    log.info('      ✓ Tray suppressed (embedded mode — desktop app owns the tray)');
  }

  const { OperatorDashboard } = require('./ui/operator_dashboard');
  const dashboard = OperatorDashboard.start(identity, db, peerMesh, gateway, operatorEngine);
  log.info(`      ✓ Operator dashboard at http://127.0.0.1:${process.env.DASHBOARD_PORT || '8080'}/dashboard`);

  // ── Autonomous release builder (launch-and-forget; opt-in per node) ─────────
  // Only the designated release node(s) build + threshold-sign + publish app
  // releases. Inert by default; enable with SOV_RELEASE_NODE=1 and provide the
  // witness-signer FROST share(s) via SOV_RELEASE_SIGNER_SEEDS. Requires the
  // bundled build toolchain (pkg cache + Flutter/SDK — see release-toolchain/ +
  // snapcraft). See docs/SOV_AUTONOMOUS_RELEASE_BUILDER.md.
  if (process.env.SOV_RELEASE_NODE === '1') {
    try {
      const path = require('path'), os = require('os');
      const seeds = (process.env.SOV_RELEASE_SIGNER_SEEDS || '').split(',').filter(Boolean);
      const threshold = parseInt(process.env.SOV_RELEASE_THRESHOLD || '1', 10);  // Phase 1 default; Phase 2 overrides from governance below
      // Trust anchor(s) the coordinator validates against (the owner-blessed release key
      // now; FROST witness-signers at Phase 2). Override via SOV_RELEASE_TRUST_KEYS.
      // Trust anchor selection (PI-37). Once the network has elected its own
      // witness signers, THEY are the trust anchor and the required signature
      // count is the governance-set threshold — the protocol validates itself and
      // no operator env var can widen who is trusted. The genesis key below is
      // only the Phase 1 bootstrap and stops being consulted the moment a signer
      // set is seated.
      let trustKeys = (process.env.SOV_RELEASE_TRUST_KEYS ||
        'b4fa1c07c8935c500602957c500a7fac4c6953491c9d763180d07cd45fba7545').split(',').filter(Boolean);
      let releaseThreshold = threshold;
      try {
        const { WitnessEngine } = require('./protocol/witness_engine');
        const we = new WitnessEngine(db, (k, d) =>
          (governanceEngine && governanceEngine._getGovParam)
            ? governanceEngine._getGovParam(k, d) : d);
        const elected = we.activeSignerPubkeys();
        if (elected.length >= we.threshold()) {
          trustKeys = elected;
          releaseThreshold = we.threshold();
          log.info(`      Release trust anchor: ${elected.length} elected witness signers ` +
                   `(threshold ${releaseThreshold}) — Phase 2`);
        } else {
          log.info('      Release trust anchor: genesis key — Phase 1 ' +
                   `(${elected.length}/${we.threshold()} signers seated)`);
        }
      } catch (e) {
        log.warn('      Witness engine unavailable, using genesis trust anchor: ' + e.message);
      }
      const outDir = process.env.SOV_RELEASE_OUT || path.join(os.homedir(), '.sov-releases');
      // Read governance params (e.g. app_download_host) from the encrypted node DB.
      const getGovParam = (k, f) => {
        try { const r = db._db.prepare("SELECT param_value FROM sov_governance_params WHERE param_key=?").get(k); return r ? r.param_value : f; }
        catch (_) { return f; }
      };
      const { ReleaseCoordinator } = require('./release/release_coordinator');
      const coordinator = new ReleaseCoordinator({ trustKeys, threshold: releaseThreshold, getGovParam });
      // Converge on releases other nodes publish.
      peerMesh.on('RELEASE_MANIFEST_BROADCAST', (msg) => { try { coordinator.ingest(msg); } catch (_) {} });
      // Live relay pool = what we bake into new downloads (so they survive genesis death).
      const getPool = () => { try { return JSON.parse(relayPool.buildPoolResponse()).nodes || []; } catch (_) { return []; } };
      // External upload (Storj/R2/B2) — credentials from sealed env; no-op if unset.
      const { credsFromEnv, publishRelease } = require('./release/release_publish');
      const creds = credsFromEnv();
      const publish = creds ? (({ artifacts, outDir: od, manifest }) => publishRelease({ artifacts, outDir: od, manifest, creds, log })) : null;

      require('./release/release_scheduler').start({
        nodeClientDir: process.env.SOV_NODECLIENT_DIR || path.join(__dirname, '..', '..', 'node-client'),
        flutterDir:    process.env.SOV_FLUTTER_DIR || '',
        outDir,
        lastManifestPath: path.join(outDir, 'sov-release-manifest.json'),
        signerSeeds:   seeds,
        threshold: releaseThreshold,
        coordinator,
        getPool,
        publish,
        broadcastManifest: (manifest) => { try { peerMesh.broadcast('RELEASE_MANIFEST_BROADCAST', manifest); } catch (_) {} },
        intervalMs:    parseInt(process.env.SOV_RELEASE_INTERVAL_MS || String(24 * 60 * 60 * 1000), 10),
        log,
      });
      log.info(`      ✓ Release builder armed (SOV_RELEASE_NODE=1, host=${getGovParam('app_download_host', '(unset)') || '(unset)'}, publish=${publish ? 'on' : 'creds-unset'})`);
    } catch (e) { log.warn(`      Release builder not armed: ${e.message}`); }
  }

  // ── Announce to network ────────────────────────────────────────────────────
  // Announce with SYNC_PORT address — peers connect to the mesh on this port,
  // not the citizen gateway SOV_PORT.
  const syncAddress = network.publicAddress.replace(/:\d+$/, `:${process.env.SYNC_PORT || '7771'}`);
  await peerMesh.announceOnline(syncAddress);

  log.info('');
  log.info('══════════════════════════════════════════════════════════');
  log.info(`  ONLINE  |  ${identity.nodeId.slice(0, 24)}...`);
  log.info(`  Address : ${network.publicAddress}`);
  log.info(`  Peers   : ${peerMesh.peerCount()} connected`);
  log.info(`  Citizens: ${gateway.connectedCount()} connected`);
  log.info('');
  log.info('  This computer is now a sovereign citizen node.');
  log.info('  Earning SOV for serving the network.');
  log.info('══════════════════════════════════════════════════════════');
  log.info('');

  // ── Graceful shutdown ──────────────────────────────────────────────────────
  const shutdown = async (signal) => {
    log.info(`${signal} received — shutting down gracefully...`);
    if (tray) tray.stop();
    dashboard.stop();
    gateway.stop();
    discoveryServer.close();
    relayPool.stop();
    await peerMesh.announceOffline();
    await peerMesh.close();
    phoneMesh.stop();
    network.stop();
    db.close();
    log.info('SOV Node offline. Goodbye.');
    process.exit(0);
  };

  process.on('SIGINT',  () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));
}

boot().catch(err => {
  (global.sovLog || console).error(`\nFatal error during boot: ${err.message}`);
  (global.sovLog || console).error(err.stack);
  process.exit(1);
});
