// ─────────────────────────────────────────────────────────────────────────────
// NETWORK MANAGER — Automatic network configuration
// ─────────────────────────────────────────────────────────────────────────────
// Handles everything needed to make a home computer publicly reachable:
//   1. Detect public IP address
//   2. Detect NAT type (open / full-cone / restricted / symmetric / CGNAT)
//   3. Attempt UPnP port forwarding (works on ~75% of home routers)
//   4. Fall back to NAT hole punching via STUN
//   5. Fall back to circuit relay registration with peer nodes
//   6. Monitor IP changes every 5 minutes — broadcast update on change
// ─────────────────────────────────────────────────────────────────────────────

'use strict';

const upnp   = require('nat-upnp');
const stun   = require('stun');
const https  = require('https');
const http   = require('http');

const SOV_PORT      = parseInt(process.env.SOV_PORT  || '443');
const SYNC_PORT     = parseInt(process.env.SYNC_PORT || '7771');
const IP_CHECK_INTERVAL = 5 * 60 * 1000; // 5 minutes

class NetworkManager {

  constructor({ publicAddress, natType, reachabilityMethod, upnpClient }) {
    this.publicAddress      = publicAddress;
    this.natType            = natType;
    this.reachabilityMethod = reachabilityMethod;
    this._upnpClient        = upnpClient;
    this._lastKnownIP       = publicAddress ? publicAddress.split(':')[0] : null;
    this._ipMonitor         = null;
    this._onIPChange        = null; // set by PeerMesh after start

    // reachability-proof-v1 — see markInboundVerified() below.
    // A method ending in '-unverified' means: we believe we have this address,
    // but nothing has ever reached us at it. Such an address is NOT advertised.
    this.inboundVerified = !String(reachabilityMethod || '').endsWith('-unverified');
    this.verifiedAt      = this.inboundVerified ? Date.now() : null;
  }

  // ── reachability-proof-v1 ──────────────────────────────────────────────────
  // The address we are willing to publish to the pool and to citizens.
  //
  // Returns '' while unverified. Advertising an address nothing can reach is
  // worse than advertising none: every client that tries it wastes a dial and
  // fails, and on a home connection the address is the operator's own IP, so a
  // failed guess is also a privacy leak for no benefit whatsoever.
  advertisedAddress() {
    return this.inboundVerified ? this.publicAddress : '';
  }

  // Called by PeerMesh the first time a peer connects INBOUND to us. That is the
  // only real proof of inbound reachability — not STUN, not NAT type, not a
  // successful outbound connection, all of which a one-way NAT also satisfies.
  markInboundVerified(fromAddress) {
    // provenAt records a GENUINE inbound connection, recorded on EVERY call —
    // even when we already assumed reachability (plugin-ingress / operator-
    // configured / direct-* seed inboundVerified=true at boot without proof).
    // The circuit-relay auto-fallback keys off provenAt, not the assumed
    // inboundVerified/verifiedAt, so an address nobody can actually reach is
    // never mistaken for a reachable one.
    this.provenAt = Date.now();
    if (this.inboundVerified) return false;
    this.inboundVerified = true;
    this.verifiedAt      = Date.now();
    if (this.reachabilityMethod.endsWith('-unverified')) {
      this.reachabilityMethod = this.reachabilityMethod.replace('-unverified', '');
    }
    // Any circuit-relay method — STUN-detected OR the auto-fallback below — that
    // then earns a genuine inbound proof is actually directly reachable: promote
    // to direct so we stop leaning on a relay we don't need.
    if (this.reachabilityMethod.startsWith('circuit-relay')) {
      this.reachabilityMethod = 'direct-inbound';
    }
    try {
      global.sovLog.info(
        `      ✓ Inbound reachability PROVEN by ${fromAddress || 'a peer'} — ` +
        `now advertising ${this.publicAddress} (${this.reachabilityMethod})`);
    } catch (_) {}
    return true;
  }

