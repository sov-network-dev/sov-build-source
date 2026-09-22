// ─────────────────────────────────────────────────────────────────────────────
// OPERATOR DASHBOARD — HTTP web UI at http://[node-ip]/dashboard
// ─────────────────────────────────────────────────────────────────────────────
// A single-page dashboard for the node operator. No external dependencies.
// Pure HTML + CSS + vanilla JS. Served as one inline HTTP response.
//
// Pages / sections:
//   /dashboard          — Main status overview
//   /dashboard/json     — Raw JSON stats for external monitors
//   /dashboard/logs     — Last 100 log lines (streamed)
//   /dashboard/nodes    — Registered operator node list
//   /dashboard/params   — Live governance params table
//
// Security: password-protected. Each node mints its own on first run and keeps
// it in its data directory at 0600 (see dashboardPassword below); set
// DASHBOARD_PASSWORD to override. There is no default password.
// ─────────────────────────────────────────────────────────────────────────────

'use strict';

const http   = require('http');
const https  = require('https');
const url    = require('url');
const crypto = require('crypto');
const fs     = require('fs');
const path   = require('path');

const DASHBOARD_PORT     = parseInt(process.env.DASHBOARD_PORT     || '8080');
const SESSION_TTL_MS     = 30 * 60 * 1000;  // 30-minute sessions

// ── Dashboard password (dashboard-password-v1) ───────────────────────────────
// This used to fall back to the literal 'operator' and merely warn about it.
// See the header: a warning is not a control.
//
// PRECEDENCE (same shape as network_seed.js, deliberately):
//   1. DASHBOARD_PASSWORD in the environment — explicit operator override.
//   2. the password file written by a previous run.
//   3. a fresh random one, generated and persisted now.
const PASSWORD_FILE = 'dashboard-password';

function _passwordPath() {
  const snapCommon = process.env.SNAP_COMMON;
  if (snapCommon) return path.join(snapCommon, PASSWORD_FILE);
  const dataDir = process.env.SOV_DATA_DIR ||
                  path.join(require('os').homedir(), '.sov-node');
  return path.join(dataDir, PASSWORD_FILE);
}

let _cachedPassword = null;
let _passwordOrigin = '';

function dashboardPassword() {
  if (_cachedPassword) return _cachedPassword;

  const fromEnv = (process.env.DASHBOARD_PASSWORD || '').trim();
  if (fromEnv) {
    _cachedPassword = fromEnv;
    _passwordOrigin = 'environment';
    return _cachedPassword;
  }

  const p = _passwordPath();
  try {
    if (fs.existsSync(p)) {
      const v = fs.readFileSync(p, 'utf8').trim();
      if (v.length >= 12) {
        _cachedPassword = v;
        _passwordOrigin = 'file';
        return _cachedPassword;
      }
    }
  } catch (_) { /* fall through and mint a new one */ }

  const minted = crypto.randomBytes(12).toString('base64url'); // 96 bits
  try {
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, minted, { mode: 0o600 });
    try { fs.chmodSync(p, 0o600); } catch (_) {}
    _passwordOrigin = 'generated';
  } catch (e) {
    // Could not persist it. Still better than a known default: valid for this
    // run only, and the operator is told why it will not survive a restart.
    _passwordOrigin = 'generated-unsaved:' + e.message;
  }
  _cachedPassword = minted;
  return _cachedPassword;
}

class OperatorDashboard {

