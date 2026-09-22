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
      `ALTER TABLE sov_exchange_messages ADD COLUMN buyer_id TEXT NOT NULL DEFAULT ''`,
      `ALTER TABLE sov_exchange_messages ADD COLUMN read_ts  INTEGER`,
    ];
    for (const sql of _migrations) {
      try { this._db._db.exec(sql); } catch (_) { /* column already exists */ }
    }
    this._db._db.exec(`CREATE INDEX IF NOT EXISTS idx_xchat_buyer ON sov_exchange_messages(order_id, buyer_id)`);

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

  handleListOrder(ws, msg) {
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

    // Lock escrow: deduct from seller's spendable balance
    // Fallback: if ws._sovereignId is somehow null, accept msg.sovereign_id
    const resolvedSellerId = seller_id || msg.sovereign_id || '';
    global.sovLog.debug('[Exchange] LIST_ORDER seller=' + resolvedSellerId + ' amount=' + sov_amount + ' ws._sov=' + seller_id);
    const disc = this._db.readDisc(resolvedSellerId);
    global.sovLog.debug('[Exchange] disc=' + JSON.stringify(disc ? {b: disc.balance_seeds, s: disc.spendable_seeds, v: disc.version} : null));
    const escrowed = this._deductBalance(resolvedSellerId, sov_amount);
    global.sovLog.debug('[Exchange] deduct result=' + escrowed);
    if (!escrowed) {
      this._send(ws, 'XD', { success: false, error: 'INSUFFICIENT_BALANCE', type: 'EXCHANGE_ORDER_LISTED' });
      return;
    }

    const now       = Date.now();
    const expiresAt = now + Math.min(parseInt(expires_in_hours) || 24 * 7, 24 * 30) * 60 * 60 * 1000;

    const insertResult = this._db._db.prepare(`
        INSERT OR IGNORE INTO sov_exchange_orders
          (order_id, seller_id, sov_amount, price_per_sov, currency_code, status, source_node,
           created_at, updated_at, expires_at, memo, payment_method)
        VALUES (?, ?, ?, ?, ?, 'open', ?, ?, ?, ?, ?, ?)
      `).run(order_id, seller_id, sov_amount, price_per_sov, currency_code || 'USD',
             this._identity.nodeId, now, now, expiresAt, memo || '', payment_method);
    if (insertResult.changes === 0) {
      // ORDER_ID already exists — INSERT OR IGNORE silently ignored; return escrow
      this._creditBalance(seller_id, sov_amount);
      this._send(ws, 'XD', { success: false, error: 'ORDER_ID_EXISTS', type: 'EXCHANGE_ORDER_LISTED' });
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

  handleFillOrder(ws, msg) {
    const { order_id } = msg;
    const buyer_id = ws._sovereignId;

    if (!order_id) {
      this._send(ws, 'XF', { success: false, error: 'MISSING_ORDER_ID' });
      return;
    }

    // Check local orders first, then replicas
    let order = this._db._db.prepare('SELECT * FROM sov_exchange_orders WHERE order_id = ? AND status = ?').get(order_id, 'open');
    const isReplica = !order;
    if (isReplica) {
      order = this._db._db.prepare('SELECT * FROM sov_exchange_replicas WHERE order_id = ? AND status = ?').get(order_id, 'open');
    }

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
    if (isReplica) {
      // Update replica status locally
      this._db._db.prepare(`
        UPDATE sov_exchange_replicas SET status = 'filled', filled_by = ?, price_per_sov = ?, updated_at = ? WHERE order_id = ?
      `).run(buyer_id, recordPrice, now, order_id);

      // Forward fill to source node
      this._peerMesh.sendTo(order.source_node, 'EXCHANGE_FILL_FORWARD', {
        order_id, buyer_id, filled_at: now, price_per_sov: recordPrice, node_id: this._identity.nodeId,
      });
    } else {
      // Local order — update directly
      this._db._db.prepare(`
        UPDATE sov_exchange_orders SET status = 'filled', filled_by = ?, price_per_sov = ?, updated_at = ? WHERE order_id = ? AND status = 'open'
      `).run(buyer_id, recordPrice, now, order_id);

      // Notify seller of fill
      this._gateway && this._gateway.push(order.seller_id, 'XN', {  // EXCHANGE_ORDER_FILLED_NOTIFY
        order_id, buyer_id, sov_amount: order.sov_amount, ts: now,
      });
      this._replicateOrder({ ...order, status: 'filled', filled_by: buyer_id, price_per_sov: recordPrice, updated_at: now });
    }

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

  handleConfirmDelivery(ws, msg) {
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

    // Credit buyer
    this._creditBalance(order.filled_by, netSeeds);

    // Route the network fee to the operator pool (supply-neutral) instead of
    // silently burning it — consistent with platform_register_fee / tx_fee routing.
    // Fail CLOSED — this previously swallowed every error with catch(_) {},
    // so a failed credit destroyed the fee with no record at all.
    if (feeSeeds > 0 && this._db.addToPoolOrRecord) {
      this._db.addToPoolOrRecord('witness_operator', feeSeeds, { source: 'exchange' });
    } else if (feeSeeds > 0 && this._db.addToPool) {
      this._db.addToPool('witness_operator', feeSeeds);
    }

    // Update order
    this._db._db.prepare(`
      UPDATE sov_exchange_orders SET status = 'confirmed', updated_at = ? WHERE order_id = ?
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
    // Return escrow to seller
    this._creditBalance(order.seller_id, order.sov_amount);
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

  handleRequestRefund(ws, msg) {
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

  handleCancelOrder(ws, msg) {
    const { order_id } = msg;
    const seller_id    = ws._sovereignId;

    const order = this._db._db.prepare(`
      SELECT * FROM sov_exchange_orders WHERE order_id = ? AND seller_id = ? AND status = 'open'
    `).get(order_id, seller_id);

    if (!order) {
      this._send(ws, 'XX', { success: false, error: 'ORDER_NOT_FOUND_OR_ALREADY_CLOSED' });
      return;
    }

    // Return escrow to seller
    this._creditBalance(seller_id, order.sov_amount);
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

  handleChatSend(ws, msg) {
    const { order_id, content } = msg;
    const from_id = ws._sovereignId;

    if (!order_id || !content) {
      this._send(ws, 'XH', { success: false, error: 'MISSING_FIELDS' });
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
    // A P2P SOV⇄fiat marketplace: buyers must reach the seller to agree a price
    // and arrange the off-platform fiat payment BEFORE they fill. So ANY citizen
    // may open a (order, buyer) negotiation thread with the seller on an OPEN
    // order; the seller replies into a specific buyer's thread via to_id. The
    // same thread carries straight through fill → paid → release.
    const isSeller = rec.seller_id === from_id;
    let to_id;
    if (isSeller) {
      to_id = msg.to_id || rec.filled_by;   // seller replies to a specific buyer (or the filler)
      if (!to_id) {
        this._send(ws, 'XH', { success: false, error: 'NO_BUYER_SPECIFIED' });
        return;
      }
    } else {
      // Prospective/actual buyer → seller. Allowed while the order is open, or if
      // this buyer already filled it (post-fill trade chat).
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
    const msg_id  = crypto.randomUUID();
    const now     = Date.now();
    // The thread key is (order, buyer): buyer_id is always the non-seller party.
    const buyer_id = isSeller ? to_id : from_id;

    this._db._db.prepare(`
      INSERT OR IGNORE INTO sov_exchange_messages (msg_id, order_id, from_id, to_id, buyer_id, content, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    `).run(msg_id, order_id, from_id, to_id, buyer_id, content, now);

    this._send(ws, 'XH', { success: true, msg_id, ts: now });

    // Deliver to recipient if online. NOTE: op code 'XI' (EXCHANGE_CHAT_INCOMING)
    // is distinct from 'XK' (EXCHANGE_CHAT_LIST_RESULT) — earlier code reused 'XK'
    // for live pushes, which Flutter routed as a list-result and silently dropped
    // the incoming message. Use the dedicated 'XI' op so Flutter's listener fires.
    const delivered = this._gateway && this._gateway.push(to_id, 'XI', {
      msg_id, order_id, from_id, content, ts: now,
    });

    if (!delivered) {
      // Forward to peer node
      this._peerMesh.broadcast('EXCHANGE_CHAT_FORWARD', {
        to_id, order_id, from_id, content, msg_id, ts: now,
        node_id: this._identity.nodeId,
      });
    }
  }

  handleChatList(ws, msg) {
    const { order_id } = msg;
    if (!order_id) return;
    const me = ws._sovereignId;

    // Scope the thread to (order, buyer). A buyer sees ONLY their own thread with
    // the seller (never other buyers' negotiations). A seller passes buyer_id to
    // view one buyer's thread; without it a seller gets the whole order (interim,
    // until the seller inbox lands).
    const order = this._db._db.prepare(`SELECT seller_id FROM sov_exchange_orders WHERE order_id = ?`).get(order_id)
              || this._db._db.prepare(`SELECT seller_id FROM sov_exchange_replicas WHERE order_id = ?`).get(order_id);
    const isSeller = order && order.seller_id === me;

    // Thread key = (order, buyer_id). Buyer views their own thread; seller passes
    // a buyer_id to open one buyer's thread (from the negotiation inbox).
    const thread_buyer = isSeller ? (msg.buyer_id || null) : me;
    let messages;
    if (thread_buyer) {
      messages = this._db._db.prepare(`
        SELECT * FROM sov_exchange_messages
        WHERE order_id = ? AND buyer_id = ? ORDER BY created_at ASC LIMIT 200
      `).all(order_id, thread_buyer);
      // Mark inbound messages to me in this thread as read (drives unread badges).
      this._db._db.prepare(`
        UPDATE sov_exchange_messages SET read_ts = ?
        WHERE order_id = ? AND buyer_id = ? AND to_id = ? AND read_ts IS NULL
      `).run(Date.now(), order_id, thread_buyer, me);
    } else {
      // Seller with no buyer_id: whole order (fallback).
      messages = this._db._db.prepare(`
        SELECT * FROM sov_exchange_messages WHERE order_id = ? ORDER BY created_at ASC LIMIT 200
      `).all(order_id);
    }

    // NOTE: use 'XK' (EXCHANGE_CHAT_LIST) not 'XL' (EXCHANGE_LIST_ORDER)
    this._send(ws, 'XK', { messages, ts: Date.now() });
  }

  // ── Seller negotiation inbox: the distinct buyer threads for one order ───────
  //  Seller-only. Returns one row per interested buyer with the last message, its
  //  time, and how many of that buyer's messages the seller hasn't read yet.
  handleChatThreads(ws, msg) {
    const { order_id } = msg;
    if (!order_id) return;
    const me = ws._sovereignId;
    const order = this._db._db.prepare(`SELECT seller_id FROM sov_exchange_orders WHERE order_id = ?`).get(order_id)
              || this._db._db.prepare(`SELECT seller_id FROM sov_exchange_replicas WHERE order_id = ?`).get(order_id);
    if (!order || order.seller_id !== me) {
      this._send(ws, 'XT', { success: false, error: 'NOT_THE_SELLER', threads: [] });
      return;
    }
    const rows = this._db._db.prepare(`
      SELECT buyer_id,
             COUNT(*)                                          AS message_count,
             MAX(created_at)                                   AS last_ts,
             SUM(CASE WHEN to_id = ? AND read_ts IS NULL THEN 1 ELSE 0 END) AS unread
      FROM sov_exchange_messages
      WHERE order_id = ? AND buyer_id != ''
      GROUP BY buyer_id
      ORDER BY last_ts DESC LIMIT 100
    `).all(me, order_id);
    // Attach each thread's last message text + the buyer's reputation.
    const threads = rows.map(r => {
      const last = this._db._db.prepare(`
        SELECT content, from_id FROM sov_exchange_messages
        WHERE order_id = ? AND buyer_id = ? ORDER BY created_at DESC, rowid DESC LIMIT 1
      `).get(order_id, r.buyer_id);
      const rep = this._db._db.prepare(`SELECT reputation_score, trades_completed FROM sov_reputation WHERE sovereign_id = ?`).get(r.buyer_id);
      return {
        buyer_id: r.buyer_id, message_count: r.message_count, last_ts: r.last_ts,
        unread: r.unread, last_content: last ? last.content : '',
        last_from_me: last ? (last.from_id === me) : false,
        reputation_score: rep ? rep.reputation_score : 100,
        trades_completed: rep ? rep.trades_completed : 0,
      };
    });
    this._send(ws, 'XT', { success: true, order_id, threads, ts: Date.now() });
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
    const { to_id, order_id, from_id, content, msg_id, ts, node_id } = msg;
    if (node_id === this._identity.nodeId || !to_id) return;

    // Store and deliver to local citizen if online
    try {
      // buyer_id = the non-seller party (needed for the seller inbox/threads).
      // Without it, a forwarded message lands with buyer_id='' and is invisible
      // to handleChatThreads (which requires buyer_id != '').
      let _bId = '';
      try {
        const _ord = this._db._db.prepare('SELECT seller_id FROM sov_exchange_orders WHERE order_id = ?').get(order_id)
                  || this._db._db.prepare('SELECT seller_id FROM sov_exchange_replicas WHERE order_id = ?').get(order_id);
        if (_ord) _bId = (from_id === _ord.seller_id) ? to_id : from_id;
      } catch (_) {}
      this._db._db.prepare(`
        INSERT OR IGNORE INTO sov_exchange_messages (msg_id, order_id, from_id, to_id, buyer_id, content, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
      `).run(msg_id || crypto.randomUUID(), order_id, from_id, to_id, _bId, content, ts || Date.now());
    } catch (_) {}

    this._gateway && this._gateway.push(to_id, 'XI', {
      msg_id, order_id, from_id, content, ts,
    });
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
      this._creditBalance(order.seller_id, order.sov_amount);
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
           filled_by, source_node, created_at, updated_at, expires_at, payment_method)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (order_id) DO UPDATE SET
          status = excluded.status,
          filled_by = excluded.filled_by,
          price_per_sov = excluded.price_per_sov,
          payment_method = excluded.payment_method,
          updated_at = excluded.updated_at
        WHERE excluded.updated_at >= sov_exchange_replicas.updated_at
      `).run(
        order.order_id, order.seller_id, order.sov_amount,
        order.price_per_sov, order.currency_code || 'USD', order.status,
        order.filled_by || '', order.source_node || '',
        order.created_at, order.updated_at, order.expires_at, order.payment_method || ''
      );
    } catch (_) {}
  }

  _replicateOrder(order) {
    this._peerMesh.broadcast('EXCHANGE_STATE_REPLICATE', {
      order, node_id: this._identity.nodeId,
    });
  }

  _deductBalance(citizenId, amountSeeds) {
    for (let attempt = 0; attempt < 3; attempt++) {
      const disc = this._db.readDisc(citizenId);
      if (!disc || disc.spendable_seeds < amountSeeds) return false;
      const result = this._db._db.prepare(`
        UPDATE sov_disc
        SET balance_seeds  = balance_seeds  - ?,
            spendable_seeds = spendable_seeds - ?,
            version = version + 1,
            updated_at = ?
        WHERE sovereign_id = ? AND version = ? AND spendable_seeds >= ?
      `).run(amountSeeds, amountSeeds, Date.now(), citizenId, disc.version, amountSeeds);
      if (result.changes > 0) return true;
    }
    return false;
  }

  _creditBalance(citizenId, amountSeeds) {
    for (let attempt = 0; attempt < 3; attempt++) {
      const disc = this._db.readDisc(citizenId);
      if (!disc) return false;
      const result = this._db._db.prepare(`
        UPDATE sov_disc
        SET balance_seeds   = balance_seeds   + ?,
            spendable_seeds = spendable_seeds + ?,
            version = version + 1,
            updated_at = ?
        WHERE sovereign_id = ? AND version = ?
      `).run(amountSeeds, amountSeeds, Date.now(), citizenId, disc.version);
      if (result.changes > 0) return true;
    }
    return false;
  }

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
