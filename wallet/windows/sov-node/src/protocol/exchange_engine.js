// ─────────────────────────────────────────────────────────────────────────────
// EXCHANGE ENGINE — Peer-to-peer SOV exchange (DEX)
// ─────────────────────────────────────────────────────────────────────────────
// Citizens list SOV for sale. Buyers fill orders. Escrow holds SOV during
// trade. Cross-node order visibility via broadcast. SOV Shield notifications.
//
// Trade flow:
//   SELLER → EXCHANGE_LIST_ORDER → escrow locked → EXCHANGE_ORDER_BROADCAST
//   BUYER  → EXCHANGE_FILL_ORDER → fill recorded → EXCHANGE_FILL_FORWARD to source node
//   SELLER → EXCHANGE_SELLER_CONFIRMS → escrow released to buyer
//   BUYER  → EXCHANGE_BUYER_REQUESTS_REFUND → escrow returned to seller
//
// Cross-node:
//   Every order/fill/status change → EXCHANGE_STATE_REPLICATE to all peers
//   This ensures a replica survives if the source node goes down.
//
// Op codes (inbound from phone):
//   XL — EXCHANGE_LIST_ORDER       XF — EXCHANGE_FILL_ORDER
//   XC — EXCHANGE_CONFIRM_DELIVERY XR — EXCHANGE_REQUEST_REFUND
//   XE — EXCHANGE_EDIT_ORDER       XX — EXCHANGE_CANCEL_ORDER
//   XO — EXCHANGE_ORDER_BOOK       XP — EXCHANGE_PRICE_HISTORY
//   XM — EXCHANGE_MY_ORDERS        XH — EXCHANGE_CHAT_SEND
//   XK — EXCHANGE_CHAT_LIST
// ─────────────────────────────────────────────────────────────────────────────

'use strict';

const crypto = require('crypto');

// Order status values
const STATUS = {
  OPEN:      'open',
  FILLED:    'filled',
  CANCELLED: 'cancelled',
  DISPUTED:  'disputed',
  CONFIRMED: 'confirmed',
  REFUNDED:  'refunded',
};

// A v2 envelope as the app's MessageEncryptor writes it: {"v":2,"nonce":hex,"ct":hex}.
function isV2Envelope(env) {
  if (typeof env !== 'string' || env.length > 65536) return false;
  try { const o = JSON.parse(env); return !!o && o.v === 2 && typeof o.nonce === 'string' && typeof o.ct === 'string'; }
  catch (_) { return false; }
}

class ExchangeEngine {

  constructor(identity, db, peerMesh) {
    this._identity    = identity;
    this._db          = db;
    this._peerMesh    = peerMesh;
    this._gateway     = null;
    this._subscribers = new Set(); // ws connections subscribed to live order updates

    this._initExchangeTables();

    // Register peer mesh handlers
    peerMesh.on('EXCHANGE_ORDER_BROADCAST',   (msg) => this._handleOrderBroadcast(msg));
    peerMesh.on('EXCHANGE_FILL_FORWARD',      (msg) => this._handleFillForward(msg));
    peerMesh.on('EXCHANGE_STATUS_BROADCAST',  (msg) => this._handleStatusBroadcast(msg));
    peerMesh.on('EXCHANGE_STATE_REPLICATE',   (msg) => this._handleStateReplicate(msg));
    peerMesh.on('EXCHANGE_CHAT_FORWARD',      (msg) => this._handleChatForward(msg));
    peerMesh.on('EXCHANGE_CHAT_ACK',          (msg) => this._handleChatAck(msg));
    this._chatWaiters = new Map();   // msg_id -> resolve(status)
    // 1.4.90: every order action runs on the order's HOME node (where its escrow is) and
    // the citizen gets the home node's real answer — never a local guess (D27).
    peerMesh.on('EXCHANGE_HOME_REQUEST',      (msg) => this._onHomeRequest(msg));
    peerMesh.on('EXCHANGE_HOME_REPLY',        (msg) => this._onHomeReply(msg));
    this._homeWaiters = new Map();   // req_id -> resolve(frame)
    setTimeout(() => this._adoptLegacyEscrow(), 10 * 1000);

    // Hourly: expire old open orders
    setTimeout(() => this._cleanupExpiredOrders(), 30 * 1000);
    setInterval(() => this._cleanupExpiredOrders(), 60 * 60 * 1000);

    global.sovLog.info('      ✓ Exchange engine initialised');
  }

