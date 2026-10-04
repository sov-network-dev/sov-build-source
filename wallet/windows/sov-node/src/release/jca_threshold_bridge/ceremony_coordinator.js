'use strict';
/**
 * Network-distributed ceremony coordinator — the "real shape" successor to
 * ceremony_sign_cli.js's local-file version. Instead of reading share files off
 * this machine's disk, it fetches `threshold` shares from `threshold` SEPARATE
 * share-holder services (share_holder_service.js), each presumed to run on its
 * own custodian's machine, over HTTP (mTLS in production — see that file's
 * header and GAP1_THRESHOLD_SIGNING_STATUS.md for what's still a PoC shortcut).
 *
 * This process is still the one place the reconstructed key is briefly whole —
 * that property doesn't change by moving the shares onto the network. What DOES
 * change: no single machine holds more than one share at rest, which is the
 * actual custody property "network-derived key" is supposed to mean.
 *
 * Usage: node ceremony_coordinator.js --holdersConfig holders.json --threshold 3
 *        --alg RSA-SHA384 --msgFile msg.bin
 */
const fs = require('fs');
const http = require('http');
const { ceremonySign } = require('../../protocol/threshold_rsa_ceremony.js');

const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, arr) => {
  if (a.startsWith('--')) acc.push([a.slice(2), arr[i + 1]]);
  return acc;
}, []));

function fetchShare(holder) {
  return new Promise((resolve, reject) => {
    const req = http.request(holder.url, {
      method: 'POST',
      headers: { Authorization: `Bearer ${holder.token}` },
      timeout: 5000,
    }, (res) => {
      if (res.statusCode !== 200) { reject(new Error(`${holder.id} refused: HTTP ${res.statusCode}`)); return; }
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve(new Uint8Array(Buffer.concat(chunks))));
    });
    req.on('error', reject);
    req.on('timeout', () => req.destroy(new Error(`${holder.id} timed out`)));
    req.end();
  });
}

async function main() {
  const holders = JSON.parse(fs.readFileSync(args.holdersConfig, 'utf8'));
  const threshold = parseInt(args.threshold, 10);
  const alg = args.alg;
  const msg = fs.readFileSync(args.msgFile);

  if (holders.length < threshold) {
    throw new Error(`configured ${holders.length} holders, need at least ${threshold}`);
  }

  console.error(`[coordinator] requesting shares from ${threshold} of ${holders.length} configured holders...`);
  const subset = holders.slice(0, threshold);
  const shares = await Promise.all(subset.map((h) => fetchShare(h).then((s) => {
    console.error(`[coordinator] received share from ${h.id}`);
    return s;
  })));

  const sig = await ceremonySign(shares, alg, msg); // reconstructs, signs, discards — see threshold_rsa_ceremony.js
  process.stdout.write(sig.toString('hex'));
}

main().catch((e) => { console.error('CEREMONY_ERROR:', e.message); process.exit(1); });
