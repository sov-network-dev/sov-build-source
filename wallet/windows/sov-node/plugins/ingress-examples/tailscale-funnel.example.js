// INGRESS PLUGIN (example): Tailscale Funnel (free forever, no domain, no VPS).
//
// Exposes this node to the PUBLIC internet on your stable Tailscale hostname
// (e.g. mybox.tailXXXX.ts.net) over valid TLS — works behind CGNAT / phone hotspot
// because Tailscale connects outbound. Best free-forever non-VPS option for a stable
// public WSS endpoint.
//
// ONE-TIME SETUP (operator):
//   1. Install Tailscale + sign in (free personal plan).
//   2. Enable Funnel for your tailnet (admin console → Funnel) if required.
//   3. Find your node's MagicDNS name: `tailscale status` → e.g. mybox.tailXXXX.ts.net
//   4. Set TS_FUNNEL_HOST below (or env SOV_TS_FUNNEL_HOST) to that name.
//
// HOW TO USE: copy to <SOV data dir>\ingress-plugin.js, set the host, restart the node.
// This plugin runs `tailscale funnel <sovPort>` to publish the port, then advertises
// the public hostname. Funnel allows ports 443 / 8443 / 10000.

const { spawn } = require('child_process');

const TS_FUNNEL_HOST = process.env.SOV_TS_FUNNEL_HOST || 'CHANGE-ME.tailXXXX.ts.net';

module.exports = {
  async establish({ log, sovPort }) {
    if (!TS_FUNNEL_HOST || TS_FUNNEL_HOST.startsWith('CHANGE-ME')) {
      log.warn && log.warn('[Ingress:tailscale] TS_FUNNEL_HOST not set — edit the plugin. Declining.');
      return null;
    }
    const port = sovPort || 8443;
    try {
      const bin = process.env.TAILSCALE_BIN || 'tailscale';
      const proc = spawn(bin, ['funnel', String(port)], { stdio: 'ignore' });
      global._sovTailscaleProc = proc;   // keep alive for node lifetime
      log.info && log.info(`[Ingress:tailscale] funnel published on :${port} → https://${TS_FUNNEL_HOST}`);
    } catch (e) {
      log.warn && log.warn(`[Ingress:tailscale] could not run 'tailscale funnel' (${e.message}); assuming it is already running.`);
    }
    return `${TS_FUNNEL_HOST}:443`;   // Funnel serves on 443
  },
};
