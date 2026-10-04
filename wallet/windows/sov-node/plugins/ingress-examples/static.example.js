// INGRESS PLUGIN (example): static / manual public host.
//
// Use when YOU already have a reachable address for this node — e.g. a home router
// with a manual port-forward + static/public IP, or a tunnel you run yourself and
// whose hostname is stable (Tailscale Funnel, a port-forward, etc.).
//
// HOW TO USE:
//   1. Copy this file to <your SOV data dir>\ingress-plugin.js
//      (or set env SOV_INGRESS_PLUGIN to its path).
//   2. Edit PUBLIC_HOST below to your reachable host (and :port if not 443).
//   3. Restart the node. It will advertise this address so clients can reach you.
//
// SOV ships only the interface — this file (and your host) are yours; nothing about
// any third-party service is hardcoded in the protocol.

const PUBLIC_HOST = 'CHANGE-ME.example.com';   // e.g. '203.0.113.7' or 'mynode.ts.net' or 'host:8443'

module.exports = {
  async establish({ log }) {
    if (!PUBLIC_HOST || PUBLIC_HOST.startsWith('CHANGE-ME')) {
      log.warn && log.warn('[Ingress:static] PUBLIC_HOST not set — edit the plugin. Declining.');
      return null;
    }
    return PUBLIC_HOST;
  },
};