  static async start(identity) {
    const log = global.sovLog;
    let result;

    // ── Operator-supplied INGRESS PLUGIN (citizen-provided, NOT a hardcoded service) ──
    // For citizens behind CGNAT/hotspot who plug in their own external ingress
    // (Tailscale Funnel / static IP / etc.). SOV ships only the
    // interface; the plugin lives outside the protocol. If it yields a host, we
    // advertise it and skip auto-detection. See reachability_plugin.js.
    try {
      const { loadIngressPlugin } = require('./reachability_plugin');
      const dataDir = process.env.SOV_DATA_DIR || (require('os').homedir() + '/.sov-node');
      const pluginHost = await loadIngressPlugin({ dataDir, sovPort: SOV_PORT, log });
      if (pluginHost) {
        const addr = /:\d+$/.test(pluginHost) ? pluginHost : `${pluginHost}:${SOV_PORT}`;
        log.info(`      Reachability via operator ingress plugin: ${addr}`);
        return new NetworkManager({
          publicAddress:      addr,
          natType:            'plugin-ingress',
          reachabilityMethod: 'plugin-ingress',
          upnpClient:         null,
        });
      }
    } catch (e) {
      log.warn(`      ingress plugin load skipped: ${e.message}`);
    }

    // ── Test/ops override: force a reachability method (e.g. circuit-relay) ────
    // SOV_FORCE_REACHABILITY=circuit-relay lets us exercise the circuit-relay path
    // on a machine that would otherwise auto-detect as directly reachable. Also
    // useful to force a hard-NAT node into relay mode deliberately.
    const forced = (process.env.SOV_FORCE_REACHABILITY || '').trim();
    if (forced) {
      const host = (process.env.SOV_PUBLIC_HOST || '').trim() || '0.0.0.0';
      log.info(`      Reachability FORCED to '${forced}' (SOV_FORCE_REACHABILITY)`);
      return new NetworkManager({
        publicAddress:      `${host}:${SOV_PORT}`,
        natType:            forced,
        reachabilityMethod: forced,
        upnpClient:         null,
      });
    }

    // ── Step 0: Operator-configured reachable address (OPERATOR-LOCAL) ────────
    // SOV_PUBLIC_HOST lets a node operator advertise their OWN externally-reachable
    // citizen-gateway address when auto-detection can't make them reachable (hard
    // NAT / CGNAT). Two intended uses, both the operator's private choice:
    //   • static router IP + port-forward   → SOV_PUBLIC_HOST="203.0.113.7"
    //   • an external tunnel/subdomain      → SOV_PUBLIC_HOST="mynode.example.com"
    // This is NOT a protocol dependency: it only sets how THIS node names its own
    // address to the mesh/phones (exactly what UPnP/STUN do automatically). If unset,
    // the normal UPnP → STUN → circuit-relay chain runs. host or host:port (defaults
    // to SOV_PORT). Skips UPnP/STUN since the operator asserts reachability.
    const manualHost = (process.env.SOV_PUBLIC_HOST || '').trim();
    if (manualHost) {
      const addr = /:\d+$/.test(manualHost) ? manualHost : `${manualHost}:${SOV_PORT}`;
      log.info(`      Operator-configured public address: ${addr} (reachability=operator-configured)`);
      return new NetworkManager({
        publicAddress:      addr,
        natType:            'operator-configured',
        // reach-probe-v1: an operator ASSERTION is not a proof. A typo, a stale
        // DNS record or a tunnel that never came up all look like a serving node.
        reachabilityMethod: 'operator-configured-unverified',
        upnpClient:         null,
      });
      // NOTE: no IP monitor — the operator's host/IP is stable by their choice.
    }

    // ── Step 1: Get current public IP ────────────────────────────────────────
    let publicIP;
    try {
      publicIP = await NetworkManager._getPublicIP();
      log.info(`      Detected public IP: ${publicIP}`);
    } catch (ipErr) {
      // All 3 IP-echo services unreachable (transient outage, restrictive network,
      // etc.) must NEVER be fatal — start in circuit-relay mode instead of crashing,
      // and let the periodic _startIPMonitor() below upgrade reachability
      // automatically the moment a public IP becomes detectable.
      log.warn(`      Could not detect public IP (${ipErr.message}) — starting in circuit-relay mode; will retry automatically`);
      result = new NetworkManager({
        publicAddress:      `0.0.0.0:${SOV_PORT}`, // placeholder until IP detection succeeds
        natType:            'unknown',
        reachabilityMethod: 'circuit-relay',
        upnpClient:         null,
      });
      result._startIPMonitor();
      return result;
    }

    // ── Step 2: Try UPnP ─────────────────────────────────────────────────────
    try {
      const client = upnp.createClient();
      await new Promise((resolve, reject) => {
        client.portMapping({
          public:   { port: SOV_PORT },
          private:  { port: SOV_PORT },
          protocol: 'TCP',
          description: 'SOV-Node-Citizens',
          ttl: 7200,
        }, err => err ? reject(err) : resolve());
      });
      await new Promise((resolve, reject) => {
        client.portMapping({
          public:   { port: SYNC_PORT },
          private:  { port: SYNC_PORT },
          protocol: 'TCP',
          description: 'SOV-Node-Sync',
          ttl: 7200,
        }, err => err ? reject(err) : resolve());
      });
      log.info('      UPnP port forward: success');
      result = new NetworkManager({
        publicAddress:      `${publicIP}:${SOV_PORT}`,
        natType:            'upnp',
        reachabilityMethod: 'direct-upnp',
        upnpClient:         client,
      });
    } catch (upnpErr) {
      log.info(`      UPnP (nat-upnp) unavailable: ${upnpErr.message}`);

      // ── Step 2b: NAT-traversal L1 fallback — nat-api (UPnP + NAT-PMP) ─────────
      // Pure-JS, catches routers that nat-upnp misses (esp. NAT-PMP-only / Apple).
      // Success here = the router opened our port → directly reachable, no relay.
      try {
        const NatAPI = require('nat-api');
        const napi = new NatAPI({ enablePMP: true, ttl: 7200 });
        await new Promise((res, rej) => napi.map(
          { publicPort: SOV_PORT, privatePort: SOV_PORT, protocol: 'TCP', description: 'SOV-Node-Citizens' },
          e => e ? rej(e) : res()));
        await new Promise((res, rej) => napi.map(
          { publicPort: SYNC_PORT, privatePort: SYNC_PORT, protocol: 'TCP', description: 'SOV-Node-Sync' },
          e => e ? rej(e) : res()));
        log.info('      Port-map (nat-api UPnP/NAT-PMP): success');
        result = new NetworkManager({
          publicAddress:      `${publicIP}:${SOV_PORT}`,
          natType:            'port-mapped',
          reachabilityMethod: 'direct-portmap',
          upnpClient:         napi,   // has unmap()/destroy() for cleanup
        });
        result._startIPMonitor();
        return result;
      } catch (pmErr) {
        log.info(`      nat-api port-map unavailable: ${pmErr.message}`);
      }

      // ── Step 3: Try STUN to detect NAT type ──────────────────────────────
      const natType = await NetworkManager._detectNatType(publicIP);
      log.info(`      NAT type detected: ${natType}`);

      if (natType === 'open' || natType === 'full-cone') {
        // reachability-proof-v1: NAT type is a HINT, never a proof. STUN reports
        // UDP behaviour; inbound TCP on 7771/443 can still be dropped, and on an
        // ordinary home line it usually is. Start unverified and advertise
        // nothing until a peer actually reaches us — see markInboundVerified().
        log.info('      NAT looks open — holding the address back until an inbound peer proves it');
        result = new NetworkManager({
          publicAddress:      `${publicIP}:${SOV_PORT}`,
          natType,
          reachabilityMethod: 'direct-unverified',
          upnpClient:         null,
        });
      } else {
        // ── Step 4: Will use circuit relay (registered after peer mesh starts)
        log.info('      Will use circuit relay through peer network');
        result = new NetworkManager({
          // reachability-proof-v1: this used to be advertised verbatim if the
          // relay was never assigned — publishing a raw home IP that nothing
          // could reach. It is held back now until proven.
          publicAddress:      `${publicIP}:${SOV_PORT}`,
          natType,
          reachabilityMethod: 'circuit-relay-unverified',
          upnpClient:         null,
        });
      }
    }

    // ── Step 5: Start IP monitor ──────────────────────────────────────────────
    result._startIPMonitor();
    return result;
  }

