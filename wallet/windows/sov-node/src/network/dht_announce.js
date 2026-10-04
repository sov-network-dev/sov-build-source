/**
 * dht_announce.js — find and be found through the public BitTorrent DHT.
 *
 * A node announces itself under an infohash derived from a constant, and looks up
 * that same infohash to learn where other nodes are. Nothing is registered with
 * anyone; every node computes the same identifier independently.
 *
 * This is the discovery path that survives losing every mirror, domain and
 * provider, because it uses infrastructure nobody owns.
 *
 * SAFETY — what this node will NOT do for strangers:
 *   BEP44 `put`/`get` (small arbitrary-data storage) are refused outright. Peer
 *   discovery does not require them and storing other people's data is not this
 *   network's business. What is still served — ping, find_node, get_peers,
 *   announce_peer — carries an address and a node id and nothing else.
 *
 * Discovered addresses are handed out as DIAL TARGETS only. They never enter the
 * pool: a node belongs there once it has been met and has passed interrogation.
 */
'use strict';
const crypto = require('crypto');

const NETWORK_ID  = process.env.SOV_DHT_NETWORK || 'sov-network-mainnet-v1';
const INFOHASH    = crypto.createHash('sha1').update(NETWORK_ID).digest();
const CYCLE_MS    = 15 * 60 * 1000;   // maintenance re-announce (well inside expiry)
const WARMUP_MS   = 12 * 1000;        // fast retry until the FIRST announce lands
const MAX_PEERS   = 200;

class DhtAnnouncer {
  constructor(peerPort, isReachable) {
    this._peerPort = peerPort || 7771;
    // reach-probe-v1: the DHT records the address we announce FROM, so a node
    // behind carrier NAT that announces puts an unreachable address into a
    // global public index other nodes then waste dials on. Absent predicate =
    // assume reachable, so older callers behave as before.
    this._isReachable = typeof isReachable === "function" ? isReachable : () => true;
    this._warnedUnverified = false;
    this._dht      = null;
    this._peers    = new Map();      // "host:port" -> lastSeen
    this._timer    = null;
    this._refused  = { put: 0, get: 0 };
  }

  /** Addresses learned from the DHT, freshest first. Dial targets, not nodes. */
  peers(limit = 20) {
    return [...this._peers.entries()]
      .sort((a, b) => b[1] - a[1])
      .slice(0, limit)
      .map(([addr]) => addr);
  }

  /**
   * Does this address actually look like a SOV node?
   *
   * Anyone may announce under any infohash, and crawlers routinely announce under
   * all of them — a soak found three unrelated machines listed under ours within
   * hours. Nothing is compromised by that, because a stranger still has to pass
   * the full join checks, but dialling them wastes a mesh handshake apiece.
   *
   * One cheap HTTP call filters them: a real node serves its pool, a crawler does
   * not. This is a courtesy filter, NOT a security check — passing it earns
   * nothing, and the real gate remains operator identity, source agreement and
   * the ledger.
   */
  async looksLikeSovNode(hostPort, timeoutMs = 4000) {
    const host = String(hostPort).split(':')[0];
    return new Promise((resolve) => {
      let done = false;
      const finish = (v) => { if (!done) { done = true; resolve(v); } };
      try {
        const http = require('http');
        const req = http.get({ host, port: 80, path: '/relay-pool', timeout: timeoutMs },
          (res) => {
            if (res.statusCode !== 200) { res.resume(); return finish(false); }
            let body = '';
            res.setEncoding('utf8');
            res.on('data', (c) => { body += c; if (body.length > 65536) req.destroy(); });
            res.on('end', () => {
              try {
                const j = JSON.parse(body);
                finish(Array.isArray((j.payload || j).nodes));
              } catch (_) { finish(false); }
            });
          });
        req.on('error', () => finish(false));
        req.on('timeout', () => { try { req.destroy(); } catch (_) {} finish(false); });
      } catch (_) { finish(false); }
      setTimeout(() => finish(false), timeoutMs + 500);
    });
  }