  constructor(identity, db, peerMesh, gateway, operatorEngine) {
    this._identity       = identity;
    this._db             = db;
    this._peerMesh       = peerMesh;
    this._gateway        = gateway;
    this._operatorEngine = operatorEngine;
    this._sessions       = new Map();  // token → { expiresAt }
    this._logBuffer      = [];         // last 200 log lines
    this._server         = null;

    // Tap into global logger to capture lines for the log viewer
    if (global.sovLog) {
      const origWrite = process.stdout.write.bind(process.stdout);
      process.stdout.write = (str, ...args) => {
        if (typeof str === 'string') {
          const line = str.trim();
          if (line) {
            this._logBuffer.push(line);
            if (this._logBuffer.length > 200) this._logBuffer.shift();
          }
        }
        return origWrite(str, ...args);
      };
    }

    // Resolve on construction so the operator is told where the password is
    // BEFORE they need it. The value itself is never logged.
    dashboardPassword();
    if (_passwordOrigin === 'generated') {
      global.sovLog.info(`      ✓ Dashboard password generated → ${_passwordPath()}`);
    } else if (_passwordOrigin.startsWith('generated-unsaved')) {
      global.sovLog.warn(
        `[Dashboard] Could not save the dashboard password (${_passwordOrigin.split(':').slice(1).join(':')}). ` +
        `A new one will be generated next restart — set DASHBOARD_PASSWORD to pin it.`);
    } else if (_passwordOrigin === 'file') {
      global.sovLog.info(`      ✓ Dashboard password loaded from ${_passwordPath()}`);
    }
  }

  static start(identity, db, peerMesh, gateway, operatorEngine) {
    const dash = new OperatorDashboard(identity, db, peerMesh, gateway, operatorEngine);
    dash._startServer();
    return dash;
  }

  // ── HTTP server ────────────────────────────────────────────────────────────

  _startServer() {
    this._server = http.createServer((req, res) => {
      try {
        this._handleRequest(req, res);
      } catch (err) {
        res.writeHead(500, { 'Content-Type': 'text/plain' });
        res.end('Internal error');
        global.sovLog.error(`[Dashboard] Error: ${err.message}`);
      }
    });

    this._server.listen(DASHBOARD_PORT, '127.0.0.1', () => {
      global.sovLog.info(`      ✓ Operator dashboard at http://127.0.0.1:${DASHBOARD_PORT}/dashboard`);
    });
  }