  setGateway(gateway) {
    this._gateway = gateway;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  SUBSCRIBE / UNSUBSCRIBE — push-based Browse
  //
  //  When a citizen opens the Exchange screen, Flutter sends EXCHANGE_SUBSCRIBE.
  //  The relay immediately pushes EXCHANGE_STATE with all open orders.
  //  Every subsequent order change is pushed as EXCHANGE_ORDER_UPDATE.
  //  On screen close Flutter sends EXCHANGE_UNSUBSCRIBE.
  //  On disconnect the gateway calls removeSubscriber() automatically.
  // ═══════════════════════════════════════════════════════════════════════════

  handleSubscribe(ws) {
    this._subscribers.add(ws);
    this._pushState(ws);
  }

  handleUnsubscribe(ws) {
    this._subscribers.delete(ws);
    if (ws && ws.readyState === 1) {
      ws.send(JSON.stringify({ op: 'XQ', type: 'EXCHANGE_UNSUBSCRIBED', success: true }));
    }
  }

  // Called by citizen_gateway on WebSocket close — always clean up.
  removeSubscriber(ws) {
    this._subscribers.delete(ws);
  }

  // Push complete open-order list to one subscriber.
  _pushState(ws) {
    if (!ws || ws.readyState !== 1) return;
    try {
      const now   = Date.now();
      const local = this._db._db.prepare(`
        SELECT * FROM sov_exchange_orders
        WHERE status = 'open' AND expires_at > ?
        ORDER BY created_at DESC LIMIT 100
      `).all(now);
      let merged = local;
      try {
        const replicas = this._db._db.prepare(`
          SELECT *, 'replica' AS _src FROM sov_exchange_replicas
          WHERE status = 'open' AND expires_at > ?
            AND source_node != ?
          ORDER BY created_at DESC LIMIT 100
        `).all(now, this._identity.nodeId);
        const seen = new Set(local.map(o => o.order_id));
        merged = [...local, ...replicas.filter(r => !seen.has(r.order_id))];
      } catch (_) { /* replicas table may not exist — local orders only */ }
      merged.sort((a, b) => b.created_at - a.created_at);
      global.sovLog.debug(`[Exchange] _pushState → ${merged.length} orders`);
      ws.send(JSON.stringify({ op: 'XB', type: 'EXCHANGE_STATE', orders: merged.slice(0, 100), ts: now }));
    } catch (err) {
      global.sovLog.warn(`[Exchange] _pushState error: ${err.message}`);
      ws.send(JSON.stringify({ op: 'XB', type: 'EXCHANGE_STATE', orders: [], ts: Date.now() }));
    }
  }

  // Broadcast a single order change to all live subscribers.
  // event: 'new' | 'updated' | 'removed'
  _broadcastUpdate(order, event = 'updated') {
    if (this._subscribers.size === 0) return;
    const msg = JSON.stringify({ op: 'XU', type: 'EXCHANGE_ORDER_UPDATE', order, event, ts: Date.now() });
    for (const ws of this._subscribers) {
      if (ws && ws.readyState === 1) {
        ws.send(msg);
      } else {
        this._subscribers.delete(ws);
      }
    }
  }

  // ── Table initialisation ──────────────────────────────────────────────────

  _initExchangeTables() {
    this._db._db.exec(`

      CREATE TABLE IF NOT EXISTS sov_exchange_orders (
        order_id      TEXT PRIMARY KEY,
        seller_id     TEXT NOT NULL,
        sov_amount    INTEGER NOT NULL,         -- seeds being sold
        price_per_sov REAL NOT NULL,            -- price in minor local currency units per SOV
        currency_code TEXT NOT NULL DEFAULT 'USD',
        status        TEXT NOT NULL DEFAULT 'open',
        filled_by     TEXT NOT NULL DEFAULT '', -- buyer sovereign_id
        source_node   TEXT NOT NULL DEFAULT '', -- which node created this order
        created_at    INTEGER NOT NULL,
        updated_at    INTEGER NOT NULL,
        expires_at    INTEGER NOT NULL,
        memo          TEXT NOT NULL DEFAULT ''
      );
      CREATE INDEX IF NOT EXISTS idx_xch_seller ON sov_exchange_orders(seller_id);
      CREATE INDEX IF NOT EXISTS idx_xch_status ON sov_exchange_orders(status);

      CREATE TABLE IF NOT EXISTS sov_exchange_replicas (
        order_id      TEXT PRIMARY KEY,
        seller_id     TEXT NOT NULL,
        sov_amount    INTEGER NOT NULL,
        price_per_sov REAL NOT NULL,
        currency_code TEXT NOT NULL DEFAULT 'USD',
        status        TEXT NOT NULL,
        filled_by     TEXT NOT NULL DEFAULT '',
        source_node   TEXT NOT NULL,
        created_at    INTEGER NOT NULL,
        updated_at    INTEGER NOT NULL,
        expires_at    INTEGER NOT NULL
      );

      CREATE TABLE IF NOT EXISTS sov_exchange_messages (
        msg_id        TEXT PRIMARY KEY,
        order_id      TEXT NOT NULL,
        from_id       TEXT NOT NULL,
        to_id         TEXT NOT NULL,
        content       TEXT NOT NULL,
        created_at    INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_xchat_order ON sov_exchange_messages(order_id);

      CREATE TABLE IF NOT EXISTS sov_reputation (
        sovereign_id     TEXT PRIMARY KEY,
        trades_completed INTEGER NOT NULL DEFAULT 0,
        trades_disputed  INTEGER NOT NULL DEFAULT 0,
        disputes_won     INTEGER NOT NULL DEFAULT 0,
        disputes_lost    INTEGER NOT NULL DEFAULT 0,
        total_sov_traded INTEGER NOT NULL DEFAULT 0,
        reputation_score REAL    NOT NULL DEFAULT 100,
        last_updated     INTEGER
      );

    `);

    // ── Stage 2 premium migrations (idempotent; ignore "duplicate column") ────
    //  payment_method: how the seller accepts off-platform fiat (bank / mobile
    //  money / cash …). buyer_id + read_ts: per-buyer negotiation threads + the
    //  unread badge for the seller inbox.
    const _migrations = [
      `ALTER TABLE sov_exchange_orders   ADD COLUMN payment_method TEXT NOT NULL DEFAULT ''`,
      `ALTER TABLE sov_exchange_replicas ADD COLUMN payment_method TEXT NOT NULL DEFAULT ''`,
      // E2E 2026-10-03: the replica never carried the order's terms (memo), so a buyer on any node
      // but the seller's was asked to agree to "" — the description existed only where it was made.
      `ALTER TABLE sov_exchange_replicas ADD COLUMN memo TEXT NOT NULL DEFAULT ''`,
      `ALTER TABLE sov_exchange_messages ADD COLUMN buyer_id TEXT NOT NULL DEFAULT ''`,
      `ALTER TABLE sov_exchange_messages ADD COLUMN read_ts  INTEGER`,
    ];
    for (const sql of _migrations) {
      try { this._db._db.exec(sql); } catch (_) { /* column already exists */ }
    }
    this._db._db.exec(`CREATE INDEX IF NOT EXISTS idx_xchat_buyer ON sov_exchange_messages(order_id, buyer_id)`);
    // Nodes keep no messages (king, 2026-10-03). Trade chat used to be stored here in
    // plain text and replicated; clear whatever an earlier version kept.
    try {
      const n = this._db._db.prepare('DELETE FROM sov_exchange_messages').run().changes;
      if (n) global.sovLog.info(`      Exchange: removed ${n} stored trade message(s) - nodes keep no messages`);
    } catch (_) {}

    // Seed exchange governance defaults
    const govDefaults = [
      ['exchange_network_fee',    '0.01'],
      ['exchange_max_order_sov',  '10000'],
    ];
    for (const [key, val] of govDefaults) {
      this._db._db.prepare(`
        INSERT OR IGNORE INTO sov_governance_params (param_key, param_value, activated_at)
        VALUES (?, ?, 0)
      `).run(key, val);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  LIST ORDER (seller)
  // ═══════════════════════════════════════════════════════════════════════════

  async handleListOrder(ws, msg) {
    // sov_amount MUST be in seeds (integer). Flutter SDK converts SOV float
    // (e.g. 20.0) to seeds (20_000_000) before sending. Removed the fragile
    // `< 1000` auto-convert heuristic — it silently corrupted any legitimate
    // listing of exactly 1000 SOV or more (stored as 1000 seeds = 0.001 SOV).
    const raw_amount = msg.sov_amount;
    const sov_amount = Math.round(Number(raw_amount) || 0);
    // Sanity bounds: 1 seed minimum, 50M SOV maximum (matches total supply ceiling)
    const MAX_SOV_SEEDS = 50_000_000_000_000;
    if (sov_amount <= 0 || sov_amount > MAX_SOV_SEEDS) {
      this._send(ws, 'XD', { success: false, error: 'INVALID_AMOUNT', type: 'EXCHANGE_ORDER_LISTED' });
      return;
    }
    // Auto-generate order_id if not provided by client
    const order_id = msg.order_id || require('crypto').randomUUID();
    // price_per_sov is optional — OTC description orders use 0
    const price_per_sov = msg.price_per_sov || 0;
    // Accept either expires_in_hours or expires_in_days
    const expires_in_hours = msg.expires_in_hours || ((msg.expires_in_days || 7) * 24);
    const currency_code = msg.currency_code;
    // Accept memo or asking_description as the description field
    const memo = msg.memo || msg.asking_description || '';
    // Stage 2: accepted off-platform fiat payment method(s), e.g. "Bank transfer,
    // Mobile money". Free text so any local rail works; shown to buyers so they
    // know how the seller wants to be paid before negotiating.
    const payment_method = (msg.payment_method || '').toString().slice(0, 200);
    // FIX 2026-06-04: resolve the seller from the authenticated session OR the
    // message payload. Previously seller_id = ws._sovereignId only; if the session
    // id was unset, the INSERT (seller_id NOT NULL) threw AFTER escrow was deducted
    // → no order, no response (app timeout), funds locked. All downstream uses
    // (INSERT, escrow refund, push) now use this resolved id.
    const seller_id = ws._sovereignId || msg.sovereign_id || '';
    global.sovLog.info('[Exchange] LIST_ORDER seller=' + (seller_id ? seller_id.slice(0, 14) : 'EMPTY') +
      ' sov_amount=' + sov_amount + ' memo=' + JSON.stringify((memo || '').slice(0, 24)));

    if (!sov_amount || !seller_id) {
      this._send(ws, 'XD', { success: false, error: 'MISSING_FIELDS', type: 'EXCHANGE_ORDER_LISTED' });
      return;
    }

    // Check max order size (governance param, in SOV not seeds)
    const maxOrderSov = parseInt(this._getGovParam('exchange_max_order_sov', '10000'));
    const amountSov   = sov_amount / 1_000_000;
    if (amountSov > maxOrderSov) {
      this._send(ws, 'XD', { success: false, error: 'ORDER_TOO_LARGE', max_sov: maxOrderSov });
      return;
    }

    // Duplicate order id: refuse BEFORE any money moves.
    if (this._db._db.prepare('SELECT 1 FROM sov_exchange_orders WHERE order_id = ?').get(order_id) ||
        this._db._db.prepare('SELECT 1 FROM sov_exchange_replicas WHERE order_id = ?').get(order_id)) {
      this._send(ws, 'XD', { success: false, error: 'ORDER_ID_EXISTS', type: 'EXCHANGE_ORDER_LISTED' });
      return;
    }

    // Ledger (1.4.90): listing is an OWNER op. The seller's SOV moves into this order's escrow
    // holding only after a majority of nodes granted the seller's next (account, nonce) slot —
    // so a listing and a transfer can never spend the same SOV, wherever each was sent.
    const res = await this._db.ledger.commitOwnerOp({
      kind: 'escrow_list', ref: order_id, owner: { acct: seller_id },
      moves: [{ acct: seller_id, d: -sov_amount }],
      holds: [{ id: 'escrow:' + order_id, d: sov_amount }],
    });
    if (!res.ok) {
      this._send(ws, 'XD', { success: false, type: 'EXCHANGE_ORDER_LISTED',
        error: res.error === 'LEDGER_INSUFFICIENT' ? 'INSUFFICIENT_BALANCE' : res.error });
      return;
    }

    const now       = Date.now();
    const expiresAt = now + Math.min(parseInt(expires_in_hours) || 24 * 7, 24 * 30) * 60 * 60 * 1000;
    try {
      this._db._db.prepare(`
        INSERT INTO sov_exchange_orders
          (order_id, seller_id, sov_amount, price_per_sov, currency_code, status, source_node,
           created_at, updated_at, expires_at, memo, payment_method)
        VALUES (?, ?, ?, ?, ?, 'open', ?, ?, ?, ?, ?, ?)
      `).run(order_id, seller_id, sov_amount, price_per_sov, currency_code || 'USD',
             this._identity.nodeId, now, now, expiresAt, memo || '', payment_method);
    } catch (e) {
      // The escrow is already committed: give it back through the ledger, never silently.
      this._escrowRelease({ order_id, sov_amount }, seller_id, sov_amount, 0, 'escrow_list_undo');
      this._send(ws, 'XD', { success: false, error: 'ORDER_INSERT_FAILED', type: 'EXCHANGE_ORDER_LISTED' });
      return;
    }

    // History: seller's SOV is now escrowed for this listing (their -amount).
    this._recordExchangeTx(`list-${order_id}`, seller_id, 'SOV-EXCHANGE-ESCROW',
      sov_amount, `Exchange listing — funds escrowed (order ${order_id})`);

    const order = this._db._db.prepare('SELECT * FROM sov_exchange_orders WHERE order_id = ?').get(order_id);
    // FIX 2026-06-04: op 'XD' decodes to a different type app-side; without an
    // explicit type the app's sendAndWait('EXCHANGE_ORDER_LISTED') never matches
    // and EVERY successful listing times out (same response-contract bug class as
    // governance V41/V42). Carry the type so the seller gets confirmation.
    this._send(ws, 'XD', { success: true, type: 'EXCHANGE_ORDER_LISTED', order });

    // Push live update to all Browse subscribers
    this._broadcastUpdate(order, 'new');

    // Notify seller: escrow locked
    this._gateway && this._gateway.push(seller_id, 'XS', {   // EXCHANGE_ESCROW_LOCKED
      order_id, sov_amount, ts: now,
    });

    // Broadcast to peers + replicate
    this._peerMesh.broadcast('EXCHANGE_ORDER_BROADCAST', { order, node_id: this._identity.nodeId });
    this._replicateOrder(order);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  FILL ORDER (buyer)
  // ═══════════════════════════════════════════════════════════════════════════

  async handleFillOrder(ws, msg) {
    const { order_id } = msg;
    const buyer_id = ws._sovereignId;

    if (!order_id) {
      this._send(ws, 'XF', { success: false, error: 'MISSING_ORDER_ID' });
      return;
    }
    // The order's home node decides who fills it — first come, once (D27).
    if (await this._forwardToHome(ws, 'fill', msg, 'XF')) return;

    const order = this._db._db.prepare('SELECT * FROM sov_exchange_orders WHERE order_id = ? AND status = ?').get(order_id, 'open');

    if (!order) {
      this._send(ws, 'XF', { success: false, error: 'ORDER_NOT_FOUND_OR_CLOSED' });
      return;
    }

    if (order.seller_id === buyer_id) {
      this._send(ws, 'XF', { success: false, error: 'CANNOT_FILL_OWN_ORDER' });
      return;
    }

    const now = Date.now();
    // Stage 2c "fill at agreed terms": for a negotiable (OTC / price 0) listing,
    // record the price the parties agreed in chat when the buyer fills — so the
    // history and any dispute have the actual number. A fixed-price order keeps
    // its listed price (agreed price is ignored).
    const agreedPrice = Number(msg.agreed_price_per_sov) || 0;
    const recordPrice = (Number(order.price_per_sov) === 0 && agreedPrice > 0)
        ? agreedPrice : order.price_per_sov;
    // Local order — update directly
    this._db._db.prepare(`
      UPDATE sov_exchange_orders SET status = 'filled', filled_by = ?, price_per_sov = ?, updated_at = ? WHERE order_id = ? AND status = 'open'
    `).run(buyer_id, recordPrice, now, order_id);

    // Notify seller of fill
    this._gateway && this._gateway.push(order.seller_id, 'XN', {  // EXCHANGE_ORDER_FILLED_NOTIFY
      order_id, buyer_id, sov_amount: order.sov_amount, ts: now,
    });
    this._replicateOrder({ ...order, status: 'filled', filled_by: buyer_id, price_per_sov: recordPrice, updated_at: now });

    this._send(ws, 'XF', {
      success: true, order_id, sov_amount: order.sov_amount,
      seller_id: order.seller_id, ts: now,
    });

    // Push live update to all Browse subscribers — order no longer open
    this._broadcastUpdate({ ...order, status: 'filled', filled_by: buyer_id, price_per_sov: recordPrice, updated_at: now }, 'updated');

    this._peerMesh.broadcast('EXCHANGE_STATUS_BROADCAST', {
      order_id, status: 'filled', filled_by: buyer_id, updated_at: now,
      node_id: this._identity.nodeId,
    });
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  CONFIRM / REFUND / DISPUTE unified handler
  //
  //  Flutter sends type 'EXCHANGE_CONFIRM_DELIVERY' for ALL three actions,
  //  disambiguated by confirmation_type:
  //    (empty / 'SELLER_CONFIRMS_PAYMENT_RECEIVED') → seller confirms delivery
  //    'BUYER_REQUESTS_REFUND'                      → buyer requests refund
  //    'DISPUTE'                                    → raise exchange dispute
  //
  //  Also directly routable via:
  //    EXCHANGE_CONFIRM (op 'XC') → seller confirms
  //    EXCHANGE_REFUND  (op 'XR') → buyer refund
  // ═══════════════════════════════════════════════════════════════════════════

  async handleConfirmDelivery(ws, msg) {
    if (await this._forwardToHome(ws, 'confirm', msg, 'XC', 'EXCHANGE_DELIVERY_CONFIRMED')) return;
    const { confirmation_type } = msg;
    if (confirmation_type === 'BUYER_REQUESTS_REFUND') {
      return this._handleRefundInternal(ws, msg);
    }
    if (confirmation_type === 'DISPUTE') {
      return this._handleDisputeInternal(ws, msg);
    }
    return this._handleSellerConfirmInternal(ws, msg);
  }

  _handleSellerConfirmInternal(ws, msg) {
    const { order_id } = msg;
    const seller_id    = ws._sovereignId;

    const order = this._db._db.prepare(`
      SELECT * FROM sov_exchange_orders WHERE order_id = ? AND seller_id = ? AND status = 'filled'
    `).get(order_id, seller_id);

    if (!order) {
      this._send(ws, 'XC', { type: 'EXCHANGE_DELIVERY_CONFIRMED', success: false, error: 'ORDER_NOT_FOUND_OR_NOT_FILLED' });
      return;
    }

    const now      = Date.now();
    const feePct   = parseFloat(this._getGovParam('exchange_network_fee', '0.01'));
    const feeSeeds = Math.floor(order.sov_amount * feePct);
    const netSeeds = order.sov_amount - feeSeeds;

    // Ledger (1.4.90): escrow -> buyer (net) and fee -> operator pool as ONE op, released at
    // most once per order (deterministic op id). The status changes only if the money moved.
    const rel = this._escrowRelease(order, order.filled_by, netSeeds, feeSeeds, 'escrow_confirm');
    if (!rel.ok) {
      this._send(ws, 'XC', { type: 'EXCHANGE_DELIVERY_CONFIRMED', success: false, error: rel.error });
      return;
    }
    this._db._db.prepare(`
      UPDATE sov_exchange_orders SET status = 'confirmed', updated_at = ? WHERE order_id = ? AND status = 'filled'
    `).run(now, order_id);

    this._send(ws, 'XC', {
      type: 'EXCHANGE_DELIVERY_CONFIRMED',
      success: true, order_id, released_seeds: netSeeds, fee_seeds: feeSeeds,
    });

    // History (king transparency rule): the buyer's actual credit is NET, but
    // record it as GROSS purchase + an explicit fee line so the fee is visible
    // and the two reconcile to the real balance change (gross − fee = net).
    this._recordExchangeTx(`buy-${order_id}`, 'SOV-EXCHANGE-ESCROW', order.filled_by,
      order.sov_amount, `Exchange purchase (order ${order_id})`);
    if (feeSeeds > 0) {
      this._recordExchangeTx(`fee-${order_id}`, order.filled_by, 'SOV-POOL-WITNESS-OPERATOR',
        feeSeeds, `Exchange network fee (order ${order_id})`);
    }

    // Push live update to all Browse subscribers — order confirmed/closed
    this._broadcastUpdate({ ...order, status: 'confirmed', updated_at: now }, 'removed');

    // Update reputation for both parties
    this._updateReputation(order.seller_id, true, false, false, order.sov_amount);
    this._updateReputation(order.filled_by, true, false, false, order.sov_amount);

    // Notify buyer: SOV received from SOV-SHIELD
    this._gateway && this._gateway.push(order.filled_by, 'SV', {  // SOV_TRANSFER_RECEIVED
      from_id:      'SOV-SHIELD',
      amount:       netSeeds / 1_000_000,   // float SOV — Flutter primary field
      amount_seeds: netSeeds,
      tx_id:        order_id,
      memo:         `Exchange order ${order_id.slice(0, 8)}`,
      ts:           now,
    });

    this._replicateOrder({ ...order, status: 'confirmed', updated_at: now });
    this._peerMesh.broadcast('EXCHANGE_STATUS_BROADCAST', {
      order_id, status: 'confirmed', updated_at: now, node_id: this._identity.nodeId,
    });
  }

  _handleRefundInternal(ws, msg) {
    const { order_id } = msg;
    const buyer_id     = ws._sovereignId;

    const order = this._db._db.prepare(`
      SELECT * FROM sov_exchange_orders WHERE order_id = ? AND filled_by = ? AND status = 'filled'
    `).get(order_id, buyer_id);

    if (!order) {
      this._send(ws, 'XR', { type: 'EXCHANGE_REFUND_PROCESSED', success: false, error: 'ORDER_NOT_FOUND_OR_NOT_REFUNDABLE' });
      return;
    }

    const now = Date.now();
    // Ledger (1.4.90): escrow -> seller, once.
    const rel = this._escrowRelease(order, order.seller_id, order.sov_amount, 0, 'escrow_refund');
    if (!rel.ok) {
      this._send(ws, 'XR', { type: 'EXCHANGE_REFUND_PROCESSED', success: false, error: rel.error });
      return;
    }
    this._recordExchangeTx(`refund-${order_id}`, 'SOV-EXCHANGE-ESCROW', order.seller_id,
      order.sov_amount, `Exchange refund — escrow returned (order ${order_id})`);

    this._db._db.prepare(`
      UPDATE sov_exchange_orders SET status = 'refunded', updated_at = ? WHERE order_id = ?
    `).run(now, order_id);

    this._send(ws, 'XR', { type: 'EXCHANGE_REFUND_PROCESSED', success: true, order_id });

    // Push live update to all Browse subscribers — order refunded/closed
    this._broadcastUpdate({ ...order, status: 'refunded', updated_at: now }, 'removed');

    // Notify seller: refund received
    this._gateway && this._gateway.push(order.seller_id, 'SV', {
      from_id:      'SOV-SHIELD',
      amount:       order.sov_amount / 1_000_000,   // float SOV — Flutter primary field
      amount_seeds: order.sov_amount,
      tx_id:        `refund-${order_id}`,
      memo:         `Refund for order ${order_id.slice(0, 8)}`,
      ts:           now,
    });

    this._replicateOrder({ ...order, status: 'refunded', updated_at: now });
    this._peerMesh.broadcast('EXCHANGE_STATUS_BROADCAST', {
      order_id, status: 'refunded', updated_at: now, node_id: this._identity.nodeId,
    });
  }

  _handleDisputeInternal(ws, msg) {
    const { order_id } = msg;
    const buyer_id = ws._sovereignId;

    const order = this._db._db.prepare(`
      SELECT * FROM sov_exchange_orders WHERE order_id = ? AND filled_by = ? AND status = 'filled'
    `).get(order_id, buyer_id);

    if (!order) {
      this._send(ws, 'XC', { type: 'EXCHANGE_DISPUTE_RAISED', success: false, error: 'ORDER_NOT_FOUND_OR_NOT_DISPUTED' });
      return;
    }

    const now = Date.now();
    this._db._db.prepare(`
      UPDATE sov_exchange_orders SET status = 'disputed', updated_at = ? WHERE order_id = ?
    `).run(now, order_id);

    this._send(ws, 'XC', { type: 'EXCHANGE_DISPUTE_RAISED', success: true, order_id });

    this._replicateOrder({ ...order, status: 'disputed', updated_at: now });
    this._peerMesh.broadcast('EXCHANGE_STATUS_BROADCAST', {
      order_id, status: 'disputed', updated_at: now, node_id: this._identity.nodeId,
    });
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  DIRECT REFUND  (reached via EXCHANGE_REFUND op 'XR' — legacy path)
  // ═══════════════════════════════════════════════════════════════════════════

  async handleRequestRefund(ws, msg) {
    if (await this._forwardToHome(ws, 'refund', msg, 'XR', 'EXCHANGE_REFUND_PROCESSED')) return;
    return this._handleRefundInternal(ws, msg);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  EDIT / CANCEL ORDER
  // ═══════════════════════════════════════════════════════════════════════════

  handleEditOrder(ws, msg) {
    const { order_id, price_per_sov, memo } = msg;
    const seller_id = ws._sovereignId;

    const order = this._db._db.prepare(`
      SELECT * FROM sov_exchange_orders WHERE order_id = ? AND seller_id = ? AND status = 'open'
    `).get(order_id, seller_id);

    if (!order) {
      this._send(ws, 'XE', { success: false, error: 'ORDER_NOT_FOUND_OR_NOT_EDITABLE' });
      return;
    }

    const now = Date.now();
    this._db._db.prepare(`
      UPDATE sov_exchange_orders SET price_per_sov = COALESCE(?, price_per_sov),
        memo = COALESCE(?, memo), updated_at = ?
      WHERE order_id = ?
    `).run(price_per_sov || null, memo !== undefined ? memo : null, now, order_id);

    const updated = this._db._db.prepare('SELECT * FROM sov_exchange_orders WHERE order_id = ?').get(order_id);
    this._send(ws, 'XE', { success: true, order: updated });
    this._broadcastUpdate(updated, 'updated');
    this._replicateOrder(updated);  // also broadcasts EXCHANGE_STATE_REPLICATE to peers
  }

  async handleCancelOrder(ws, msg) {
    if (await this._forwardToHome(ws, 'cancel', msg, 'XX')) return;
    const { order_id } = msg;
    const seller_id    = ws._sovereignId;

    const order = this._db._db.prepare(`
      SELECT * FROM sov_exchange_orders WHERE order_id = ? AND seller_id = ? AND status = 'open'
    `).get(order_id, seller_id);

    if (!order) {
      this._send(ws, 'XX', { success: false, error: 'ORDER_NOT_FOUND_OR_ALREADY_CLOSED' });
      return;
    }

    // Ledger (1.4.90): escrow -> seller, once. Status changes only if the money moved.
    const rel = this._escrowRelease(order, seller_id, order.sov_amount, 0, 'escrow_cancel');
    if (!rel.ok) {
      this._send(ws, 'XX', { success: false, error: rel.error });
      return;
    }
    this._recordExchangeTx(`cancel-${order_id}`, 'SOV-EXCHANGE-ESCROW', seller_id,
      order.sov_amount, `Exchange listing cancelled — escrow returned (order ${order_id})`);

    const now = Date.now();
    this._db._db.prepare(`
      UPDATE sov_exchange_orders SET status = 'cancelled', updated_at = ? WHERE order_id = ?
    `).run(now, order_id);

    this._send(ws, 'XX', { success: true, order_id, returned_seeds: order.sov_amount });
    this._broadcastUpdate({ ...order, status: 'cancelled', updated_at: now }, 'removed');
    this._peerMesh.broadcast('EXCHANGE_STATUS_BROADCAST', {
      order_id, status: 'cancelled', updated_at: now, node_id: this._identity.nodeId,
    });
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  ORDER BOOK + PRICE HISTORY
  // ═══════════════════════════════════════════════════════════════════════════

  handleOrderBook(ws, msg) {
    const { currency_code, limit } = msg;
    const lim  = Math.min(limit || 20, 50);
    const curr = currency_code || 'USD';

    // Aggregate open orders from both local + replicas by price level
    const bids = this._db._db.prepare(`
      SELECT price_per_sov AS price, SUM(sov_amount) AS total_seeds, COUNT(*) AS orders
      FROM sov_exchange_orders
      WHERE status = 'open' AND currency_code = ? AND expires_at > ?
      GROUP BY price_per_sov ORDER BY price_per_sov DESC LIMIT ?
    `).all(curr, Date.now(), lim);

    const replicaBids = this._db._db.prepare(`
      SELECT price_per_sov AS price, SUM(sov_amount) AS total_seeds, COUNT(*) AS orders
      FROM sov_exchange_replicas
      WHERE status = 'open' AND currency_code = ? AND expires_at > ?
        AND source_node != ?
      GROUP BY price_per_sov ORDER BY price_per_sov DESC LIMIT ?
    `).all(curr, Date.now(), this._identity.nodeId, lim);

    // Merge bids from local and replicas at same price points
    const merged = new Map();
    for (const row of [...bids, ...replicaBids]) {
      const key = row.price;
      if (merged.has(key)) {
        const m = merged.get(key);
        m.total_seeds += row.total_seeds;
        m.orders      += row.orders;
      } else {
        merged.set(key, { price: row.price, total_seeds: row.total_seeds, orders: row.orders });
      }
    }

    const allBids = [...merged.values()]
      .sort((a, b) => b.price - a.price)
      .slice(0, lim)
      .map(b => ({ ...b, total_sov: b.total_seeds / 1_000_000 }));

    this._send(ws, 'XO', { bids: allBids, asks: [], ts: Date.now() });
  }

  handlePriceHistory(ws, msg) {
    const { currency_code, limit } = msg;
    const fills = this._db._db.prepare(`
      SELECT price_per_sov AS price, sov_amount AS amount_seeds, updated_at AS filled_at
      FROM sov_exchange_orders
      WHERE status IN ('confirmed','filled') AND currency_code = ?
      ORDER BY updated_at DESC LIMIT ?
    `).all(currency_code || 'USD', Math.min(limit || 50, 200));

    this._send(ws, 'XP', {
      fills: fills.map(f => ({ ...f, amount_sov: f.amount_seeds / 1_000_000 })),
      ts: Date.now(),
    });
  }

  handleMyOrders(ws, msg) {
    const citizen_id = ws._sovereignId;
    const orders     = this._db._db.prepare(`
      SELECT * FROM sov_exchange_orders
      WHERE seller_id = ? OR filled_by = ?
      ORDER BY updated_at DESC LIMIT 50
    `).all(citizen_id, citizen_id);

    this._send(ws, 'XM', { orders, ts: Date.now() });
  }

  // ── EXCHANGE_VIEW_ORDERS — Browse ALL open orders (Flutter Browse tab) ──────
  // Flutter sends type 'EXCHANGE_VIEW_ORDERS', expects responseType 'EXCHANGE_ORDERS_LIST'.
  // Returns all non-expired open orders across local + replicas.
  // Wrapped in try/catch: if any DB query throws, Flutter gets an empty list rather
  // than a silent 10-second sendAndWait timeout.

  handleViewOrders(ws, _msg) {
    try {
      const now   = Date.now();
      const local = this._db._db.prepare(`
        SELECT * FROM sov_exchange_orders
        WHERE status = 'open' AND expires_at > ?
        ORDER BY created_at DESC LIMIT 100
      `).all(now);

      let merged = local;
      try {
        const replicas = this._db._db.prepare(`
          SELECT *, 'replica' AS _src FROM sov_exchange_replicas
          WHERE status = 'open' AND expires_at > ?
            AND source_node != ?
          ORDER BY created_at DESC LIMIT 100
        `).all(now, this._identity.nodeId);
        const seen = new Set(local.map(o => o.order_id));
        merged = [...local, ...replicas.filter(r => !seen.has(r.order_id))];
      } catch (replicaErr) {
        global.sovLog.debug(`[Exchange] replica query skipped: ${replicaErr.message}`);
        // replicas table may not exist on this node — local orders only
      }

      merged.sort((a, b) => b.created_at - a.created_at);
      global.sovLog.debug(`[Exchange] VIEW_ORDERS → ${merged.length} orders`);
      this._send(ws, 'XV', { orders: merged.slice(0, 100), ts: now });
    } catch (err) {
      global.sovLog.warn(`[Exchange] handleViewOrders error: ${err.message}`);
      this._send(ws, 'XV', { orders: [], ts: Date.now(), error: err.message });
    }
  }

  // ── EXCHANGE_VIEW_MY_LISTINGS — Seller's own orders in any status ───────────
  // Flutter sends type 'EXCHANGE_VIEW_MY_LISTINGS', expects 'EXCHANGE_MY_LISTINGS_LIST'.

  handleViewMyListings(ws, msg) {
    try {
      const seller_id = msg.sovereign_id || ws._sovereignId;
      const orders    = this._db._db.prepare(`
        SELECT * FROM sov_exchange_orders
        WHERE seller_id = ?
        ORDER BY updated_at DESC LIMIT 100
      `).all(seller_id);
      global.sovLog.debug(`[Exchange] VIEW_MY_LISTINGS for ${seller_id} → ${orders.length}`);
      this._send(ws, 'XY', { orders, ts: Date.now() });
    } catch (err) {
      global.sovLog.warn(`[Exchange] handleViewMyListings error: ${err.message}`);
      this._send(ws, 'XY', { orders: [], ts: Date.now(), error: err.message });
    }
  }

  // ── EXCHANGE_VIEW_MY_FILLS — Orders filled by this citizen as buyer ──────────
  // Flutter sends type 'EXCHANGE_VIEW_MY_FILLS', expects 'EXCHANGE_MY_FILLS_LIST'.

  handleViewMyFills(ws, msg) {
    try {
      const buyer_id = msg.sovereign_id || ws._sovereignId;
      const orders   = this._db._db.prepare(`
        SELECT * FROM sov_exchange_orders
        WHERE filled_by = ?
        ORDER BY updated_at DESC LIMIT 100
      `).all(buyer_id);
      global.sovLog.debug(`[Exchange] VIEW_MY_FILLS for ${buyer_id} → ${orders.length}`);
      this._send(ws, 'XW', { orders, ts: Date.now() });
    } catch (err) {
      global.sovLog.warn(`[Exchange] handleViewMyFills error: ${err.message}`);
      this._send(ws, 'XW', { orders: [], ts: Date.now(), error: err.message });
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  EXCHANGE CHAT
  // ═══════════════════════════════════════════════════════════════════════════

  // Trade chat is end-to-end and never stored (king, 2026-10-03). The phone encrypts
  // `content` to the recipient's messaging key (a v2 envelope); the node checks the
  // sender is a party, hands it over if the recipient is connected here or on the node
  // their presence names, and says whether it was delivered. Undelivered messages stay
  // on the SENDER's device, which retries. Thread history and the seller's inbox are
  // built on each device. Before 1.4.81 this was plain text, stored, and replicated.
  async handleChatSend(ws, msg) {
    const { order_id, content } = msg;
    const from_id = ws._sovereignId;

    if (ws._legacyMode) { this._send(ws, 'XH', { success: false, error: 'SIGNATURE_REQUIRED' }); return; }
    if (!order_id || !content) {
      this._send(ws, 'XH', { success: false, error: 'MISSING_FIELDS' });
      return;
    }
    if (!isV2Envelope(content)) {
      this._send(ws, 'XH', { success: false, error: 'EXCHANGE_CHAT_PLAINTEXT_REFUSED' });
      return;
    }

    // Verify sender is a party to this order
    const order = this._db._db.prepare(`
      SELECT * FROM sov_exchange_orders WHERE order_id = ?
    `).get(order_id);
    const replica = !order && this._db._db.prepare(`
      SELECT * FROM sov_exchange_replicas WHERE order_id = ?
    `).get(order_id);
    const rec  = order || replica;

    if (!rec) {
      this._send(ws, 'XH', { success: false, error: 'ORDER_NOT_FOUND' });
      return;
    }

    // ── Trade Negotiation (re-engineered 2026-07-20) ─────────────────────────
    // Any citizen may open a (order, buyer) negotiation thread with the seller on an
    // OPEN order; the seller replies into a specific buyer's thread via to_id. The
    // same thread carries straight through fill -> paid -> release.
    const isSeller = rec.seller_id === from_id;
    let to_id;
    if (isSeller) {
      to_id = msg.to_id || rec.filled_by;   // seller replies to a specific buyer (or the filler)
      if (!to_id) {
        this._send(ws, 'XH', { success: false, error: 'NO_BUYER_SPECIFIED' });
        return;
      }
    } else {
      if (rec.status && rec.status !== 'open' && rec.filled_by !== from_id) {
        this._send(ws, 'XH', { success: false, error: 'ORDER_UNAVAILABLE' });
        return;
      }
      to_id = rec.seller_id;
    }
    if (to_id === from_id) {
      this._send(ws, 'XH', { success: false, error: 'CANNOT_MESSAGE_SELF' });
      return;
    }
    // The sender's id lets its device dedupe a retry; otherwise make one.
    const msg_id = (typeof msg.msg_id === 'string' && /^[a-zA-Z0-9_\-]{8,64}$/.test(msg.msg_id))
      ? msg.msg_id : crypto.randomUUID();
    const now = Date.now();
    const buyer_id = isSeller ? to_id : from_id;   // the thread key is (order, buyer)
    const push = { msg_id, order_id, from_id, buyer_id, content, ts: now };

    let status = 'offline';
    if (this._gateway && this._gateway.push(to_id, 'XI', push)) {
      status = 'delivered';
    } else {
      const presence = this._db.getCitizenPresence && this._db.getCitizenPresence(to_id);
      if (presence && presence.status === 'online' && presence.node_id && presence.node_id !== this._identity.nodeId) {
        status = await this._forwardChat(presence.node_id, { ...push, to_id });
      }
    }
    this._send(ws, 'XH', { success: true, msg_id, to_id, buyer_id, status, ts: now });
  }

  _forwardChat(nodeId, payload) {
    return new Promise((resolve) => {
      const timer = setTimeout(() => { this._chatWaiters.delete(payload.msg_id); resolve('offline'); }, 5000);
      this._chatWaiters.set(payload.msg_id, (st) => {
        clearTimeout(timer); this._chatWaiters.delete(payload.msg_id); resolve(st === 'delivered' ? 'delivered' : 'offline');
      });
      const fwd = { ...payload, target_node: nodeId, node_id: this._identity.nodeId };
      if (!this._peerMesh.sendTo || !this._peerMesh.sendTo(nodeId, 'EXCHANGE_CHAT_FORWARD', fwd)) {
        this._peerMesh.broadcast('EXCHANGE_CHAT_FORWARD', fwd);
      }
    });
  }

  _handleChatAck(msg) {
    const { msg_id, status, origin_node } = msg;
    if (origin_node && origin_node !== this._identity.nodeId) return;
    const w = this._chatWaiters.get(msg_id);
    if (w) w(status);
  }

  // History lives on each device; nodes have none. Answered (empty) so an older app
  // does not hang.
  handleChatList(ws, msg) {
    this._send(ws, 'XK', { messages: [], ts: Date.now() });
  }

  // The seller's inbox is built from the seller's own device. Answered (empty) for an
  // older app.
  handleChatThreads(ws, msg) {
    this._send(ws, 'XT', { success: true, order_id: (msg && msg.order_id) || '', threads: [], ts: Date.now() });
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  PEER MESH HANDLERS
  // ═══════════════════════════════════════════════════════════════════════════

  _handleOrderBroadcast(msg) {
    const { order, node_id } = msg;
    if (node_id === this._identity.nodeId || !order) return;
    this._upsertReplica(order);
    // Broadcast new cross-node order to subscribers on this node
    this._broadcastUpdate(order, 'new');
  }

  _handleFillForward(msg) {
    const { order_id, buyer_id, filled_at, node_id } = msg;
    if (!order_id || !buyer_id) return;

    // This is the source node receiving a fill from a remote buyer
    const order = this._db._db.prepare(`
      SELECT * FROM sov_exchange_orders WHERE order_id = ? AND status = 'open'
    `).get(order_id);
    if (!order) return;

    const now = filled_at || Date.now();
    const recordPrice = (msg.price_per_sov != null ? Number(msg.price_per_sov) : order.price_per_sov);
    this._db._db.prepare(`
      UPDATE sov_exchange_orders SET status = 'filled', filled_by = ?, price_per_sov = ?, updated_at = ?
      WHERE order_id = ? AND status = 'open'
    `).run(buyer_id, recordPrice, now, order_id);

    // Notify seller
    this._gateway && this._gateway.push(order.seller_id, 'XN', {
      order_id, buyer_id, sov_amount: order.sov_amount, ts: now,
    });

    this._replicateOrder({ ...order, status: 'filled', filled_by: buyer_id, price_per_sov: recordPrice, updated_at: now });
  }

  _handleStatusBroadcast(msg) {
    const { order_id, status, filled_by, updated_at, node_id } = msg;
    if (node_id === this._identity.nodeId || !order_id) return;

    // Update replica status
    const now = updated_at || Date.now();
    this._db._db.prepare(`
      UPDATE sov_exchange_replicas SET status = ?, filled_by = COALESCE(?, filled_by), updated_at = ?
      WHERE order_id = ?
    `).run(status, filled_by || null, now, order_id);

    // Broadcast status change to subscribers — removed orders are 'removed', others 'updated'
    const replica = this._db._db.prepare('SELECT * FROM sov_exchange_replicas WHERE order_id = ?').get(order_id);
    if (replica) {
      const event = (status === 'cancelled' || status === 'confirmed' || status === 'refunded') ? 'removed' : 'updated';
      this._broadcastUpdate(replica, event);
    }
  }

  _handleStateReplicate(msg) {
    const { order, node_id } = msg;
    if (node_id === this._identity.nodeId || !order) return;
    this._upsertReplica(order);
  }

  _handleChatForward(msg) {
    const { to_id, order_id, from_id, buyer_id, content, msg_id, ts, node_id, target_node } = msg;
    if (node_id === this._identity.nodeId || !to_id || !msg_id) return;
    // Only the addressed node acts. (An untargeted forward is from an older node; nothing
    // is lost by ignoring it - the sender's device still holds the message.)
    if (!target_node || target_node !== this._identity.nodeId) return;
    let status = 'offline';
    if (isV2Envelope(content) && this._gateway &&
        this._gateway.push(to_id, 'XI', { msg_id, order_id, from_id, buyer_id, content, ts })) {
      status = 'delivered';
    }
    const ack = { msg_id, status, origin_node: node_id, answering_node: this._identity.nodeId };
    if (!this._peerMesh.sendTo || !this._peerMesh.sendTo(node_id, 'EXCHANGE_CHAT_ACK', ack)) {
      this._peerMesh.broadcast('EXCHANGE_CHAT_ACK', ack);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  MAINTENANCE
  // ═══════════════════════════════════════════════════════════════════════════

  _cleanupExpiredOrders() {
    const now = Date.now();

    // Find expired open orders on THIS node — return escrow to sellers
    const expired = this._db._db.prepare(`
      SELECT * FROM sov_exchange_orders WHERE status = 'open' AND expires_at < ?
    `).all(now);

    for (const order of expired) {
      const rel = this._escrowRelease(order, order.seller_id, order.sov_amount, 0, 'escrow_expire');
      if (!rel.ok) { global.sovLog.error(`[Exchange] expiry release ${order.order_id} failed: ${rel.error}`); continue; }
      this._recordExchangeTx(`expire-${order.order_id}`, 'SOV-EXCHANGE-ESCROW', order.seller_id,
        order.sov_amount, `Exchange listing expired — escrow returned (order ${order.order_id})`);
      this._db._db.prepare(`
        UPDATE sov_exchange_orders SET status = 'cancelled', updated_at = ? WHERE order_id = ?
      `).run(now, order.order_id);
    }

    if (expired.length > 0) {
      global.sovLog.debug(`Exchange: expired and returned ${expired.length} orders`);
    }

    // Clean up old replica entries
    this._db._db.prepare(`
      DELETE FROM sov_exchange_replicas WHERE status NOT IN ('open','filled') AND updated_at < ?
    `).run(now - 30 * 24 * 60 * 60 * 1000);

    // Clean up exchange chat for closed orders (90 days)
    this._db._db.prepare(`
      DELETE FROM sov_exchange_messages WHERE created_at < ?
    `).run(now - 90 * 24 * 60 * 60 * 1000);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  HELPERS
  // ═══════════════════════════════════════════════════════════════════════════

  _upsertReplica(order) {
    try {
      this._db._db.prepare(`
        INSERT INTO sov_exchange_replicas
          (order_id, seller_id, sov_amount, price_per_sov, currency_code, status,
           filled_by, source_node, created_at, updated_at, expires_at, payment_method, memo)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (order_id) DO UPDATE SET
          status = excluded.status,
          filled_by = excluded.filled_by,
          price_per_sov = excluded.price_per_sov,
          payment_method = excluded.payment_method,
          memo = CASE WHEN sov_exchange_replicas.memo = '' THEN excluded.memo ELSE sov_exchange_replicas.memo END,
          updated_at = excluded.updated_at
        WHERE excluded.updated_at >= sov_exchange_replicas.updated_at
      `).run(
        order.order_id, order.seller_id, order.sov_amount,
        order.price_per_sov, order.currency_code || 'USD', order.status,
        order.filled_by || '', order.source_node || '',
        order.created_at, order.updated_at, order.expires_at, order.payment_method || '',
        typeof order.memo === 'string' ? order.memo.slice(0, 500) : ''
      );
    } catch (_) {}
  }

  _replicateOrder(order) {
    this._peerMesh.broadcast('EXCHANGE_STATE_REPLICATE', {
      order, node_id: this._identity.nodeId,
    });
  }

  // Escrow out of an order's holding: `amountSeeds` to `toAcct`, `feeSeeds` to the operator
  // pool; the two must equal the order amount. One op id per order, so an order's escrow is
  // released at most once, whichever path (confirm/refund/cancel/expire) gets there first.
  _escrowRelease(order, toAcct, amountSeeds, feeSeeds, kind) {
    return this._db.ledger.commitSystemOp({
      op_id: `escrow-release:${order.order_id}`, kind, ref: order.order_id,
      holds: [{ id: 'escrow:' + order.order_id, d: -(amountSeeds + feeSeeds) }],
      moves: [{ acct: toAcct, d: amountSeeds }],
      pools: feeSeeds > 0 ? [{ pool: 'witness_operator', d: feeSeeds }] : [],
    });
  }

  // Orders listed before 1.4.90 hold escrow that is in no account (the seller was debited,
  // nothing was credited — audit D19). Give each such order its escrow holding, once.
  _adoptLegacyEscrow() {
    if (!this._db.ledger) return;
    const rows = this._db._db.prepare(
      "SELECT order_id, sov_amount FROM sov_exchange_orders WHERE status IN ('open','filled','disputed')").all();
    for (const o of rows) {
      if (this._db.holdingBalance('escrow:' + o.order_id) > 0) continue;
      const r = this._db.ledger.commitSystemOp({
        op_id: `escrow-adopt:${o.order_id}`, kind: 'escrow_adopt', ref: o.order_id,
        holds: [{ id: 'escrow:' + o.order_id, d: o.sov_amount }],
      });
      global.sovLog.warn(`[Exchange] adopted pre-1.4.90 escrow of order ${o.order_id}: ${r.ok ? 'ok' : r.error}`);
    }
  }

  // If this node is not the order's home, run the action THERE and hand the citizen the
  // home node's own answer. Returns true when the request was handled (forwarded or refused).
  async _forwardToHome(ws, action, msg, errOp, errType) {
    const orderId = msg && msg.order_id;
    if (!orderId) return false;
    if (this._db._db.prepare('SELECT 1 FROM sov_exchange_orders WHERE order_id = ?').get(orderId)) return false;
    const rep = this._db._db.prepare('SELECT source_node FROM sov_exchange_replicas WHERE order_id = ?').get(orderId);
    const fail = (error) => this._send(ws, errOp, { success: false, error, ...(errType ? { type: errType } : {}) });
    if (!rep || !rep.source_node || rep.source_node === this._identity.nodeId) return false;
    if (msg._forwarded) { fail('ORDER_NOT_FOUND_OR_CLOSED'); return true; }
    const req_id = require('crypto').randomBytes(8).toString('hex');
    const frame = await new Promise((resolve) => {
      this._homeWaiters.set(req_id, resolve);
      const t = setTimeout(() => { if (this._homeWaiters.delete(req_id)) resolve(null); }, 8000);
      if (t.unref) t.unref();
      const sent = this._peerMesh.sendTo(rep.source_node, 'EXCHANGE_HOME_REQUEST', {
        req_id, action, actor: ws._sovereignId, msg: { ...msg, _forwarded: true }, from_node: this._identity.nodeId,
      });
      if (!sent && this._homeWaiters.delete(req_id)) resolve(null);
    });
    if (!frame) { fail('ORDER_HOME_UNREACHABLE'); return true; }
    if (ws && ws.readyState === 1) ws.send(frame);
    return true;
  }

  async _onHomeRequest(msg) {
    if (!msg || !msg.req_id || !msg.from_node || !msg.actor) return;
    const run = { fill: 'handleFillOrder', confirm: 'handleConfirmDelivery',
                  refund: 'handleRequestRefund', cancel: 'handleCancelOrder' }[msg.action];
    if (!run) return;
    const frames = [];
    const proxy = { _sovereignId: msg.actor, readyState: 1, send: (f) => frames.push(f) };
    try { await this[run](proxy, msg.msg || {}); } catch (e) { global.sovLog.warn(`[Exchange] home ${msg.action}: ${e.message}`); }
    this._peerMesh.sendTo(msg.from_node, 'EXCHANGE_HOME_REPLY', { req_id: msg.req_id, frame: frames[0] || null });
  }

  _onHomeReply(msg) {
    const resolve = msg && this._homeWaiters.get(msg.req_id);
    if (resolve) { this._homeWaiters.delete(msg.req_id); resolve(msg.frame); }
  }

  // 1.4.90: no direct balance helpers — every exchange money move is a ledger op (_escrowRelease,
  // and the listing in handleListOrder).

  _getGovParam(key, fallback = '0') {
    const row = this._db._db.prepare(
      'SELECT param_value FROM sov_governance_params WHERE param_key = ?'
    ).get(key);
    return row ? row.param_value.toString() : fallback.toString();
  }

  // Payment-history record for an exchange money movement (king transparency
  // rule 2026-07-19: every in/out must show its source + destination). The
  // exchange escrow account is the synthetic SOV-EXCHANGE-ESCROW; fees route to
  // SOV-POOL-WITNESS-OPERATOR. Deterministic tx_id → INSERT OR IGNORE dedups.
  _recordExchangeTx(suffix, fromId, toId, amountSeeds, memo) {
    if (amountSeeds <= 0 || !this._db.insertTransaction) return;
    try {
      const crypto = require('crypto');
      const txId   = `exch-${suffix}`;
      this._db.insertTransaction({
        tx_id:        txId,
        tx_hash:      crypto.createHash('sha256').update(`${txId}:${amountSeeds}`).digest('hex'),
        from_id:      fromId,
        to_id:        toId,
        amount_seeds: amountSeeds,
        memo,
        status:       'confirmed',
        confirmed_at: Date.now(),
        created_at:   Date.now(),
      });
    } catch (e) {
      global.sovLog.warn(`[Exchange] tx-history record failed: ${e.message}`);
    }
  }

  _send(ws, op, payload) {
    if (!ws || ws.readyState !== 1) return;
    // payload.type takes priority (handlers that return a different type than
    // the request op use this — e.g. EXCHANGE_CONFIRM → EXCHANGE_DELIVERY_CONFIRMED).
    // Fall back to static result-type map, then op code itself.
    const type = payload.type || ExchangeEngine._RESULT_TYPE[op] || op;
    ws.send(JSON.stringify({ op, type, ...payload }));
  }

  // Static map: exchange op code used in _send() → Flutter-expected response type.
  // Flutter's sendAndWait matches on msg['type'], not op code, so every response
  // must carry the type string that the caller's responseType parameter expects.
  static get _RESULT_TYPE() {
    return {
      'XD': 'EXCHANGE_ORDER_LISTED',            // handleListOrder error (odd op, kept for compat)
      'XL': 'EXCHANGE_ORDER_LISTED',            // handleListOrder success
      'XF': 'EXCHANGE_ORDER_FILLED',            // handleFillOrder
      'XC': 'EXCHANGE_DELIVERY_CONFIRMED',      // handleConfirmDelivery (seller path)
      'XR': 'EXCHANGE_REFUND_PROCESSED',        // handleRequestRefund direct
      'XE': 'EXCHANGE_ORDER_EDITED',            // handleEditOrder
      'XX': 'EXCHANGE_ORDER_CANCELLED',         // handleCancelOrder
      'XO': 'EXCHANGE_ORDER_BOOK_RESULT',       // handleOrderBook
      'XP': 'EXCHANGE_PRICE_HISTORY_RESULT',    // handlePriceHistory
      'XM': 'EXCHANGE_ORDERS_LIST',             // handleMyOrders (legacy)
      'XV': 'EXCHANGE_ORDERS_LIST',             // handleViewOrders (browse all open)
      'XY': 'EXCHANGE_MY_LISTINGS_LIST',        // handleViewMyListings (seller's orders)
      'XW': 'EXCHANGE_MY_FILLS_LIST',           // handleViewMyFills (buyer fills)
      'XH': 'EXCHANGE_CHAT_SEND_RESULT',        // handleChatSend
      'XK': 'EXCHANGE_CHAT_LIST_RESULT',        // handleChatList
      'XI': 'EXCHANGE_CHAT_INCOMING',           // push: live chat delivery (distinct from XK list result)
      'XT': 'EXCHANGE_CHAT_THREADS_RESULT',     // handleChatThreads (seller negotiation inbox)
      'XN': 'EXCHANGE_ORDER_FILLED_NOTIFY',     // push to seller on fill
      'XS': 'EXCHANGE_ESCROW_LOCKED',           // push to seller on list
      'XB': 'EXCHANGE_STATE',                   // push: full open order list on subscribe
      'XU': 'EXCHANGE_ORDER_UPDATE',            // push: single order change to subscribers
      'XQ': 'EXCHANGE_UNSUBSCRIBED',            // ack on unsubscribe
      'XZ': 'EXCHANGE_VIEW_REPUTATION',         // handleViewReputation
    };
  }
  // ── Exchange Reputation ────────────────────────────────────────────────────
  // Score formula: base 100 + min(trades_completed × 2, 50) − disputes_lost × 10
  // Clamped to [0, 150]. Called after confirmed delivery or a resolved dispute.

  _updateReputation(sovereignId, tradeCompleted, disputeFiled, disputeWon, sovAmount) {
    try {
      const now     = Date.now();
      const tcDelta = tradeCompleted ? 1 : 0;
      const tdDelta = disputeFiled   ? 1 : 0;
      const dwDelta = disputeWon     ? 1 : 0;
      const dlDelta = (disputeFiled && !disputeWon) ? 1 : 0;
      const sovDelta = sovAmount || 0;
      this._db._db.prepare(`
        INSERT INTO sov_reputation
          (sovereign_id, trades_completed, trades_disputed, disputes_won, disputes_lost, total_sov_traded, reputation_score, last_updated)
        VALUES (?, ?, ?, ?, ?, ?, 100, ?)
        ON CONFLICT(sovereign_id) DO UPDATE SET
          trades_completed = trades_completed + ?,
          trades_disputed  = trades_disputed  + ?,
          disputes_won     = disputes_won     + ?,
          disputes_lost    = disputes_lost    + ?,
          total_sov_traded = total_sov_traded + ?,
          last_updated     = ?
      `).run(
        sovereignId, tcDelta, tdDelta, dwDelta, dlDelta, sovDelta, now,
        tcDelta, tdDelta, dwDelta, dlDelta, sovDelta, now
      );
      const rep = this._db._db.prepare('SELECT * FROM sov_reputation WHERE sovereign_id = ?').get(sovereignId);
      if (rep) {
        const score = Math.max(0, Math.min(150, 100 + Math.min(rep.trades_completed * 2, 50) - rep.disputes_lost * 10));
        this._db._db.prepare('UPDATE sov_reputation SET reputation_score = ? WHERE sovereign_id = ?').run(score, sovereignId);
      }
    } catch (e) {
      global.sovLog.warn('[Exchange] updateReputation error:', e.message);
    }
  }

  _getReputation(sovereignId) {
    try {
      return this._db._db.prepare('SELECT * FROM sov_reputation WHERE sovereign_id = ?').get(sovereignId)
        || { sovereign_id: sovereignId, trades_completed: 0, trades_disputed: 0,
             disputes_won: 0, disputes_lost: 0, total_sov_traded: 0,
             reputation_score: 100, last_updated: null };
    } catch (e) {
      return { sovereign_id: sovereignId, trades_completed: 0, trades_disputed: 0,
               disputes_won: 0, disputes_lost: 0, total_sov_traded: 0,
               reputation_score: 100, last_updated: null };
    }
  }

  handleViewReputation(ws, msg) {
    const sovereignId = msg.sovereign_id || ws._sovereignId;
    if (!sovereignId) {
      return this._send(ws, 'XZ', { success: false, error: 'Missing sovereign_id' });
    }
    const rep = this._getReputation(sovereignId);
    this._send(ws, 'XZ', {
      type:             'EXCHANGE_REPUTATION',
      success:          true,
      sovereign_id:     rep.sovereign_id,
      trades_completed: rep.trades_completed,
      trades_disputed:  rep.trades_disputed,
      disputes_won:     rep.disputes_won,
      disputes_lost:    rep.disputes_lost,
      total_sov_traded: rep.total_sov_traded,
      reputation_score: rep.reputation_score,
      last_updated:     rep.last_updated,
      timestamp:        Date.now(),
    });
  }

}

module.exports = { ExchangeEngine };
