// ─────────────────────────────────────────────────────────────────────────────
// SYSTEM TRAY — Desktop presence for the SOV node
// ─────────────────────────────────────────────────────────────────────────────
// On Windows: shows in the system notification area (bottom right)
// On Linux:   shows in the system tray (appindicator)
// On macOS:   shows in the menu bar
//
// The tray icon gives the operator live status at a glance:
//   Green  = node running, connected to peer network
//   Yellow = node running, limited connectivity (< MIN_PEERS)
//   Red    = node running, isolated (no peers)
//
// Menu items:
//   [●] SOV Node — Running (Node ID: 8a3f...)
//   Citizens connected: 14
//   Peer nodes: 9
//   ─────────────────────
//   Open Dashboard...
//   ─────────────────────
//   Stop Node
// ─────────────────────────────────────────────────────────────────────────────

'use strict';

let SysTray;
try {
  SysTray = require('systray2').default;
} catch (_) {
  // systray2 not installed — tray silently disabled
  // This happens in headless server environments
}

class TrayUI {

  constructor(node) {
    this._node   = node;
    this._tray   = null;
    this._active = false;
  }

  static async start(node) {
    const tray = new TrayUI(node);
    if (!SysTray || process.env.NODE_ENV === 'test' || !process.env.DISPLAY && process.platform === 'linux') {
      global.sovLog.info('      System tray: unavailable (headless environment)');
      return tray;
    }
    try {
      await tray._init();
    } catch (err) {
      global.sovLog.info(`      System tray: ${err.message} (continuing without tray)`);
    }
    return tray;
  }

  async _init() {
    const menu = this._buildMenu();

    this._tray = new SysTray({
      menu,
      debug:       false,
      copyDir:     true,
    });

    this._tray.onClick(action => {
      if (action.seq_id === 0) {
        // "Stop Node" — last item
        global.sovLog.info('Stop requested via system tray');
        process.kill(process.pid, 'SIGTERM');
      }
    });

    this._active = true;

    // Update tray every 10 seconds with live stats
    setInterval(() => this._updateMenu(), 10000);

    global.sovLog.info('      System tray: active');
  }

  _buildMenu() {
    const nodeId    = this._node?.identity?.nodeId || '...';
    const peers     = this._node?.peerMesh?.peerCount() || 0;
    const citizens  = this._node?.citizenGateway?.connectedCount() || 0;
    const status    = peers >= 4 ? 'Running' : peers > 0 ? 'Limited' : 'Isolated';

    return {
      icon:    this._iconBase64(peers),
      title:   `SOV Node — ${status}`,
      tooltip: `SOV Node | ${peers} peers | ${citizens} citizens`,
      items: [
        {
          title:   `SOV Node — ${status}`,
          tooltip: `Node ID: ${nodeId.slice(0, 16)}...`,
          checked: false,
          enabled: false,
        },
        {
          title:   `Citizens connected: ${citizens}`,
          checked: false,
          enabled: false,
        },
        {
          title:   `Peer nodes: ${peers}`,
          checked: false,
          enabled: false,
        },
        { title: '<separator>' },
        {
          title:   'Stop Node',
          tooltip: 'Gracefully shut down the SOV node',
          checked: false,
          enabled: true,
        },
      ],
    };
  }

  _updateMenu() {
    if (!this._tray || !this._active) return;
    try {
      this._tray.sendAction({
        type:   'update-menu',
        menu:   this._buildMenu(),
      });
    } catch (_) {}
  }

  // Returns a tiny 16×16 PNG as base64 — green/yellow/red circle
  // Real implementation would load actual icon files from the installer bundle
  _iconBase64(peers) {
    // Placeholder — installer places real icons at assets/tray-{green,yellow,red}.png
    const iconPath = require('path').join(__dirname, '..', '..', 'assets',
      peers >= 4 ? 'tray-green.png' : peers > 0 ? 'tray-yellow.png' : 'tray-red.png'
    );
    try {
      return require('fs').readFileSync(iconPath, 'base64');
    } catch (_) {
      return ''; // Icon file missing — tray shows blank
    }
  }

  stop() {
    this._active = false;
    try { this._tray?.kill(); } catch (_) {}
  }
}

module.exports = { TrayUI };
