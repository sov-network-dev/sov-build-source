// reachability_plugin.js — OPERATOR-SUPPLIED ingress plugin loader (Task #27).
//
// SOV's own reachability is self-dependent + hardcoded: UPnP/NAT-PMP (L1) and
// circuit-relay through mesh peers (L3). NO third-party service is baked into the
// protocol. This loader lets a citizen who NEEDS an external ingress (e.g. behind
// CGNAT / a phone hotspot, with no reachable peer handy) DROP IN their own plugin
// that establishes a public endpoint (Tailscale Funnel, a static
// IP / manual port-forward, ngrok, etc.) and returns its public host. The plugin is
// citizen-provided and lives OUTSIDE the protocol — SOV ships only this interface.
//
// Plugin contract: a CommonJS module exporting
//     async function establish({ log, sovPort }) -> "host" | "host:port" | null
// It may launch a helper process and must return the public hostname/IP to advertise
// (or null to decline). See plugins/ingress-examples/ for ready-to-fill templates.
//
// Resolution order (first that yields a host wins):
//   1. process.env.SOV_INGRESS_PLUGIN   (absolute path to a plugin .js)
//   2. <SOV_DATA_DIR>/ingress-plugin.js (citizen drops their filled plugin here)
'use strict';
const fs = require('fs');
const path = require('path');

async function loadIngressPlugin({ dataDir, sovPort, log }) {
  log = log || global.sovLog || console;
  const candidates = [];
  if (process.env.SOV_INGRESS_PLUGIN) candidates.push(process.env.SOV_INGRESS_PLUGIN);
  if (dataDir) candidates.push(path.join(dataDir, 'ingress-plugin.js'));

  for (const p of candidates) {
    try {
      const abs = path.resolve(p);
      if (!fs.existsSync(abs)) continue;
      const plugin = require(abs);
      if (!plugin || typeof plugin.establish !== 'function') {
        log.warn && log.warn(`[Ingress] plugin ${abs} has no establish() — skipping`);
        continue;
      }
      log.info && log.info(`[Ingress] running operator ingress plugin: ${abs}`);
      const host = await plugin.establish({ log, sovPort });
      if (host && typeof host === 'string' && host.trim()) {
        log.info && log.info(`[Ingress] plugin provided public host: ${host.trim()}`);
        return host.trim();
      }
      log.info && log.info('[Ingress] plugin returned no host — falling back to built-in reachability');
    } catch (e) {
      log.warn && log.warn(`[Ingress] plugin ${p} error: ${e.message} — falling back`);
    }
  }
  return null;
}

module.exports = { loadIngressPlugin };
