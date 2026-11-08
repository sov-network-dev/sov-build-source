#!/usr/bin/env node
// mesh_client.js — enrol synthetic test citizens on the ISOLATED test mesh (tools/test_mesh/mesh.sh).
// Run it inside the namespace:  mesh.sh exec /usr/local/bin/node mesh_client.js <cmd> ...
//
//   enroll <wsPort> <personSeed> [--face]   enrol a NEW citizen (fresh key + Sovereign ID) whose
//                                           palm (and face) template is derived from <personSeed>,
//                                           so the same seed = the same human. Prints the result.
//   info <httpPort>                         GET /node-info from a node (discovery port)
//
// It only ever talks to 127.0.0.1: the namespace has no other route, and the client refuses any
// other host on top of that.
'use strict';
const crypto = require('crypto');
const http = require('http');
const WebSocket = require('ws');
const nacl = require('tweetnacl');

// Deterministic TEST attestation root — stands in for the Play Integrity / App Attest root on the
// isolated mesh. The node trusts it via SOV_ATTESTATION_ROOTS. attest() is the "genuine app" signing
// a capture; --noattest on enroll models an attacker's custom client that has no attestation.
function attestRoot() {
  const seed = crypto.createHash('sha256').update('sov-mesh-attest-root').digest();
  return nacl.sign.keyPair.fromSeed(new Uint8Array(seed));
}
function attestRootPubHex() { return Buffer.from(attestRoot().publicKey).toString('hex'); }
function attest(id, pubHex, palmJson, faceJson) {
  const bioHash = crypto.createHash('sha256').update(String(palmJson) + '\u0000' + String(faceJson), 'utf8').digest('hex');
  const binding = `sov-personhood-v1|${id}|${String(pubHex).toLowerCase()}|${bioHash}`;
  const ts = Date.now();
  const sig = Buffer.from(nacl.sign.detached(Buffer.from(`${binding}|${ts}`, 'utf8'), attestRoot().secretKey)).toString('hex');
  return { root: attestRootPubHex(), ts, sig };
}

// ── PATH A (genesis) via the REAL sovereign signer (security/attestation_signer.js) ──────────────
// attest() above is a bare root key that signs ANY capture — it stands in for a platform-attestation
// root and does not exercise an admission policy. Path A is the sovereign flow: a GENESIS APPROVER
// (the king) authorises THIS exact capture out of band, and ONLY then does the genesis signing backend
// issue the Ed25519 attestation the UNCHANGED gate accepts. A client that reaches the signer WITHOUT a
// valid genesis approval obtains NO attestation — the policy, not the key, is the gate. We require the
// node's own module so the proof runs against the shipped code, never a reimplementation.
const SRC = require('path').resolve(__dirname, '../../wallet/windows/sov-node/src');
function genesisSigningKey() {   // Phase-0 stand-in for the FROST group: one SOV-held signing key
  return nacl.sign.keyPair.fromSeed(new Uint8Array(crypto.createHash('sha256').update('sov-mesh-genesis-signing').digest()));
}
function genesisApproverKey() {  // the out-of-band approver (the king); may equal the signer at Phase 0
  return nacl.sign.keyPair.fromSeed(new Uint8Array(crypto.createHash('sha256').update('sov-mesh-genesis-approver').digest()));
}
function pathARootHex() { return Buffer.from(genesisSigningKey().publicKey).toString('hex'); }

// Produce a genesis-approved attestation for `cap` via the REAL signer. withApproval=false models an
// attacker who reaches the signer with no genesis authorisation. Returns the signer's result object.
function issueViaGenesis(cap, withApproval) {
  const signer = require(SRC + '/security/attestation_signer');
  const approverPub = Buffer.from(genesisApproverKey().publicKey).toString('hex');
  const approval = withApproval
    ? Buffer.from(nacl.sign.detached(Buffer.from(signer.captureBinding(cap), 'utf8'), genesisApproverKey().secretKey)).toString('hex')
    : '';   // no approval -> admit() returns GENESIS_APPROVAL_INVALID, issue() withholds the signature
  const s = signer.createSigner(signer.genesisBackend(genesisSigningKey().secretKey), { genesisApprover: approverPub });
  return s.issue(cap, { path: 'genesis', approval });   // { ok, path, attestation } | { ok:false, reason }
}

// Increment #1: the SERVED path. Instead of the client running the signer, the app asks the NODE authority
// for the attestation over op ZA. These helpers provide the env the node authority needs and the
// out-of-band genesis approval the app presents.
function genesisSigningSeedHex() { return crypto.createHash('sha256').update('sov-mesh-genesis-signing').digest('hex'); }
function genesisApproverPubHex() { return Buffer.from(genesisApproverKey().publicKey).toString('hex'); }
function genesisApprovalFor(cap) {   // the out-of-band approver (king) signs THIS capture's binding
  const signer = require(SRC + '/security/attestation_signer');
  return Buffer.from(nacl.sign.detached(Buffer.from(signer.captureBinding(cap), 'utf8'), genesisApproverKey().secretKey)).toString('hex');
}
// Genesis-approval TOKEN (SOVPA1 envelope): the approver MINTS it with the REAL tool, the app PARSES it
// (fail-fast if its bind != this capture), then enrols with the approval inside. Seed hex of the approver.
function genesisApproverSeedHex() { return crypto.createHash('sha256').update('sov-mesh-genesis-approver').digest('hex'); }
const APPROVAL_TOOL = require('../personhood/genesis_approval_token');

function unit(seed, n) {
  const v = []; let h = seed;
  while (v.length < n) { h = crypto.createHash('sha256').update(h).digest('hex'); for (let i = 0; i < 64 && v.length < n; i += 4) v.push(parseInt(h.slice(i, i + 4), 16) / 65535 - 0.5); }
  const norm = Math.hypot(...v); return v.map(x => +(x / norm).toFixed(6));
}

// A deterministic test identity (--as <name>), so the same citizen can log in again later.
function identity(name) {
  const seed = crypto.createHash('sha256').update('key:' + name).digest();
  const priv = crypto.createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), seed]), format: 'der', type: 'pkcs8' });
  const pub = crypto.createPublicKey(priv).export({ type: 'spki', format: 'der' }).subarray(-32).toString('hex');
  const id = 'SOV-' + crypto.createHash('sha256').update('id:' + name).digest('hex').slice(0, 16).toUpperCase();
  return { id, pub, sign: (s) => crypto.sign(null, Buffer.from(s), priv).toString('hex'), x: xkey(name) };
}

