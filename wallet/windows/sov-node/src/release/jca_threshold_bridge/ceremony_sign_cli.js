'use strict';
// Called by the Java Signature SPI bridge. Reads message bytes from a file,
// reconstructs the key from a threshold of share files, signs, prints hex
// signature to stdout ONLY (so Java can parse it with zero ambiguity), and
// discards the reconstructed key when ceremonySign's `finally` runs.
const fs = require('fs');
const path = require('path');
const { ceremonySign } = require('../../protocol/threshold_rsa_ceremony.js');

const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, arr) => {
  if (a.startsWith('--')) acc.push([a.slice(2), arr[i + 1]]);
  return acc;
}, []));

async function main() {
  const sharesDir = args.sharesDir;
  const threshold = parseInt(args.threshold, 10);
  const alg = args.alg;
  const msgFile = args.msgFile;

  const shareFiles = fs.readdirSync(sharesDir).filter((f) => f.endsWith('.bin')).sort();
  const subset = shareFiles.slice(0, threshold).map((f) => new Uint8Array(fs.readFileSync(path.join(sharesDir, f))));
  const msg = fs.readFileSync(msgFile);

  const sig = await ceremonySign(subset, alg, msg);
  process.stdout.write(sig.toString('hex'));
}

main().catch((e) => { console.error('CEREMONY_ERROR:', e.message); process.exit(1); });
