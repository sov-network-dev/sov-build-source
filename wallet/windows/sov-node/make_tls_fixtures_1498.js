// make_tls_fixtures_1498.js — fixtures for the app's test/node_trust_tls_test.dart, made by the NODE'S OWN
// proof code (CitizenGateway._makeTlsProof), so the Dart test proves the app and the node agree on the
// signed bytes. Run: bash tools/test_mesh/run_unit.sh make_tls_fixtures_1498.js  (writes $SOV_FIXTURE_OUT)
'use strict';
const os = require('os'), fs = require('fs'), path = require('path'), crypto = require('crypto');
global.sovLog = { info() {}, debug() {}, warn() {}, error() {}, success() {} };
const nacl = require('tweetnacl');
const { CitizenGateway } = require('./src/network/citizen_gateway.js');
const sha = (b) => crypto.createHash('sha256').update(b).digest('hex');

function node() {
  const kp = nacl.sign.keyPair();
  const gw = Object.create(CitizenGateway.prototype);
  gw._identity = { nodeId: sha(Buffer.from(kp.publicKey)), publicKey: kp.publicKey,
    sign: (d) => Buffer.from(nacl.sign.detached(new Uint8Array(d), kp.secretKey)) };
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tlsfx-'));
  const cf = path.join(dir, 'tls', 'node.crt'), kf = path.join(dir, 'tls', 'node.key');
  gw._ensureSelfSignedCert(dir, cf, kf);
  const pem = fs.readFileSync(cf);
  return { gw, kp, proof: gw._makeTlsProof(pem), certSha: sha(new crypto.X509Certificate(pem).raw) };
}
const real = node(), stranger = node();
const hello = (p) => Object.assign({ type: 'RELAY_HELLO', op: 'RH', ts: 1791900000000 }, p);
const out = {
  trusted: [real.proof.node_pub],
  real_cert_sha: real.certSha,
  mitm_cert_sha: stranger.certSha,
  genuine: hello(real.proof),
  forged_hash: hello(Object.assign({}, real.proof, { tls_sha256: stranger.certSha })),
  stranger: hello(stranger.proof),
  wrong_id: hello(Object.assign({}, real.proof, { node_id: stranger.proof.node_id })),
  no_proof: { type: 'RELAY_HELLO', op: 'RH', ts: 1791900000000 },
};
const dest = process.env.SOV_FIXTURE_OUT || path.join(__dirname, 'tls_fixtures.json');
fs.writeFileSync(dest, JSON.stringify(out, null, 1) + '\n');
console.log('wrote ' + dest + ' — ALL PASS');