// SOV Speak E2E, byte-compatible with lib/sov_node_sdk/message_encryptor.dart (v2):
// X25519 ECDH -> HKDF-SHA256(salt "sov-speak-salt", info "sov-speak-v2", 32) -> AES-256-GCM,
// 12-byte nonce, envelope {"v":2,"nonce":hex,"ct":hex(ciphertext||16-byte tag)}.
function xkey(name) {
  const seed = crypto.createHash('sha256').update('x25519:' + name).digest();
  const priv = crypto.createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b656e04220420', 'hex'), seed]), format: 'der', type: 'pkcs8' });
  return { priv, pub: crypto.createPublicKey(priv).export({ type: 'spki', format: 'der' }).subarray(-32).toString('hex') };
}
function aesKey(x, theirPubHex) {
  const pub = crypto.createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b656e032100', 'hex'), Buffer.from(theirPubHex, 'hex')]), format: 'der', type: 'spki' });
  const shared = crypto.diffieHellman({ privateKey: x.priv, publicKey: pub });
  return Buffer.from(crypto.hkdfSync('sha256', shared, Buffer.from('sov-speak-salt'), Buffer.from('sov-speak-v2'), 32));
}
function encryptV2(x, theirPubHex, text) {
  const nonce = crypto.randomBytes(12); const c = crypto.createCipheriv('aes-256-gcm', aesKey(x, theirPubHex), nonce);
  const ct = Buffer.concat([c.update(text, 'utf8'), c.final(), c.getAuthTag()]);
  return JSON.stringify({ v: 2, nonce: nonce.toString('hex'), ct: ct.toString('hex') });
}
function decryptV2(x, theirPubHex, env) {
  try { const o = JSON.parse(env); if (o.v !== 2) return null; const ct = Buffer.from(o.ct, 'hex');
    const d = crypto.createDecipheriv('aes-256-gcm', aesKey(x, theirPubHex), Buffer.from(o.nonce, 'hex'));
    d.setAuthTag(ct.subarray(-16)); return Buffer.concat([d.update(ct.subarray(0, -16)), d.final()]).toString('utf8');
  } catch (_) { return null; }
}
// Ask the node for a citizen's published messaging key over an open socket.
function keyOf(ws, id) {
  return new Promise((resolve) => {
    const prev = ws._onMsg; const t = setTimeout(() => { ws._onMsg = prev; resolve(null); }, 8000);
    ws._onMsg = (m) => { if ((m.type || '') === 'PUBLIC_KEY_RESULT' || m.op === 'KR') { clearTimeout(t); ws._onMsg = prev; resolve(m.x25519_public_key_hex || null); } else if (prev) prev(m); };
    ws.send(JSON.stringify({ op: 'PK', target_id: id, target_sovereign_id: id }));   // routed by op code only
  });
}

// Log in (signed HELLO) and hand the open socket to `then`.
function hello(port, name, then) {
  const me = identity(name);
  const ws = new WebSocket(`ws://127.0.0.1:${port}`);
  // 1.4.95: the wallet signs EVERY request (RelayConnector.send -> KeyManager.signMessage) and the nodes
  // now check that signature on every money op. Sign every outgoing frame the same way: `type` dropped when
  // an op code is present, node_id + timestamp set, sha256 of that JSON signed as
  // "<id>|<counter>|<timestamp>|<type>|<hash>", counter + signature appended. HELLO and frames that already
  // carry their own signature (transfers, garbage-signature probes) go out untouched.
  const rawSend = ws.send.bind(ws);
  ws.send = (text) => {
    let o; try { o = JSON.parse(text); } catch (_) { return rawSend(text); }
    if (!o || o.signature || (o.type || o.op) === 'HELLO' || o.op === 'HL' || process.env.MESH_UNSIGNED === '1') return rawSend(text);
    if (o.op) delete o.type;
    o.node_id = me.id; o.timestamp = Date.now();
    const counter = ++ws._signCounter;
    const hash = crypto.createHash('sha256').update(JSON.stringify(o), 'utf8').digest('hex');
    const sig = me.sign(`${me.id}|${counter}|${o.timestamp}|${o.type || ''}|${hash}`);
    return rawSend(JSON.stringify(o).slice(0, -1) + `,"nonce":${counter},"signature":"${sig}"}`);
  };
  ws._signCounter = Date.now();
  ws.on('open', () => { const ts = Date.now();
    ws.send(JSON.stringify({ type: 'HELLO', sovereign_id: me.id, public_key: me.pub, timestamp: ts, signature: me.sign(`${me.id}:${ts}`), messaging_public_key: me.x.pub })); });
  ws.on('message', (raw) => { let m; try { m = JSON.parse(raw); } catch (_) { return; }
    if ((m.type || m.op) === 'HELLO_ACK' || m.op === 'HA') then(ws, me, m); else if (ws._onMsg) ws._onMsg(m); });
  return ws;
}