  // ── IP change monitoring ───────────────────────────────────────────────────

  _startIPMonitor() {
    this._ipMonitor = setInterval(async () => {
      try {
        const currentIP = await NetworkManager._getPublicIP();
        if (currentIP !== this._lastKnownIP) {
          global.sovLog.info(`IP changed: ${this._lastKnownIP} → ${currentIP}`);
          this._lastKnownIP    = currentIP;
          this.publicAddress   = `${currentIP}:${SOV_PORT}`;

          // Re-request UPnP if we had it
          if (this._upnpClient) {
            try {
              await new Promise((resolve, reject) => {
                this._upnpClient.portMapping({
                  public: { port: SOV_PORT }, private: { port: SOV_PORT },
                  protocol: 'TCP', description: 'SOV-Node-Citizens', ttl: 7200,
                }, err => err ? reject(err) : resolve());
              });
            } catch (_) {}
          }

          // Notify peer mesh to re-announce
          if (this._onIPChange) this._onIPChange(currentIP);
        }
      } catch (_) {}
    }, IP_CHECK_INTERVAL);
  }

  stop() {
    if (this._ipMonitor) clearInterval(this._ipMonitor);
    if (this._upnpClient) {
      try { this._upnpClient.portUnmapping({ public: { port: SOV_PORT }, protocol: 'TCP' }, () => {}); } catch (_) {}
    }
  }

