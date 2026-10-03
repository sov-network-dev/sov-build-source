'use strict';
/**
 * One custodian's share-holder service. Run one of these per custodian machine.
 * Holds exactly ONE Shamir share (never the whole key, never another holder's
 * share) and serves it ONLY on an authenticated request from a ceremony
 * coordinator, over `/share`.
 *
 * PoC auth: a per-holder bearer token (shared secret, out-of-band distributed).
 * NOT production-grade — a real deployment needs mutual TLS (each holder and the
 * coordinator present a certificate) so a stolen bearer token alone can't pull a
 * share, and so the holder knows it's really talking to the coordinator and not
 * an impersonator. Said here explicitly so a bearer-token shortcut doesn't
 * quietly become the assumed final design — see GAP1_THRESHOLD_SIGNING_STATUS.
 *
 * Usage: node share_holder_service.js --port 4001 --shareFile shares/share_0.bin --token <secret>
 */
const http = require('http');
const fs = require('fs');

const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, arr) => {
  if (a.startsWith('--')) acc.push([a.slice(2), arr[i + 1]]);
  return acc;
}, []));

const PORT = parseInt(args.port, 10);
const SHARE = fs.readFileSync(args.shareFile); // held in memory for this process's lifetime only
const TOKEN = args.token;
const HOLDER_ID = args.holderId || `holder-${PORT}`;

const server = http.createServer((req, res) => {
  if (req.method !== 'POST' || req.url !== '/share') {
    res.writeHead(404).end();
    return;
  }
  const auth = req.headers.authorization || '';
  if (auth !== `Bearer ${TOKEN}`) {
    console.log(`[${HOLDER_ID}] REFUSED unauthenticated share request`);
    res.writeHead(403).end('forbidden');
    return;
  }
  // Real deployment: also check a signed, time-boxed ceremony ID from the
  // coordinator, and log/rate-limit — a holder that hands out its share on any
  // authenticated ping is a standing single point of compromise for its own
  // share, even though no ONE share is enough to sign alone.
  console.log(`[${HOLDER_ID}] serving share for an authenticated ceremony request`);
  res.writeHead(200, { 'Content-Type': 'application/octet-stream' }).end(SHARE);
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[${HOLDER_ID}] share-holder service up on 127.0.0.1:${PORT}`);
});
