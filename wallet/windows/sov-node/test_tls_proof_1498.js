// test_tls_proof_1498.js — node 1.4.98 (audit D83): the gateway's RELAY_HELLO carries a statement, signed
// by the node key, naming the SHA-256 of the TLS certificate it serves. This serves that certificate over
// real TLS and checks, as the app will, that what a client receives is exactly what the node signed —
// and that a middleman's certificate does not match.
// Run: bash tools/test_mesh/run_unit.sh test_tls_proof_1498.js
'use strict';
const os = require('os'), fs = require('fs'), path = require('path'), crypto = require('crypto'), tls = require('tls'), https = require('https');
global.sovLog = { info() {}, debug() {}, warn() {}, error() {}, success() {} };
const nacl = require('tweetnacl');
let pass = 0, fail = 0;
const t = (name, cond, extra) => { if (cond) { pass++; console.log('  PASS ' + name); } else { fail++; console.log('  FAIL ' + name + (extra ? ' — ' + extra : '')); } };

const { CitizenGateway } = require('./src/network/citizen_gateway.js');
const kp = nacl.sign.keyPair();
const identity = {
  nodeId: crypto.createHash('sha256').update(Buffer.from(kp.publicKey)).digest('hex'),
  publicKey: kp.publicKey,
  sign: (data) => Buffer.from(nacl.sign.detached(new Uint8Array(data), kp.secretKey)),
};
const gw = Object.create(CitizenGateway.prototype);
gw._identity = identity;

function makeCert(label) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tls1498-' + label + '-'));
  const certFile = path.join(dir, 'tls', 'node.crt'), keyFile = path.join(dir, 'tls', 'node.key');
  gw._ensureSelfSignedCert(dir, certFile, keyFile);
  return { cert: fs.readFileSync(certFile), key: fs.readFileSync(keyFile) };
}
function presented(server) {          // the DER certificate a client actually receives, hashed
  return new Promise((res, rej) => {
    const s = tls.connect({ port: server.address().port, host: '127.0.0.1', rejectUnauthorized: false }, () => {
      const der = s.getPeerCertificate(true).raw; s.end();
      res(crypto.createHash('sha256').update(der).digest('hex'));
    });
    s.on('error', rej);
  });
}
// exactly the app's check (relay_connector.dart _verifyNodeIdentity)
function appCheck(hello, seenSha, trusted) {
  if (!hello.node_pub || !hello.node_sig || !hello.tls_sha256 || !hello.node_id) return 'NO_PROOF';
  const pub = Buffer.from(hello.node_pub, 'hex');
  if (crypto.createHash('sha256').update(pub).digest('hex') !== hello.node_id) return 'ID_MISMATCH';
  const ok = nacl.sign.detached.verify(Buffer.from(`sov-node-tls-v1|${hello.node_id}|${hello.tls_sha256}`, 'utf8'),
    Buffer.from(hello.node_sig, 'hex'), pub);
  if (!ok) return 'BAD_SIGNATURE';
  if (hello.tls_sha256 !== seenSha) return 'CERT_MISMATCH';
  if (!trusted.has(hello.node_pub)) return 'NOT_TRUSTED';
  return null;
}

(async () => {
  const real = makeCert('real'), mitm = makeCert('mitm');
  const proof = gw._makeTlsProof(real.cert);
  t('proof names this node', proof.node_id === identity.nodeId && proof.node_pub === Buffer.from(kp.publicKey).toString('hex'));
  const srv = https.createServer(real).listen(0, '127.0.0.1');
  await new Promise(r => srv.once('listening', r));
  const seen = await presented(srv);
  t('the certificate a client receives is exactly the one the node signed for', seen === proof.tls_sha256, `${seen} vs ${proof.tls_sha256}`);
  const trusted = new Set([proof.node_pub]);
  const hello = Object.assign({ type: 'RELAY_HELLO', op: 'RH', ts: Date.now() }, proof);
  t('app check passes on the genuine node', appCheck(hello, seen, trusted) === null, appCheck(hello, seen, trusted));

  const mitmSrv = https.createServer(mitm).listen(0, '127.0.0.1');
  await new Promise(r => mitmSrv.once('listening', r));
  const seenMitm = await presented(mitmSrv);
  t('middleman relaying the genuine proof is caught (certificate mismatch)', appCheck(hello, seenMitm, trusted) === 'CERT_MISMATCH');
  const forged = Object.assign({}, hello, { tls_sha256: seenMitm });
  t('middleman rewriting the hash breaks the signature', appCheck(forged, seenMitm, trusted) === 'BAD_SIGNATURE');
  const own = nacl.sign.keyPair(); const ownPub = Buffer.from(own.publicKey).toString('hex');
  const ownId = crypto.createHash('sha256').update(Buffer.from(own.publicKey)).digest('hex');
  const selfSigned = { node_id: ownId, node_pub: ownPub, tls_sha256: seenMitm,
    node_sig: Buffer.from(nacl.sign.detached(Buffer.from(`sov-node-tls-v1|${ownId}|${seenMitm}`), own.secretKey)).toString('hex') };
  t('middleman signing with his own key is not trusted', appCheck(selfSigned, seenMitm, trusted) === 'NOT_TRUSTED');
  t('a greeting with no proof is refused', appCheck({ type: 'RELAY_HELLO' }, seen, trusted) === 'NO_PROOF');
  const wrongId = Object.assign({}, hello, { node_id: ownId });
  t('a key that does not hash to the claimed node id is refused', appCheck(wrongId, seen, trusted) === 'ID_MISMATCH');
  srv.close(); mitmSrv.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  console.log(fail ? 'SOME FAILED' : 'ALL PASS');
  process.exit(fail ? 1 : 0);
})().catch(e => { console.log('ERROR ' + e.stack); process.exit(1); });