  /** DHT peers that answered as SOV nodes. Falls back to unfiltered on error. */
  async verifiedPeers(limit = 10) {
    const candidates = this.peers(limit * 3);
    const good = [];
    for (const addr of candidates) {
      if (good.length >= limit) break;
      try { if (await this.looksLikeSovNode(addr)) good.push(addr); } catch (_) {}
    }
    return good;
  }

  stats() {
    return { peers: this._peers.size, refused: { ...this._refused },
             infohash: INFOHASH.toString('hex') };
  }

  async start() {
    let DHT;
    try {
      // The library is ESM-only; this codebase is CommonJS.
      ({ default: DHT } = await import('bittorrent-dht'));
    } catch (e) {
      global.sovLog.warn('      DHT unavailable (' + e.message + ') — other discovery paths still apply');
      return false;
    }

    try {
      const dht = new DHT();

      // Refuse storage BEFORE the socket opens, so no request is ever served.
      // A refusal is an ordinary DHT response: the asker simply tries elsewhere
      // and our participation in discovery is unaffected.
      const proto = Object.getPrototypeOf(dht);
      const self  = this;
      if (typeof proto._onput === 'function') {
        proto._onput = function (query, peer) {
          self._refused.put++;
          try { this._rpc.error(peer, query, [203, 'storage not offered']); } catch (_) {}
        };
      }
      if (typeof proto._onget === 'function') {
        proto._onget = function (query, peer) {
          self._refused.get++;
          try { this._rpc.error(peer, query, [203, 'storage not offered']); } catch (_) {}
        };
      }

      dht.on('peer', (peer, hash) => {
        if (hash.toString('hex') !== INFOHASH.toString('hex')) return;
        if (this._peers.size >= MAX_PEERS) return;
        this._peers.set(peer.host + ':' + peer.port, Date.now());
      });
      dht.on('error', () => { /* transient UDP problems are not fatal */ });

      await new Promise((resolve) => dht.listen(0, resolve));
      this._dht = dht;

      // The FIRST announce fires the instant the socket binds — BEFORE the DHT has
      // bootstrapped (found nodes) — so it fails "No nodes to query". At the old
      // 15-minute CYCLE_MS the next attempt was 15 min away, so a LONE genesis
      // effectively never published its address and no fresh app could find it.
      // Fix: re-announce every WARMUP_MS until the announce actually lands
      // (callback returns no error), THEN settle to the slow maintenance cadence.
      let confirmed = false;
      const cycle = () => {
        try {
          // LOOKUP ALWAYS — an unverified node still needs to FIND the network;
          // that is how a fresh install bootstraps. Only PUBLISHING is gated.
          dht.lookup(INFOHASH);
          if (this._isReachable()) {
            dht.announce(INFOHASH, this._peerPort, (err) => {
              if (!err && !confirmed) {
                confirmed = true;
                if (this._timer) clearInterval(this._timer);
                this._timer = setInterval(cycle, CYCLE_MS);   // settle to maintenance
                if (this._timer.unref) this._timer.unref();
                global.sovLog.info('      ✓ DHT: announce landed — node is discoverable via the public swarm');
              }
            });
            this._warnedUnverified = false;
          } else if (!this._warnedUnverified) {
            this._warnedUnverified = true;
            global.sovLog.info("      DHT: searching but not publishing — nothing has reached this node yet.");
          }
        } catch (_) { /* keep the node running regardless */ }
      };
      cycle();
      // Warm-up cadence until the first announce confirms; cycle() then swaps this
      // timer for the CYCLE_MS maintenance timer.
      this._timer = setInterval(cycle, WARMUP_MS);
      if (this._timer.unref) this._timer.unref();

      global.sovLog.info('      ✓ DHT announce active (infohash ' +
        INFOHASH.toString('hex').slice(0, 12) + '…, storage refused)');
      return true;
    } catch (e) {
      global.sovLog.warn('      DHT start failed (' + e.message + ') — continuing');
      return false;
    }
  }

  stop() {
    if (this._timer) clearInterval(this._timer);
    if (this._dht) { try { this._dht.destroy(); } catch (_) {} }
  }
}

module.exports = { DhtAnnouncer, INFOHASH };
