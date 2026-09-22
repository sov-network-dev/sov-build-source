// ─────────────────────────────────────────────────────────────────────────────
// WATCHDOG — Crash recovery and process supervision
// ─────────────────────────────────────────────────────────────────────────────
// Runs as a SEPARATE process from the main SOV node.
// It launches and monitors the main process. If it crashes, watchdog restarts it.
//
// On Windows: runs as a Windows Service (via node-windows)
// On Linux:   managed by systemd (watchdog is the ExecStart target)
// On macOS:   managed by launchd (LaunchDaemon plist)
//
// Start order:
//   1. OS starts watchdog on boot (service/systemd/launchd)
//   2. Watchdog spawns src/index.js (the actual SOV node)
//   3. If node crashes → watchdog restarts it after backoff delay
//   4. If node is healthy for 10 minutes → reset backoff counter
//
// Usage (run directly for development):
//   node src/watchdog/watchdog.js
// ─────────────────────────────────────────────────────────────────────────────

'use strict';

const { spawn }  = require('child_process');
const path       = require('path');
const fs         = require('fs');
const os         = require('os');

const LOG_DIR    = path.join(process.env.SOV_DATA_DIR || path.join(os.homedir(), '.sov-node'), 'logs');
const NODE_MAIN  = path.join(__dirname, '..', 'index.js');

// Crash backoff: 2s, 4s, 8s, 16s, 32s, then cap at 60s
const BACKOFF_DELAYS = [2000, 4000, 8000, 16000, 32000, 60000];
const HEALTHY_UPTIME_MS = 10 * 60 * 1000; // 10 minutes = reset backoff

fs.mkdirSync(LOG_DIR, { recursive: true });

let crashCount   = 0;
let startTime    = 0;
let childProcess = null;
let stopping     = false;

function log(msg) {
  const line = `[${new Date().toISOString()}] [WATCHDOG] ${msg}`;
  console.log(line);
  try {
    fs.appendFileSync(path.join(LOG_DIR, 'watchdog.log'), line + '\n');
  } catch (_) {}
}

function getBackoffDelay() {
  const idx = Math.min(crashCount, BACKOFF_DELAYS.length - 1);
  return BACKOFF_DELAYS[idx];
}

function startNode() {
  if (stopping) return;

  startTime = Date.now();
  log(`Starting SOV node (attempt ${crashCount + 1})`);

  // Open stdout/stderr log streams
  const logFile = fs.openSync(path.join(LOG_DIR, 'node.log'), 'a');

  childProcess = spawn(process.execPath, [NODE_MAIN], {
    stdio: ['ignore', logFile, logFile],
    env:   { ...process.env },
    detached: false,
  });

  log(`Node PID: ${childProcess.pid}`);

  childProcess.on('exit', (code, signal) => {
    const uptime = Date.now() - startTime;

    if (uptime > HEALTHY_UPTIME_MS) {
      // Was running long enough — reset backoff
      crashCount = 0;
      log(`Node exited after ${Math.round(uptime / 1000)}s (healthy run — backoff reset). Code: ${code}`);
    } else {
      crashCount++;
      log(`Node exited after ${Math.round(uptime / 1000)}s. Code: ${code}, Signal: ${signal}. Crash #${crashCount}`);
    }

    if (stopping) {
      log('Watchdog stopping — not restarting node');
      process.exit(0);
      return;
    }

    const delay = getBackoffDelay();
    log(`Restarting in ${delay / 1000}s...`);
    setTimeout(startNode, delay);
  });
}

function stopGracefully() {
  stopping = true;
  log('Watchdog received shutdown signal');

  if (childProcess && childProcess.pid) {
    log(`Sending SIGTERM to node PID ${childProcess.pid}`);
    try {
      childProcess.kill('SIGTERM');
    } catch (_) {}
    // Force kill after 15 seconds
    setTimeout(() => {
      try { childProcess.kill('SIGKILL'); } catch (_) {}
      process.exit(0);
    }, 15000);
  } else {
    process.exit(0);
  }
}

process.on('SIGTERM', stopGracefully);
process.on('SIGINT',  stopGracefully);

// Watchdog is alive
log('SOV Node Watchdog started');
log(`Node executable: ${NODE_MAIN}`);
log(`Logs directory:  ${LOG_DIR}`);

startNode();