function enroll(port, personSeed, withFace) {
  const asName = (process.argv.indexOf('--as') > 0) ? process.argv[process.argv.indexOf('--as') + 1] : null;
  let pub, id;
  if (asName) { const me = identity(asName); pub = me.pub; id = me.id; }
  else {
    const { publicKey } = crypto.generateKeyPairSync('ed25519');
    pub = publicKey.export({ type: 'spki', format: 'der' }).subarray(-32).toString('hex');
    id = 'SOV-' + crypto.randomBytes(8).toString('hex').toUpperCase();
  }
  const ws = new WebSocket(`ws://127.0.0.1:${port}`);
  const send = (o) => ws.send(JSON.stringify(o));
  return new Promise((resolve) => {
    let pendingPalm = null;   // served mode: the PALM_EMBEDDING_REGISTER held until the node returns 'ZB'
    let livenessBinding = null;  // --liveness: the personhood binding this capture's PAD challenge is bound to
    const done = (r) => { try { ws.close(); } catch (_) {} resolve(r); };
    const timer = setTimeout(() => done({ id, error: 'TIMEOUT' }), 30000);
    ws.on('error', (e) => { clearTimeout(timer); done({ id, error: 'WS_' + e.code }); });
    ws.on('close', (code, reason) => { clearTimeout(timer); done({ id, error: 'CLOSED', code, reason: String(reason || '') }); });
    ws.on('open', () => send({ type: 'ENROLLMENT_REGISTER', sovereign_id: id, public_key: pub, enrollment_sov: 1000, citizen_number: 0 }));
    ws.on('message', (raw) => {
      let m; try { m = JSON.parse(raw); } catch (_) { return; }
      const t = m.type || m.op;
      if (t === 'ENROLLMENT_ACK') {
        if (!m.success) { clearTimeout(timer); return done({ id, error: 'ACK_' + m.error }); }
        const palmJson = JSON.stringify(unit('palm:' + personSeed, 128));
        const msg = { type: 'PALM_EMBEDDING_REGISTER', sovereign_id: id, embedding: palmJson, hand_type: 'LEFT' };
        // --face-seed <s>: a DIFFERENT face from the palm's person (1.4.93 tests: same palm, new face)
        const fsI = process.argv.indexOf('--face-seed');
        const faceSeed = fsI > 0 ? process.argv[fsI + 1] : personSeed;
        const faceJson = withFace ? JSON.stringify(unit('face:' + faceSeed, 192)) : '';
        if (withFace) msg.face_embedding = faceJson;
        // --pow: solve the §5 proof-of-work for this capture (to SOV_ENROLL_POW_BITS) and attach it.
        if (process.argv.includes('--pow')) {
          const need = parseInt(process.env.SOV_ENROLL_POW_BITS || '0', 10) || 0;
          msg.pow_nonce = require(SRC + '/security/enroll_pow').solve(id, pub, need);
        }
        // Personhood attestation. Flags select how (or whether) it is produced:
        //   --noattest          : attacker's custom client — no attestation at all
        //   --pathA             : genuine — genesis-approved, via the REAL sovereign signer
        //   --pathA-noapproval  : attacker reaches the signer with NO genesis approval -> no sig issued
        //   --replay-as <name>  : a genuine Path A attestation built over ANOTHER capture (swap/replay)
        //   (default)           : legacy bare-root attest() (pre-Path-A scenarios)
        const cap = { sovereignId: id, publicKey: pub, palmJson, faceJson };
        const ri = process.argv.indexOf('--replay-as');
        // ── SERVED path (increment #1): the app asks the NODE for its attestation over op ZA, then
        //    enrols with whatever the node returns. --served = genuine (presents a genesis approval);
        //    --served-noapproval = attacker who presents none (node withholds the signature). The PALM
        //    message is held in pendingPalm until the 'ZB' reply arrives.
        //    --served-op <csv>    = Path B operator witnesses (each named operator co-signs the binding)
        //    --served-vouch <csv> = Path C citizen vouches (each named matured citizen signs the binding)
        const servedGenuine    = process.argv.includes('--served');
        const servedNoApproval = process.argv.includes('--served-noapproval');
        //    --served-token          = Path A via the SOVPA1 approval TOKEN (mint with the real tool, parse
        //                              with the app's fail-fast bind check, enrol with the approval inside)
        //    --served-token-badsig   = a token whose approval sig is corrupted -> parse OK, NODE refuses
        //    --served-token-badbind  = a token whose bind != this capture -> the APP rejects it locally
        const servedToken   = process.argv.includes('--served-token');
        const servedTokBadS = process.argv.includes('--served-token-badsig');
        const servedTokBadB = process.argv.includes('--served-token-badbind');
        //    --served-token-reqpath  = the FULL app<->approver round-trip: the app emits its SOVREQ1 request
        //                              envelope, the approver reads it back (parseRequest) and mints over it.
        const servedTokReq  = process.argv.includes('--served-token-reqpath');
        const soI = process.argv.indexOf('--served-op');
        const svI = process.argv.indexOf('--served-vouch');
        //    --served-op-envelope / --served-vouch-envelope = the FULL Paths B/C app round-trip: each signer
        //    produces a SOVWIT1 envelope (PersonhoodClient.signWitnessEnvelope), the applicant parses it with
        //    the same fail-fast bind check (parseWitnessEnvelope) before assembling the evidence.
        const soeI = process.argv.indexOf('--served-op-envelope');
        const sveI = process.argv.indexOf('--served-vouch-envelope');
        if (servedGenuine || servedNoApproval || servedToken || servedTokBadS || servedTokBadB || servedTokReq || soI > 0 || svI > 0 || soeI > 0 || sveI > 0) {
          pendingPalm = msg;
          const signerMod = require(SRC + '/security/attestation_signer');
          const bind = signerMod.captureBinding(cap);
          const endorsers = (csv) => csv.split(',').map(n => { const e = identity(n.trim()); return { signer: e.pub, sig: e.sign(bind) }; });
          // Envelope round-trip: build SOVWIT1 per signer, then parse+bind-check it back (mirror of the app).
          const envEndorsers = (csv) => csv.split(',').map(n => {
            const e = identity(n.trim());
            const env = 'SOVWIT1:' + APPROVAL_TOOL.b64urlEncode(JSON.stringify({ v: 1, bind, signer: e.pub, sig: e.sign(bind) }));
            const obj = JSON.parse(APPROVAL_TOOL.b64urlDecode(env.slice('SOVWIT1:'.length)));
            if (obj.bind !== bind) { console.log('WITNESS_REJECTED_LOCALLY different capture'); process.exit(3); }
            return { signer: obj.signer, sig: obj.sig };
          });
          let evidence;
          if (soeI > 0)      evidence = { path: 'operator', witnesses: envEndorsers(process.argv[soeI + 1]) };
          else if (sveI > 0) evidence = { path: 'vouch',    vouches:   envEndorsers(process.argv[sveI + 1]) };
          else if (soI > 0)      evidence = { path: 'operator', witnesses: endorsers(process.argv[soI + 1]) };
          else if (svI > 0) evidence = { path: 'vouch',    vouches:   endorsers(process.argv[svI + 1]) };
          else if (servedToken || servedTokBadS || servedTokBadB || servedTokReq) {
            // Approver mints the envelope over THIS capture's binding (same key as genesisApprovalFor).
            // --served-token-reqpath routes the bind through the SOVREQ1 request envelope the app shows and
            // the approver reads back with parseRequest — the full request->mint round-trip.
            const bindForMint = servedTokReq
              ? APPROVAL_TOOL.parseRequest(APPROVAL_TOOL.REQ_PREFIX + bind) : bind;
            let tok = APPROVAL_TOOL.mint({ bindStr: bindForMint, seedHex: genesisApproverSeedHex() }).token;
            if (servedTokBadS) {                    // corrupt the approval sig inside the envelope
              const p = APPROVAL_TOOL.parseEnvelope(tok);
              const badSig = (p.sig[0] === '0' ? '1' : '0') + p.sig.slice(1);
              tok = APPROVAL_TOOL.buildEnvelope(p.bind, badSig);
            } else if (servedTokBadB) {             // envelope bind != this capture
              const p = APPROVAL_TOOL.parseEnvelope(tok);
              tok = APPROVAL_TOOL.buildEnvelope(p.bind + '-X', p.sig);
            }
            // APP SIDE: parse + the fail-fast bind check (mirror of PersonhoodClient.parseApprovalToken).
            const parsed = APPROVAL_TOOL.parseEnvelope(tok);
            if (parsed.bind !== bind) { console.log('TOKEN_REJECTED_LOCALLY approval is for a different capture'); process.exit(3); }
            evidence = { path: 'genesis', approval: parsed.sig };
          }
          else              evidence = { path: 'genesis',  approval:  servedGenuine ? genesisApprovalFor(cap) : '' };
          send({ op: 'ZA', sovereignId: id, publicKey: pub, embedding: palmJson, face_embedding: faceJson, evidence });
          return;
        }
        if (process.argv.includes('--noattest')) {
          /* no attestation */
        } else if (ri > 0) {
          const victim = process.argv[ri + 1];
          const vcap = { sovereignId: identity(victim).id, publicKey: identity(victim).pub,
                         palmJson: JSON.stringify(unit('palm:' + victim, 128)), faceJson: JSON.stringify(unit('face:' + victim, 192)) };
          const r = issueViaGenesis(vcap, true);                 // a VALID attestation, but over the wrong capture
          if (r.ok) msg.attestation = r.attestation;
        } else if (process.argv.includes('--pathA-noapproval')) {
          const r = issueViaGenesis(cap, false);
          if (r.ok) msg.attestation = r.attestation; else process.stderr.write('SIGNER_REFUSED ' + r.reason + '\n');
        } else if (process.argv.includes('--pathA')) {
          const r = issueViaGenesis(cap, true);
          if (r.ok) msg.attestation = r.attestation; else process.stderr.write('SIGNER_REFUSED ' + r.reason + '\n');
        } else {
          msg.attestation = attest(id, pub, palmJson, faceJson);
        }
        // ── LIVENESS (PAD) round-trip, when requested — do it BEFORE the enrol register ──────────────
        //   --liveness        : a genuine live response (region brightness tracks the node's sequence) -> PASS
        //   --liveness-bad    : a flat response (still photo / fixed screen) -> node verdicts failFlat, no pass
        //   --liveness-skip   : send the enrol with NO liveness at all -> enrol gate refuses LIVENESS_REQUIRED
        // The binding is the SAME personhood binding the enrol gate recomputes from this capture.
        if (process.argv.includes('--liveness') || process.argv.includes('--liveness-bad')) {
          pendingPalm = msg;
          livenessBinding = require(SRC + '/security/personhood').binding(id, pub, palmJson, faceJson);
          send({ op: 'ZC', sovereignId: id, binding: livenessBinding });
          return;
        }
        send(msg);
      } else if (t === 'ZB') {                 // served mode: the node authority's ATTESTATION_RESULT
        if (m.ok && m.attestation) pendingPalm.attestation = m.attestation;
        else process.stderr.write('NODE_SIGNER_REFUSED ' + (m.reason || '?') + '\n');
        send(pendingPalm);                     // enrol with it (genuine) or without it (attacker -> gate refuses)
      } else if (t === 'ZD') {                 // liveness: the node's one-time challenge (nonce + sequence)
        if (!m.ok) { process.stderr.write('PAD_CHALLENGE_REFUSED ' + (m.reason || '?') + '\n'); send(pendingPalm); return; }
        const bad = process.argv.includes('--liveness-bad');
        const samples = [];
        for (const e of m.sequence) for (let k = 0; k < 2; k++) {
          // live: region tracks the light (y = 0.5*emitted + 0.1); bad: flat region (fails failFlat)
          samples.push(bad ? { emitted: e, faceLuma: 0.5, bgLuma: 0.2 }
                           : { emitted: e, faceLuma: 0.30 + 0.50 * e, bgLuma: 0.20 });
        }
        send({ op: 'ZE', sovereignId: id, nonceHex: m.nonceHex, bindingHex: livenessBinding, samples });
      } else if (t === 'ZF') {                 // liveness: the node's verdict — then enrol either way
        if (!m.ok) process.stderr.write('PAD_FAILED ' + (m.reason || m.verdict || '?') + '\n');
        send(pendingPalm);                     // pass -> gate admits; fail -> gate refuses LIVENESS_REQUIRED
      } else if (t === 'PALM_EMBEDDING_RESULT') {
        clearTimeout(timer);
        done({ id, success: !!m.success, error: m.error || null, enrollment_sov: m.enrollment_sov });
      }
    });
  });
}