  _handleRequest(req, res) {
    const parsed   = url.parse(req.url, true);
    const pathname = parsed.pathname;

    // ── Login form ─────────────────────────────────────────────────────────
    if (pathname === '/dashboard/login') {
      if (req.method === 'POST') {
        let body = '';
        req.on('data', d => body += d);
        req.on('end', () => {
          const params = new URLSearchParams(body);
          const pwd    = params.get('password') || '';
          if (this._checkPassword(pwd)) {
            const token = crypto.randomBytes(24).toString('hex');
            this._sessions.set(token, { expiresAt: Date.now() + SESSION_TTL_MS });
            res.writeHead(302, {
              'Location':   '/dashboard',
              'Set-Cookie': `sovd=${token}; HttpOnly; Path=/`,
            });
            res.end();
          } else {
            res.writeHead(200, { 'Content-Type': 'text/html' });
            res.end(this._loginPage('Invalid password'));
          }
        });
      } else {
        res.writeHead(200, { 'Content-Type': 'text/html' });
        res.end(this._loginPage());
      }
      return;
    }

    // ── Auth check for all other /dashboard routes ─────────────────────────
    if (!this._isAuthed(req)) {
      res.writeHead(302, { 'Location': '/dashboard/login' });
      res.end();
      return;
    }

    // ── JSON stats API ─────────────────────────────────────────────────────
    if (pathname === '/dashboard/json') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(this._collectStats(), null, 2));
      return;
    }

    // ── Log viewer (plain text) ────────────────────────────────────────────
    if (pathname === '/dashboard/logs') {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(this._logsPage());
      return;
    }

    // ── Nodes list ─────────────────────────────────────────────────────────
    if (pathname === '/dashboard/nodes') {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(this._nodesPage());
      return;
    }

    // ── Governance params ──────────────────────────────────────────────────
    if (pathname === '/dashboard/params') {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(this._paramsPage());
      return;
    }

    // ── Main dashboard ─────────────────────────────────────────────────────
    if (pathname === '/dashboard' || pathname === '/dashboard/') {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(this._mainPage());
      return;
    }

    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Not found');
  }

  // ── Auth helpers ───────────────────────────────────────────────────────────

  _checkPassword(pwd) {
    // The comment here used to say "constant-time comparison" above a plain
    // `===`, which is not one. Hash to equalise length (timingSafeEqual throws
    // on a length mismatch, which would itself leak), then compare properly.
    const expected = crypto.createHash('sha256').update(dashboardPassword()).digest();
    const actual   = crypto.createHash('sha256').update(String(pwd ?? '')).digest();
    return crypto.timingSafeEqual(expected, actual);
  }

  _isAuthed(req) {
    const cookie = req.headers['cookie'] || '';
    const match  = cookie.match(/sovd=([a-f0-9]+)/);
    if (!match) return false;
    const token   = match[1];
    const session = this._sessions.get(token);
    if (!session || session.expiresAt < Date.now()) {
      this._sessions.delete(token);
      return false;
    }
    // Renew session TTL on each request
    session.expiresAt = Date.now() + SESSION_TTL_MS;
    return true;
  }

  // ── Stats collector ────────────────────────────────────────────────────────

  _collectStats() {
    const nodeId      = this._identity.nodeId;
    const connCount   = this._gateway ? this._gateway.connectedCount() : 0;
    const peerCount   = this._peerMesh.peerCount();
    const uptime      = Math.floor((Date.now() - (this._startedAt || Date.now())) / 1000);
    const isReg       = this._operatorEngine ? this._operatorEngine.isRegistered() : false;
    const nodeCount   = this._operatorEngine ? this._operatorEngine.getRegisteredNodeCount() : 0;
    const proofHist   = this._operatorEngine ? this._operatorEngine.getProofHistory(null, 3) : [];

    // DB counts
    let citizenCount = 0;
    let totalSeeds   = 0;
    let openPolls    = 0;
    let openDisputes = 0;
    try {
      citizenCount = this._db._db.prepare('SELECT COUNT(*) as c FROM sov_enrollments').get().c;
      totalSeeds   = this._db._db.prepare('SELECT COALESCE(SUM(balance_seeds),0) as s FROM sov_disc').get().s;
      openPolls    = this._db._db.prepare("SELECT COUNT(*) as c FROM sov_polls WHERE status='open'").get().c;
      openDisputes = this._db._db.prepare("SELECT COUNT(*) as c FROM sov_disputes WHERE status='open'").get().c;
    } catch (_) {}

    return {
      node_id:          nodeId,
      registered:       isReg,
      connected_citizens: connCount,
      enrolled_citizens:  citizenCount,
      peer_count:       peerCount,
      network_nodes:    nodeCount,
      uptime_sec:       uptime,
      total_sov_seeds:  totalSeeds,
      open_polls:       openPolls,
      open_disputes:    openDisputes,
      proof_history:    proofHist,
      timestamp:        Date.now(),
    };
  }

  // ── HTML page generators ───────────────────────────────────────────────────

  _loginPage(error = '') {
    return `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>SOV Node — Operator Dashboard</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { background: #0a0f1e; color: #e0e0e0; font-family: system-ui, sans-serif;
           display: flex; justify-content: center; align-items: center; height: 100vh; }
    .card { background: #131c35; border: 1px solid #2a3a5c; border-radius: 12px;
            padding: 40px; width: 360px; }
    h1 { font-size: 22px; font-weight: 700; color: #f5c518; margin-bottom: 8px; }
    p.sub { color: #7a8aaa; font-size: 14px; margin-bottom: 28px; }
    input { width: 100%; background: #0d1529; border: 1px solid #2a3a5c; border-radius: 8px;
            color: #e0e0e0; padding: 12px 16px; font-size: 15px; outline: none;
            margin-bottom: 16px; }
    button { width: 100%; background: #f5c518; color: #0a0f1e; border: none;
             border-radius: 8px; padding: 12px; font-size: 16px; font-weight: 700;
             cursor: pointer; }
    .err { color: #ff6b6b; font-size: 13px; margin-bottom: 12px; }
  </style>
</head>
<body>
  <div class="card">
    <h1>⚡ SOV Node</h1>
    <p class="sub">Operator Dashboard — authenticated access</p>
    ${error ? `<p class="err">⚠ ${error}</p>` : ''}
    <form method="POST" action="/dashboard/login">
      <input type="password" name="password" placeholder="Operator password" autofocus>
      <button type="submit">Sign in</button>
    </form>
  </div>
</body>
</html>`;
  }

  _nav(active) {
    const links = [
      ['Overview',  '/dashboard'],
      ['Nodes',     '/dashboard/nodes'],
      ['Params',    '/dashboard/params'],
      ['Logs',      '/dashboard/logs'],
    ];
    return `<nav>
      ${links.map(([label, href]) =>
        `<a href="${href}" class="${active === label ? 'active' : ''}">${label}</a>`
      ).join('')}
    </nav>`;
  }

  _shell(title, active, content) {
    const s = this._collectStats();
    return `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta http-equiv="refresh" content="30">
  <title>SOV Node — ${title}</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { background: #0a0f1e; color: #e0e0e0; font-family: system-ui, sans-serif; }
    header { background: #131c35; border-bottom: 1px solid #2a3a5c;
             display: flex; align-items: center; padding: 0 24px; height: 56px; }
    header h1 { font-size: 18px; font-weight: 700; color: #f5c518; }
    .status-dot { display: inline-block; width: 10px; height: 10px; border-radius: 50%;
                  background: ${s.registered ? '#2ecc71' : '#e74c3c'}; margin-right: 10px; }
    nav { display: flex; gap: 0; }
    nav a { display: block; padding: 18px 20px; color: #7a8aaa; text-decoration: none;
            font-size: 14px; font-weight: 500; transition: color 0.15s; }
    nav a:hover, nav a.active { color: #f5c518; border-bottom: 2px solid #f5c518; }
    main { padding: 28px 28px; max-width: 1100px; }
    .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 16px; margin-bottom: 28px; }
    .card { background: #131c35; border: 1px solid #2a3a5c; border-radius: 10px; padding: 20px; }
    .card h3 { color: #7a8aaa; font-size: 12px; font-weight: 600; text-transform: uppercase;
               letter-spacing: 0.08em; margin-bottom: 8px; }
    .card .val { font-size: 28px; font-weight: 700; color: #f5c518; }
    .card .sub { font-size: 12px; color: #5a6a8a; margin-top: 4px; }
    table { width: 100%; border-collapse: collapse; font-size: 13px; }
    th { color: #7a8aaa; text-align: left; padding: 10px 12px; border-bottom: 1px solid #2a3a5c;
         font-weight: 600; text-transform: uppercase; font-size: 11px; letter-spacing: 0.06em; }
    td { padding: 10px 12px; border-bottom: 1px solid #1a2440; }
    tr:hover td { background: #131c35; }
    .badge { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 11px; font-weight: 600; }
    .badge.green  { background: #1a3a2a; color: #2ecc71; }
    .badge.yellow { background: #3a3010; color: #f5c518; }
    .badge.red    { background: #3a1010; color: #e74c3c; }
    h2 { font-size: 16px; font-weight: 600; margin-bottom: 16px; color: #c0cce0; }
    pre { background: #0d1529; border: 1px solid #1a2440; border-radius: 8px; padding: 16px;
          font-size: 12px; line-height: 1.6; overflow-x: auto; white-space: pre-wrap;
          word-break: break-all; max-height: 600px; overflow-y: auto; }
    .node-id { font-family: monospace; font-size: 11px; color: #7a8aaa; }
  </style>
</head>
<body>
  <header>
    <h1>⚡ SOV Node &nbsp;&mdash;&nbsp;
      <span class="status-dot"></span>
      <span style="font-size:14px; color: ${s.registered ? '#2ecc71' : '#e74c3c'}">
        ${s.registered ? 'Registered' : 'Unregistered'}
      </span>
    </h1>
    ${this._nav(active)}
    <div style="margin-left:auto; font-size:12px; color:#5a6a8a;">
      Auto-refresh 30s &nbsp;|&nbsp;
      <a href="/dashboard/json" style="color:#7a8aaa;">JSON</a>
    </div>
  </header>
  <main>
    ${content}
  </main>
</body>
</html>`;
  }

  _mainPage() {
    const s = this._collectStats();
    const fmtSeeds = (n) => {
      if (n >= 1_000_000_000) return (n / 1_000_000_000).toFixed(2) + 'B SOV';
      if (n >= 1_000_000)     return (n / 1_000_000).toFixed(2) + 'M SOV';
      if (n >= 1_000)         return (n / 1_000).toFixed(1) + 'K seeds';
      return n + ' seeds';
    };
    const fmtUptime = (sec) => {
      const d = Math.floor(sec / 86400);
      const h = Math.floor((sec % 86400) / 3600);
      const m = Math.floor((sec % 3600) / 60);
      return d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : `${m}m`;
    };

    const nodeIdShort = s.node_id.slice(0, 16) + '…';
    const proof = s.proof_history[0];

    const statsGrid = `
    <div class="grid">
      <div class="card"><h3>Connected</h3><div class="val">${s.connected_citizens}</div><div class="sub">Citizens online now</div></div>
      <div class="card"><h3>Enrolled</h3><div class="val">${s.enrolled_citizens}</div><div class="sub">Network citizens</div></div>
      <div class="card"><h3>Peers</h3><div class="val">${s.peer_count}</div><div class="sub">Connected nodes</div></div>
      <div class="card"><h3>Network Nodes</h3><div class="val">${s.network_nodes}</div><div class="sub">Registered operators</div></div>
      <div class="card"><h3>SOV in Circulation</h3><div class="val">${fmtSeeds(s.total_sov_seeds)}</div><div class="sub">Disc total</div></div>
      <div class="card"><h3>Open Polls</h3><div class="val">${s.open_polls}</div><div class="sub">Active governance</div></div>
      <div class="card"><h3>Open Disputes</h3><div class="val">${s.open_disputes}</div><div class="sub">Justice cases</div></div>
      <div class="card"><h3>Uptime</h3><div class="val">${fmtUptime(s.uptime_sec)}</div><div class="sub">Since last start</div></div>
    </div>`;

    const nodeInfo = `
    <div class="card" style="margin-bottom:24px;">
      <h3>This Node</h3>
      <div class="node-id" style="font-size:13px; color:#c0cce0; margin-top:8px;">${s.node_id}</div>
      <div style="margin-top:12px; font-size:13px; color:#7a8aaa;">
        Status: <span class="badge ${s.registered ? 'green' : 'red'}">${s.registered ? 'Active' : 'Unregistered'}</span>
        &nbsp;&nbsp;
        ${proof ? `Last proof score: <strong style="color:#f5c518">${proof.score.toFixed(2)}</strong>` : 'No proof yet'}
      </div>
    </div>`;

    const proofTable = s.proof_history.length ? `
    <h2>Recent Proof-of-Service</h2>
    <div class="card">
      <table>
        <tr>
          <th>Epoch</th>
          <th>Score</th>
          <th>Citizens</th>
          <th>Uptime</th>
          <th>Peers</th>
          <th>Earned</th>
        </tr>
        ${s.proof_history.map(p => `
        <tr>
          <td>${p.epoch_id}</td>
          <td style="color:#f5c518">${(p.score||0).toFixed(2)}</td>
          <td>${p.citizens_served}</td>
          <td>${fmtUptime(p.uptime_sec)}</td>
          <td>${p.peer_count}</td>
          <td>${fmtSeeds(p.earned_seeds)}</td>
        </tr>`).join('')}
      </table>
    </div>` : '';

    return this._shell('Overview', 'Overview', statsGrid + nodeInfo + proofTable);
  }

  _nodesPage() {
    const nodes = this._operatorEngine ? this._operatorEngine.getOperatorRegistry(200) : [];
    const now   = Date.now();

    const rows = nodes.map(n => {
      const ago  = Math.floor((now - n.last_seen_at) / 60000);
      const seen = ago < 2 ? 'just now' : ago < 60 ? `${ago}m ago` : `${Math.floor(ago/60)}h ago`;
      const badge = n.status === 'active' ? 'green' : 'red';
      const hw    = n.hardware_class === 'server' ? '🖥 Server' :
                    n.hardware_class === 'pi'     ? '🍓 Pi' : '💻 Desktop';
      return `<tr>
        <td class="node-id">${n.node_id.slice(0, 20)}…</td>
        <td>${n.operator_id ? n.operator_id.slice(0, 12) + '…' : '—'}</td>
        <td>${hw}</td>
        <td>${(n.stake_seeds / 1_000_000).toFixed(0)} SOV</td>
        <td style="color:#f5c518">${(n.proof_score||0).toFixed(2)}</td>
        <td>${seen}</td>
        <td><span class="badge ${badge}">${n.status}</span></td>
      </tr>`;
    }).join('');

    const content = `
    <h2>Registered Operators (${nodes.length})</h2>
    <div class="card">
      <table>
        <tr>
          <th>Node ID</th>
          <th>Operator</th>
          <th>Hardware</th>
          <th>Stake</th>
          <th>Proof Score</th>
          <th>Last Seen</th>
          <th>Status</th>
        </tr>
        ${rows || '<tr><td colspan="7" style="text-align:center; color:#5a6a8a; padding:24px;">No registered nodes yet</td></tr>'}
      </table>
    </div>`;

    return this._shell('Nodes', 'Nodes', content);
  }

  _paramsPage() {
    let params = [];
    try {
      params = this._db._db.prepare(
        'SELECT param_key, param_value, updated_at FROM sov_governance_params ORDER BY param_key'
      ).all();
    } catch (_) {}

    const rows = params.map(p => {
      const ago = p.updated_at ? Math.floor((Date.now() - p.updated_at) / 60000) : null;
      const since = ago === null ? '—' : ago < 60 ? `${ago}m ago` : `${Math.floor(ago/60)}h ago`;
      const isBinary = p.param_value === '0' || p.param_value === '1';
      const valBadge = isBinary
        ? `<span class="badge ${p.param_value === '1' ? 'green' : 'yellow'}">${p.param_value === '1' ? 'Active' : 'Dormant'}</span>`
        : `<strong style="color:#f5c518">${p.param_value}</strong>`;
      return `<tr>
        <td style="font-family: monospace; font-size: 12px;">${p.param_key}</td>
        <td>${valBadge}</td>
        <td style="color:#5a6a8a; font-size:12px;">${since}</td>
      </tr>`;
    }).join('');

    const content = `
    <h2>Governance Parameters (${params.length})</h2>
    <div class="card">
      <table>
        <tr>
          <th>Parameter</th>
          <th>Current Value</th>
          <th>Last Changed</th>
        </tr>
        ${rows || '<tr><td colspan="3" style="text-align:center; color:#5a6a8a; padding:24px;">No params set yet</td></tr>'}
      </table>
    </div>`;

    return this._shell('Params', 'Params', content);
  }

  _logsPage() {
    const lines = this._logBuffer.slice(-100).reverse();
    const escaped = lines
      .map(l => l.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'))
      .join('\n');

    const content = `
    <h2>Recent Log Output</h2>
    <pre>${escaped || '(no log output yet)'}</pre>`;

    return this._shell('Logs', 'Logs', content);
  }

  stop() {
    if (this._server) this._server.close();
  }
}

module.exports = { OperatorDashboard };