  // ── Utilities ─────────────────────────────────────────────────────────────

  static _getPublicIP() {
    return new Promise((resolve, reject) => {
      // Try multiple IP detection services for resilience
      const services = [
        'https://api.ipify.org',
        'https://icanhazip.com',
        'https://ifconfig.me/ip',
      ];
      let tried = 0;
      const tryNext = () => {
        if (tried >= services.length) {
          reject(new Error('Could not detect public IP'));
          return;
        }
        const url = services[tried++];
        const get = url.startsWith('https') ? https.get : http.get;
        get(url, res => {
          let data = '';
          res.on('data', chunk => data += chunk);
          res.on('end',  () => resolve(data.trim()));
        }).on('error', tryNext);
      };
      tryNext();
    });
  }

  static async _detectNatType(publicIP) {
    // Use STUN to probe NAT behaviour
    // Returns: 'open' | 'full-cone' | 'restricted' | 'port-restricted' | 'symmetric' | 'cgnat'
    //
    // BUG FIXED 2026-08-30: this only ever read the legacy RFC 3489
    // MAPPED-ADDRESS attribute. Every modern STUN server (including Google's,
    // stun.l.google.com — the only one configured here) replies with RFC 5389
    // XOR-MAPPED-ADDRESS instead, which the 'stun' package exposes via
    // getXorAddress(). Reading the wrong attribute meant mappedAddr was always
    // undefined and this returned 'unknown' unconditionally, on every network,
    // regardless of actual NAT type — confirmed by running the STUN request
    // directly: it succeeded and getXorAddress() returned a real address while
    // getAttribute(STUN_ATTR_MAPPED_ADDRESS) returned undefined on the same
    // response. Falls back to the legacy attribute for any STUN server old
    // enough to only send that one.
    try {
      const stunServer = { host: 'stun.l.google.com', port: 19302 };
      const response = await stun.request(stunServer.host, { port: stunServer.port });

      const xor = response.getXorAddress ? response.getXorAddress() : null;
      let mappedIP = xor && xor.address;

      if (!mappedIP) {
        const legacy = response.getAttribute(stun.constants.STUN_ATTR_MAPPED_ADDRESS);
        mappedIP = legacy && legacy.value && legacy.value.address;
      }

      if (!mappedIP) {
        global.sovLog.debug && global.sovLog.debug('[NAT] STUN response carried neither XOR-MAPPED-ADDRESS nor MAPPED-ADDRESS');
        return 'unknown';
      }

      // If mapped IP matches detected public IP — likely open or full-cone
      if (mappedIP === publicIP) return 'full-cone';

      // CGNAT: mapped IP is in RFC 6598 (100.64.0.0/10) range
      if (mappedIP.startsWith('100.6') || mappedIP.startsWith('100.7')) return 'cgnat';

      return 'restricted';
    } catch (e) {
      global.sovLog.debug && global.sovLog.debug(`[NAT] STUN request failed: ${e.message}`);
      return 'unknown';
    }
  }
}

module.exports = { NetworkManager };