function info(port) {
  return new Promise((resolve) => {
    http.get({ host: '127.0.0.1', port, path: '/node-info', timeout: 10000 }, (res) => {
      let b = ''; res.on('data', d => b += d); res.on('end', () => { try { resolve(JSON.parse(b)); } catch (_) { resolve({ raw: b.slice(0, 200) }); } });
    }).on('error', (e) => resolve({ error: e.code }));
  });
}

// ── Ledger tests (2026-10-08, docs/ledger/SOV_LEDGER_V2_DESIGN.md phase A) ───────────────────
// Transfers are SIGNED like the app's (1.4.93: nodes refuse unsigned transfers, D29).
function balance(port, name) {          // log in as <name> (test key) and read its own balance on THIS node
  return new Promise((resolve) => {
    const t = setTimeout(() => resolve(null), 15000);
    const ws = hello(port, name, (w) => {
      w._onMsg = (m) => { if ((m.type || '') === 'SOV_BALANCE_RESULT' || m.op === 'BR') { clearTimeout(t); try { w.close(); } catch (_) {}
        resolve(m.success === false ? m.error : m.balance_seeds); } };
      w.send(JSON.stringify({ type: 'BALANCE_QUERY' }));
    });
    ws.on('error', () => { clearTimeout(t); resolve(null); });
  });
}
function transfer(w, me, to, seeds, txNonce) {   // one SOV_TRANSFER on an open session -> result frame
  return new Promise((resolve) => {
    const tx_id = 'ds-' + crypto.randomBytes(6).toString('hex');
    const t = setTimeout(() => resolve({ tx_id, error: 'TIMEOUT' }), 20000);
    const prev = w._onMsg;
    w._onMsg = (m) => { if ((m.type || '') === 'SOV_TRANSFER_RESULT' || m.op === 'SR') { clearTimeout(t); w._onMsg = prev;
        resolve({ tx_id, success: !!m.success, error: m.error || null, expected_nonce: m.expected_nonce }); } else if (prev) prev(m); };
    // 1.4.93 (D29): nodes REFUSE an unsigned transfer, so sign exactly like the app/CLI
    // (KeyManager.signMessage): hash the message without nonce/signature, sign
    // "<id>|<counter>|<timestamp>|<type>|<hash>", then add the counter and the signature.
    const msg = { type: 'SOV_TRANSFER', op: 'ST', from_sovereign_id: me.id, to_sovereign_id: to, amount_seeds: seeds,
      tx_id, tx_nonce: txNonce, node_id: me.id, timestamp: Date.now() };
    const counter = Date.now();
    const hash = crypto.createHash('sha256').update(JSON.stringify(msg), 'utf8').digest('hex');
    msg.nonce = counter;
    msg.signature = me.sign(`${me.id}|${counter}|${msg.timestamp}|${msg.type}|${hash}`);
    w.send(JSON.stringify(msg));
  });
}
// 1.4.94 (D53): the claim keypair the app derives from the claim key (ed25519 from a seed). The node
// stores only the public key; a claim proves possession of the key by signing, so the public key leaks nothing.
function allocKeypair(claimKey) {
  const seed = crypto.createHash('sha256').update('SOV-ALLOC-CLAIM-v1|' + claimKey).digest();
  const priv = crypto.createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), seed]), format: 'der', type: 'pkcs8' });
  const pub = crypto.createPublicKey(priv).export({ type: 'spki', format: 'der' }).subarray(-32).toString('hex');
  return { pub, sign: (msg) => crypto.sign(null, Buffer.from(msg, 'utf8'), priv).toString('hex') };
}
const allocClaimString = (pub, claimant, ts) => `SOV-ALLOC-CLAIM-v1|${String(pub).toLowerCase()}|${claimant}|${ts}`;

// one request on an open session -> the first frame whose type/op is in `want`
function rpc(w, sendObj, want) {
  return new Promise((resolve) => {
    const t = setTimeout(() => resolve({ error: 'TIMEOUT' }), 20000);
    const prev = w._onMsg;
    w._onMsg = (m) => {
      const ty = m.type || m.op || '';
      if (want.includes(ty)) { clearTimeout(t); w._onMsg = prev; resolve(m); }
      else if (prev) prev(m);
    };
    w.send(JSON.stringify(sendObj));
  });
}

const session = (port, name) => new Promise((res) => hello(port, name, (w, me) => res({ w, me })));

(async () => {
  const [cmd, a, b] = process.argv.slice(2);
  if (cmd === 'idof') { console.log(identity(a).id); process.exit(0); }             // the deterministic SOV id of a test name
  if (cmd === 'attest-root') { console.log(attestRootPubHex()); process.exit(0); }  // the bare test attestation root pubkey
  if (cmd === 'attest-root-A') { console.log(pathARootHex()); process.exit(0); }    // Path A: the genesis signing backend's root
  if (cmd === 'signer-check') {   // signer-check <0|1 withApproval> <name> <seed>: policy teeth, no node needed
    const withApproval = a === '1'; const name = b; const seed = process.argv[5] || name;
    const me = identity(name);
    const cap = { sovereignId: me.id, publicKey: me.pub,
                  palmJson: JSON.stringify(unit('palm:' + seed, 128)), faceJson: JSON.stringify(unit('face:' + seed, 192)) };
    const r = issueViaGenesis(cap, withApproval);
    console.log(JSON.stringify(r.ok ? { ok: true, path: r.path, root: r.attestation.root } : r));
    process.exit(0);
  }
  // Increment #1 env + node-service checks ----------------------------------------------------------
  if (cmd === 'attest-seed-A')     { console.log(genesisSigningSeedHex()); process.exit(0); }  // node authority's Phase-0 signing seed
  if (cmd === 'attest-approver-A') { console.log(genesisApproverPubHex()); process.exit(0); }  // the genesis approver pubkey the node expects
  if (cmd === 'service-check') {   // service-check <hasSeed 0|1> <withApproval 0|1> <name> [seed]: the NODE service wrapper, no node up
    const hasSeed = a === '1'; const withApproval = process.argv[4] === '1';
    const name = process.argv[5]; const seed = process.argv[6] || name;
    if (hasSeed) process.env.SOV_ATTESTATION_SIGN_SEED = genesisSigningSeedHex(); else delete process.env.SOV_ATTESTATION_SIGN_SEED;
    process.env.SOV_GENESIS_APPROVER = genesisApproverPubHex();
    const me = identity(name);
    const palmJson = JSON.stringify(unit('palm:' + seed, 128)), faceJson = JSON.stringify(unit('face:' + seed, 192));
    const cap = { sovereignId: me.id, publicKey: me.pub, palmJson, faceJson };
    const stubDb = { getGovParam: (k, d) => d, grantVesting: () => 0,
                     _db: { prepare: () => ({ all: () => [], get: () => undefined }) } };
    const { AttestationService } = require(SRC + '/security/attestation_service');
    const svc = new AttestationService({ nodeId: 'test' }, stubDb);
    let out = null; const fakeWs = { send: (s) => { out = JSON.parse(s); } };
    svc.handleAttestationRequest(fakeWs, {
      sovereignId: me.id, publicKey: me.pub, embedding: palmJson, face_embedding: faceJson,
      evidence: { path: 'genesis', approval: withApproval ? genesisApprovalFor(cap) : '' } });
    console.log(JSON.stringify(out && out.ok ? { ok: true, path: out.path, root: out.attestation.root } : out));
    process.exit(0);
  }
  if (cmd === 'bal') {                  // bal <port> <name...>: balance (seeds) of each test citizen as THIS node sees it
    const out = {}; for (const id of process.argv.slice(4)) out[id] = await balance(+a, id);
    console.log(JSON.stringify({ port: +a, ...out })); process.exit(0);
  }
  // xreq <port> <name> <op-type> <json>: one exchange request, print the first reply frame for it
  //   op-type: EXCHANGE_FILL_ORDER | EXCHANGE_CONFIRM | EXCHANGE_CANCEL_ORDER | EXCHANGE_LIST_ORDER
  if (cmd === 'xreq') {
    const [name, type, json] = process.argv.slice(4);
    const want = { EXCHANGE_FILL_ORDER: ['XF', 'EXCHANGE_ORDER_FILLED'], EXCHANGE_CONFIRM: ['XC', 'EXCHANGE_DELIVERY_CONFIRMED'],
                   EXCHANGE_CANCEL_ORDER: ['XX', 'EXCHANGE_ORDER_CANCELLED'], EXCHANGE_LIST_ORDER: ['XD', 'EXCHANGE_ORDER_LISTED'],
                   // 1.4.97 governance (scenario_governance.sh)
                   POLL_CREATE: ['PJ', 'POLL_CREATED'], POLL_VOTE: ['PQ', 'POLL_VOTE_RECORDED'],
                   PETITION_CREATE: ['ED', 'PETITION_RESULT'], PETITION_SIGN: ['ES', 'PETITION_SIGN_RESULT'] }[type];
    const S = await session(+a, name);
    const t = setTimeout(() => { console.log(JSON.stringify({ error: 'TIMEOUT' })); process.exit(1); }, 25000);
    S.w._onMsg = (m) => { if (m.op === want[0] || m.type === want[1]) { clearTimeout(t); if (m.order) { m.order_id = m.order.order_id; delete m.order; } console.log(JSON.stringify(m)); process.exit(0); } };
    S.w.send(JSON.stringify({ type, ...JSON.parse(json || '{}') }));
    return;
  }
  // race <portA> <portB> <name> <toId> <sov>: the SAME citizen lists <sov> on A and transfers <sov> on B at once
  if (cmd === 'race') {
    const [name, to, sov] = process.argv.slice(5); const seeds = Math.round(Number(sov) * 1e6);
    const A = await session(+a, name), B = await session(+b, name);
    const p = await transfer(B.w, B.me, to, 1, 999999999);
    const listed = new Promise((res) => { const t = setTimeout(() => res({ error: 'TIMEOUT' }), 25000);
      A.w._onMsg = (m) => { if (m.op === 'XD' || m.type === 'EXCHANGE_ORDER_LISTED') { clearTimeout(t); res({ success: !!m.success, error: m.error || null }); } }; });
    A.w.send(JSON.stringify({ type: 'EXCHANGE_LIST_ORDER', sov_amount: seeds, memo: 'race', payment_method: 'Bank transfer', expires_in_days: 1 }));
    const [rl, rt] = await Promise.all([listed, transfer(B.w, B.me, to, seeds, p.expected_nonce)]);
    console.log(JSON.stringify({ list: rl, transfer: rt })); process.exit(0);
  }
  if (cmd === 'txu') {                  // txu <port> <name> <to> <sov>: an UNSIGNED transfer (1.4.93 D29: must be refused)
    const [name, to, sov] = process.argv.slice(4);
    const S = await session(+a, name);
    const r = await new Promise((resolve) => {
      const t = setTimeout(() => resolve({ error: 'TIMEOUT' }), 15000);
      S.w._onMsg = (m) => { if ((m.type || '') === 'SOV_TRANSFER_RESULT' || m.op === 'SR') { clearTimeout(t); resolve({ success: !!m.success, error: m.error || null }); } };
      // complete in every way EXCEPT a valid signature (a counter is present, the signature is garbage)
      S.w.send(JSON.stringify({ type: 'SOV_TRANSFER', op: 'ST', from_sovereign_id: S.me.id, to_sovereign_id: to,
        amount_seeds: Math.round(Number(sov) * 1e6), tx_id: 'u-' + crypto.randomBytes(5).toString('hex'), tx_nonce: 0,
        node_id: S.me.id, timestamp: Date.now(), nonce: Date.now(), signature: '00'.repeat(64) }));
    });
    console.log(JSON.stringify(r)); process.exit(0);
  }
  if (cmd === 'tx') {                   // tx <port> <name> <to> <sov> [nonce]: one transfer; nonce = what THIS node expects
    const [name, to, sov, nonceArg] = process.argv.slice(4); const seeds = Math.round(Number(sov) * 1e6);
    const S = await session(+a, name);
    let n = nonceArg ? +nonceArg : null;
    if (n == null) { const p = await transfer(S.w, S.me, to, 1, 999999999); n = p.expected_nonce; }
    if (n == null) { console.log(JSON.stringify({ error: 'NO_EXPECTED_NONCE' })); process.exit(1); }
    console.log(JSON.stringify({ nonce: n, ...(await transfer(S.w, S.me, to, seeds, n)) })); process.exit(0);
  }
  if (cmd === 'ds') {                   // ds <portA> <portB> <name> <toX> <toY> <sov>: same citizen, same nonce, two nodes, same instant
    const name = process.argv[5]; const [toX, toY, sov] = process.argv.slice(6); const seeds = Math.round(Number(sov) * 1e6);
    if (!name || !toX || !toY || !(seeds > 0)) { console.log(JSON.stringify({ error: 'BAD_ARGS', name, toX, toY, seeds })); process.exit(2); }
    const A = await session(+a, name), B = await session(+b, name);
    const probe = await transfer(A.w, A.me, toX, 1, 999999999);            // learn the expected nonce
    const n = probe.expected_nonce;
    if (n == null) { console.log(JSON.stringify({ error: 'NO_EXPECTED_NONCE', probe })); process.exit(1); }
    const [rX, rY] = await Promise.all([transfer(A.w, A.me, toX, seeds, n), transfer(B.w, B.me, toY, seeds, n)]);
    console.log(JSON.stringify({ nonce: n, via_A: rX, via_B: rY })); process.exit(0);
  }
  if (cmd === 'alloc-create') {        // alloc-create <port> <donor> <sov> <claimkey> [releaseEpochSec]
    const [donor, sov, claimkey, rel] = process.argv.slice(4);
    const seeds = Math.round(Number(sov) * 1e6);
    const kp = allocKeypair(claimkey);
    const S = await session(+a, donor);
    const r = await rpc(S.w, { type: 'ALLOCATION_CREATE', op: 'OC',
      beneficiary_name_hash: crypto.createHash('sha256').update('ben:' + claimkey).digest('hex'),
      beneficiary_name_encrypted: 'enc', amount_seeds: seeds,
      release_date: rel ? +rel : Math.floor(Date.now() / 1000) - 10, claim_pubkey: kp.pub },
      ['ALLOCATION_CREATED', 'OCR']);
    console.log(JSON.stringify(r)); process.exit(0);
  }
  if (cmd === 'alloc-claim') {         // alloc-claim <port> <claimant> <alloc_id> <claimkey> [--pubkeyonly]
    const [claimant, allocId, claimkey] = process.argv.slice(4);
    const S = await session(+a, claimant);
    const ts = Date.now();
    const kp = allocKeypair(claimkey);
    // --pubkeyonly: an attacker who only saw the (public) claim pubkey tries to claim with no real key
    const sig = process.argv.includes('--pubkeyonly') ? 'ab'.repeat(64) : kp.sign(allocClaimString(kp.pub, S.me.id, ts));
    const r = await rpc(S.w, { type: 'ALLOCATION_CLAIM_STAGE1', op: 'O1', claim_pubkey: kp.pub, claim_sig: sig, claim_ts: ts },
      ['ALLOCATION_CLAIMED', 'O1R']);
    console.log(JSON.stringify(r)); process.exit(0);
  }
  if (cmd === 'alloc-cancel') {        // alloc-cancel <port> <donor> <alloc_id>
    const [donor, allocId] = process.argv.slice(4);
    const S = await session(+a, donor);
    const r = await rpc(S.w, { type: 'ALLOCATION_CANCEL', op: 'OX', allocation_id: allocId }, ['ALLOCATION_CANCELLED', 'OXR']);
    console.log(JSON.stringify(r)); process.exit(0);
  }
  if (cmd === 'alloc-list') {          // alloc-list <port> <donor>: status of this donor's allocations on THIS node
    const S = await session(+a, b);
    const r = await rpc(S.w, { type: 'ALLOCATION_LIST', op: 'OL' }, ['ALLOCATION_LIST_RESULT', 'OLR']);
    console.log(JSON.stringify(r)); process.exit(0);
  }
  if (cmd === 'enroll') console.log(JSON.stringify(await enroll(+a, b, process.argv.includes('--face'))));
  else if (cmd === 'listen') {          // listen <port> <name> <seconds>: print every incoming message
    const secs = +(process.argv[5] || 30);
    const ws = hello(+a, b, (w, me) => { console.log(JSON.stringify({ listening: me.id }));
      const onIn = async (m) => {
        const t = m.type || m.op || '';
        let kind = null, from = '', env = '';
        if (t === 'MESSAGE_INCOMING' || t === 'MI') { kind = 'dm'; from = m.from_sovereign_id; env = m.encrypted_payload; }
        else if (t === 'GROUP_MESSAGE_INCOMING' || t === 'GM') { kind = 'group'; from = m.sender_id; env = m.content; }
        else if (t === 'EXCHANGE_CHAT_INCOMING' || t === 'XI') { kind = 'trade'; from = m.from_id; env = m.content; }
        if (!kind) return;
        let text = null; let v = 1; try { v = JSON.parse(env).v || 1; } catch (_) {}
        if (v === 2) { const k = await keyOf(w, from); text = k ? decryptV2(me.x, k, env) : null; w._onMsg = onIn; }
        console.log(JSON.stringify({ kind, received: String(env).slice(0, 60), from, v, text, group_id: m.group_id, order_id: m.order_id })); };
      w._onMsg = onIn; });
    setTimeout(() => { try { ws.close(); } catch (_) {} process.exit(0); }, secs * 1000);
  } else if (cmd === 'list') {          // list <port> <name> <sov> <memo>: list SOV on the exchange
    const [sov, memo] = process.argv.slice(5);
    hello(+a, b, (w) => {
      w._onMsg = (m) => { if ((m.type || '') === 'EXCHANGE_ORDER_LISTED' || (m.op === 'XD')) { console.log(JSON.stringify({ success: m.success, order_id: m.order && m.order.order_id, error: m.error || null })); w.close(); process.exit(0); } };
      w.send(JSON.stringify({ type: 'EXCHANGE_LIST_ORDER', sov_amount: Math.round(Number(sov) * 1e6), memo, payment_method: 'Bank transfer', expires_in_days: 1 }));
    });
    setTimeout(() => { console.log(JSON.stringify({ error: 'TIMEOUT' })); process.exit(1); }, 20000);
  } else if (cmd === 'browse') {        // browse <port> <name>: the open orders this node shows
    hello(+a, b, (w) => {
      w._onMsg = (m) => { if ((m.type || '') === 'EXCHANGE_STATE') { console.log(JSON.stringify((m.orders || []).map(o => ({ order_id: o.order_id, memo: o.memo || o.asking_description || '', seller: o.seller_id })))); w.close(); process.exit(0); } };
      w.send(JSON.stringify({ type: 'EXCHANGE_SUBSCRIBE' }));
    });
    setTimeout(() => { console.log(JSON.stringify({ error: 'TIMEOUT' })); process.exit(1); }, 20000);
  } else if (cmd === 'msg') {           // msg <port> <name> <toId> <text>
    const [to, textv] = process.argv.slice(5);
    const ws = hello(+a, b, async (w, me) => {
      const id = 'mesh' + crypto.randomBytes(8).toString('hex');
      let payload = textv;
      if (process.argv.includes('--e2e')) {
        const k = await keyOf(w, to);
        if (!k) { console.log(JSON.stringify({ error: 'NO_RECIPIENT_KEY' })); process.exit(1); }
        payload = encryptV2(me.x, k, textv);
      }
      w._onMsg = (m) => { if ((m.type || '') === 'MESSAGE_SEND_RESULT') { console.log(JSON.stringify({ success: m.success, status: m.status, error: m.error || null, message_id: id })); w.close(); process.exit(0); } };
      w.send(JSON.stringify({ type: 'MESSAGE_SEND', message_id: id, to_sovereign_id: to, encrypted_payload: payload, message_type: 'text', sent_at: Date.now() }));
    });
    setTimeout(() => { console.log(JSON.stringify({ error: 'TIMEOUT' })); process.exit(1); }, 20000);
  }
  else if (cmd === 'hijack') {         // hijack <port> <victimId> <attackerName>: UNSIGNED HELLO claiming victimId (D36 probe)
    const [victim, attacker] = [b, process.argv[5]]; const me = identity(attacker);
    const ws = new WebSocket(`ws://127.0.0.1:${a}`);
    const t = setTimeout(() => { console.log(JSON.stringify({ result: 'TIMEOUT' })); process.exit(0); }, 10000);
    ws.on('open', () => ws.send(JSON.stringify({ type: 'HELLO', sovereign_id: victim, public_key: me.pub, messaging_public_key: me.x.pub })));
    ws.on('message', (raw) => { let m; try { m = JSON.parse(raw); } catch (_) { return; }
      const ty = m.type || m.op; if (ty === 'HELLO_ACK' || ty === 'HA' || ty === 'ERROR' || m.code) { clearTimeout(t);
        console.log(JSON.stringify({ result: (ty === 'HELLO_ACK' || ty === 'HA') ? 'ACCEPTED' : 'REFUSED', code: m.code || null, attacker_xkey: me.x.pub })); process.exit(0); } });
    ws.on('close', (c, r) => { clearTimeout(t); console.log(JSON.stringify({ result: 'REFUSED', close: c, reason: String(r || ''), attacker_xkey: me.x.pub })); process.exit(0); });
  }
  else if (cmd === 'pk') {             // pk <port> <askerName> <targetId>: the messaging key the node publishes for targetId
    hello(+a, b, async (w) => { const k = await keyOf(w, process.argv[5]); console.log(JSON.stringify({ key: k })); process.exit(0); });
    setTimeout(() => { console.log(JSON.stringify({ error: 'TIMEOUT' })); process.exit(1); }, 15000);
  }
  else if (cmd === 'rlist') {          // rlist <port> <name>: the node list a signed-in citizen is given (RELAY_LIST)
    hello(+a, b, (w) => {
      w.on('message', (raw) => { let m; try { m = JSON.parse(raw); } catch (_) { return; }
        if (m.type === 'RELAY_LIST_RESPONSE' || m.op === 'RS') { console.log(JSON.stringify({ ips: (m.relays || []).map(r => r.ip) })); process.exit(0); } });
      w.send(JSON.stringify({ op: 'RN' }));
    });
    setTimeout(() => { console.log(JSON.stringify({ error: 'TIMEOUT' })); process.exit(1); }, 15000);
  }
  else if (cmd === 'enroll-en') {      // enroll-en <port>: the RETIRED 'EN' route (1.4.93 D1) — print the node's answer
    const ws = new WebSocket(`ws://127.0.0.1:${a}`);
    const t = setTimeout(() => { console.log(JSON.stringify({ error: 'TIMEOUT' })); process.exit(0); }, 10000);
    ws.on('open', () => ws.send(JSON.stringify({ op: 'EN', embedding_commitment: 'ab'.repeat(32), helper_data: { slot_a: '00', slot_b: '00', slot_c: '00' },
      public_key_hex: 'cd'.repeat(32), mcc: '234', timestamp: Date.now() })));
    ws.on('message', (raw) => { let m = {}; try { m = JSON.parse(raw); } catch (_) {}
      if (m.op === 'RH' || m.type === 'RELAY_HELLO') return;   // the greeting, not the answer
      clearTimeout(t); console.log(String(raw).slice(0, 300)); process.exit(0); });
    ws.on('close', (c, r) => { clearTimeout(t); console.log(JSON.stringify({ closed: c, reason: String(r || '') })); process.exit(0); });
  }
  else if (cmd === 'enclave') {          // enclave <port> <name> <old|new>: post + reply with the app's old (content) or new (body+ids) fields
    const mode = process.argv[5] || 'new';
    hello(+a, b, (w) => {
      const id = 'ep-' + Date.now();
      const post = mode === 'old' ? { type: 'ENCLAVE_POST', channel: 'general', title: 'T', content: 'hello' }
                                  : { type: 'ENCLAVE_POST', channel: 'general', post_id: id, title: 'T', body: 'hello' };
      let step = 0;
      w._onMsg = (m) => {
        if (m.type === 'ENCLAVE_POST_RESULT' && step === 0) {
          step = 1; console.log(JSON.stringify({ post: m.success, error: m.error || null }));
          if (!m.success) process.exit(0);
          w.send(JSON.stringify({ type: 'ENCLAVE_REPLY', post_id: id, reply_id: 'er-' + Date.now(), body: 'reply' }));
        } else if (m.type === 'ENCLAVE_REPLY_RESULT') { console.log(JSON.stringify({ reply: m.success, error: m.error || null })); process.exit(0); }
      };
      w.send(JSON.stringify(post));
    });
    setTimeout(() => { console.log(JSON.stringify({ error: 'TIMEOUT' })); process.exit(1); }, 15000);
  }
  else if (cmd === 'info') console.log(JSON.stringify(await info(+a)));
  else if (cmd === 'gcreate') {        // gcreate <port> <name> <groupId> <memberId...>
    const [gid, ...mem] = process.argv.slice(5);
    hello(+a, b, (w) => {
      w._onMsg = (m) => { if ((m.type || m.op) === 'GROUP_CREATED' || m.op === 'GD') { console.log(JSON.stringify({ success: m.success, error: m.error || null, members: m.members })); w.close(); process.exit(0); } };
      w.send(JSON.stringify({ op: 'GC', group_id: gid, name: 'Mesh test group', member_ids: mem }));
    });
    setTimeout(() => { console.log(JSON.stringify({ error: 'TIMEOUT' })); process.exit(1); }, 20000);
  }
  else if (cmd === 'gsend') {          // gsend <port> <name> <groupId> <text> [--plain]: per-member E2E, as the app does
    const [gid, textv] = process.argv.slice(5);
    hello(+a, b, async (w, me) => {
      const lst = await new Promise((res) => { w._onMsg = (m) => { if ((m.type || '') === 'GROUP_LIST_RESULT' || m.op === 'GR') res(m.groups || []); };
        w.send(JSON.stringify({ op: 'GL' })); });
      const g = lst.find(x => x.group_id === gid);
      if (!g) { console.log(JSON.stringify({ error: 'GROUP_NOT_LISTED' })); process.exit(1); }
      const envelopes = {};
      if (process.argv.includes('--plain')) envelopes['*'] = textv;
      else for (const id of (g.members || []).filter(x => x !== me.id)) { const k = await keyOf(w, id); if (k) envelopes[id] = encryptV2(me.x, k, textv); }
      const id = 'gmesh' + crypto.randomBytes(8).toString('hex');
      w._onMsg = (m) => { if (m.op === 'MA' && m.msg_id === id) { console.log(JSON.stringify(m)); w.close(); process.exit(0); } };
      w.send(JSON.stringify({ op: 'GS', msg_id: id, group_id: gid, envelopes, media_type: 'text', timestamp: Date.now() }));
    });
    setTimeout(() => { console.log(JSON.stringify({ error: 'TIMEOUT' })); process.exit(1); }, 30000);
  }
  else if (cmd === 'xsend') {          // xsend <port> <name> <orderId> <toId> <text> [--plain]: trade chat, E2E
    const [oid, to, textv] = process.argv.slice(5);
    hello(+a, b, async (w, me) => {
      let content = textv;
      if (!process.argv.includes('--plain')) { const k = await keyOf(w, to); if (!k) { console.log(JSON.stringify({ error: 'NO_RECIPIENT_KEY' })); process.exit(1); } content = encryptV2(me.x, k, textv); }
      w._onMsg = (m) => { if ((m.type || '') === 'EXCHANGE_CHAT_SEND_RESULT' || m.op === 'XH') { console.log(JSON.stringify(m)); w.close(); process.exit(0); } };
      w.send(JSON.stringify({ op: 'XH', order_id: oid, to_id: to, content, msg_id: 'xmesh' + crypto.randomBytes(8).toString('hex') }));
    });
    setTimeout(() => { console.log(JSON.stringify({ error: 'TIMEOUT' })); process.exit(1); }, 30000);
  }
  else if (cmd === 'envelope') {       // envelope <port> <name> <toId> <text>: print a v2 envelope from <name> to <toId>
    const [to, textv] = process.argv.slice(5);
    hello(+a, b, async (w, me) => { const k = await keyOf(w, to);
      console.log(JSON.stringify(k ? { from: me.id, envelope: encryptV2(me.x, k, textv) } : { error: 'NO_RECIPIENT_KEY' })); w.close(); process.exit(k ? 0 : 1); });
    setTimeout(() => { console.log(JSON.stringify({ error: 'TIMEOUT' })); process.exit(1); }, 20000);
  }
  else if (cmd === 'selftest-e2e') {    // round trip + a wrong-key control
    const A = xkey('st-a'), B = xkey('st-b'), C = xkey('st-c');
    const env = encryptV2(A, B.pub, 'hello');
    console.log(JSON.stringify({ roundtrip: decryptV2(B, A.pub, env), wrong_key: decryptV2(C, A.pub, env) }));
  }
  else { console.log('usage: mesh_client.js enroll <wsPort> <personSeed> [--face] [--as <name>] | info <httpPort> | listen <wsPort> <name> <secs> | msg <wsPort> <name> <toId> <text> [--e2e] | selftest-e2e'); process.exit(2); }
})();
