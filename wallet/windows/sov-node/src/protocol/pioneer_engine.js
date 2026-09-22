'use strict';
// ── Pioneer Engine ─────────────────────────────────────────────────────────────
// Handles the Pioneer Program: referral codes, rank certification, and
// specialisation assessments. Citizens earn SOV by referring new enrollees
// with their pioneer code. Certified pioneers unlock higher earning tiers.
//
// Pioneer pool: 5,000,000 SOV reserved for referral rewards.
// Reward tiers (based on remaining pool):
//   pool > 500,000 SOV → 50 SOV per successful referral
//   pool > 100,000 SOV → 25 SOV per successful referral
//   pool <= 100,000 SOV → 12 SOV per successful referral
//
// Certifications (via 15-question, 85%-pass-mark assessment):
//   relay_engineer, enrollment_agent, protocol_specialist
//
// Ranks: apprentice → pioneer → senior → master
//   - Apprentice: registered (no cert, no referrals)
//   - Pioneer: 1+ referrals
//   - Senior: 25+ referrals
//   - Master: 100+ referrals OR all 3 certs

const crypto = require('crypto');

class PioneerEngine {
  constructor(identity, db) {
    this._identity = identity;
    this._db       = db;
  }

  // ── PIONEER_VERIFY — pre-enrollment code validation ────────────────────────
  // Called BEFORE enrollment to validate a pioneer code.
  // Exempt from auth — pre-enrolled phone sends this.
  handleVerify(ws, msg) {
    const { pioneer_code } = msg;
    if (!pioneer_code) {
      return ws.send(JSON.stringify({
        type: 'PIONEER_VERIFY_RESPONSE', valid: false,
        pioneer_code: pioneer_code || '', bonus_sov: 0, timestamp: Date.now(),
      }));
    }
    try {
      const pioneer = this._db._db.prepare(
        'SELECT sovereign_id FROM sov_pioneers WHERE pioneer_code = ?'
      ).get(pioneer_code);
      const remaining = this._db.getPioneerPoolRemaining();
      const bonusSov = !pioneer ? 0
        : remaining > 500000 ? 50
        : remaining > 100000 ? 25
        : remaining > 0      ? 12
        : 0;

      ws.send(JSON.stringify({
        type:         'PIONEER_VERIFY_RESPONSE',
        valid:        !!pioneer,
        pioneer_code,
        bonus_sov:    bonusSov,
        timestamp:    Date.now(),
      }));
    } catch (e) {
      ws.send(JSON.stringify({ type: 'PIONEER_VERIFY_RESPONSE', valid: false, error: e.message, timestamp: Date.now() }));
    }
  }

  // ── PIONEER_REGISTER — enroll as a pioneer, get a referral code ───────────
  handleRegister(ws, msg) {
    const sovereignId = msg.sovereign_id || ws._sovereignId;
    if (!sovereignId) {
      return ws.send(JSON.stringify({ type: 'PIONEER_REGISTERED', success: false, error: 'No sovereign_id' }));
    }
    try {
      const enrollment = this._db._db.prepare(
        'SELECT sovereign_id FROM sov_enrollments WHERE sovereign_id = ?'
      ).get(sovereignId);
      if (!enrollment) {
        return ws.send(JSON.stringify({ type: 'PIONEER_REGISTERED', success: false, error: 'Sovereign not enrolled' }));
      }

      // Generate deterministic pioneer code: first 8 chars of SHA-256(sovereignId + timestamp)
      const base       = crypto.createHash('sha256')
        .update(sovereignId + Date.now().toString())
        .digest('hex').substring(0, 8).toUpperCase();
      const pioneerCode = `PI-${base}`;

      this._db._db.prepare(`
        INSERT INTO sov_pioneers (sovereign_id, pioneer_code, referral_count, total_earned, registered_at)
        VALUES (?, ?, 0, 0, ?)
        ON CONFLICT(sovereign_id) DO NOTHING
      `).run(sovereignId, pioneerCode, Math.floor(Date.now() / 1000));

      // Re-fetch (code may differ if already registered)
      const record = this._db._db.prepare('SELECT * FROM sov_pioneers WHERE sovereign_id = ?').get(sovereignId);
      const code   = record ? record.pioneer_code : pioneerCode;

      global.sovLog.info(`[PIONEER] Registered: ${sovereignId} | code: ${code}`);
      ws.send(JSON.stringify({
        type:         'PIONEER_REGISTERED',
        success:      true,
        sovereign_id: sovereignId,
        pioneer_code: code,
        timestamp:    Date.now(),
      }));
    } catch (e) {
      global.sovLog.error('[PIONEER] Register error:', e.message);
      ws.send(JSON.stringify({ type: 'PIONEER_REGISTERED', success: false, error: e.message }));
    }
  }

  // ── PIONEER_GET_STATUS — rank, certs, earnings, attempt history ────────────
  handleGetStatus(ws, msg) {
    const { sovereign_id } = msg;
    if (!sovereign_id) {
      return ws.send(JSON.stringify({ type: 'PIONEER_STATUS_RESULT', success: false, error: 'MISSING_SOVEREIGN_ID' }));
    }
    try {
      const pioneer = this._db._db.prepare(
        'SELECT * FROM sov_pioneers WHERE sovereign_id = ?'
      ).get(sovereign_id);

      const attempts = {};
      for (const spec of ['relay_engineer', 'enrollment_agent', 'protocol_specialist']) {
        const last = this._db._db.prepare(
          'SELECT COUNT(*) as count, MAX(started_at) as last_at FROM sov_pioneer_assessments WHERE sovereign_id = ? AND specialisation = ? AND passed = 0'
        ).get(sovereign_id, spec);
        attempts[spec] = {
          failed_count: last ? last.count : 0,
          last_attempt: last ? last.last_at : null,
        };
      }

      ws.send(JSON.stringify({
        type:         'PIONEER_STATUS_RESULT',
        success:      true,
        sovereign_id,
        is_pioneer:   !!(pioneer && (pioneer.cert_relay_engineer || pioneer.cert_enrollment_agent || pioneer.cert_protocol_specialist)),
        pioneer_code: pioneer ? pioneer.pioneer_code : null,
        rank:         pioneer ? (pioneer.rank || 'apprentice') : null,
        certs: {
          relay_engineer:       !!(pioneer && pioneer.cert_relay_engineer),
          enrollment_agent:     !!(pioneer && pioneer.cert_enrollment_agent),
          protocol_specialist:  !!(pioneer && pioneer.cert_protocol_specialist),
        },
        relay_engineer_at:      pioneer ? pioneer.relay_engineer_at      : null,
        enrollment_agent_at:    pioneer ? pioneer.enrollment_agent_at    : null,
        protocol_specialist_at: pioneer ? pioneer.protocol_specialist_at : null,
        referral_count:         pioneer ? (pioneer.referral_count || 0) : 0,
        total_earned_seeds:     pioneer ? (pioneer.total_earned_seeds || 0) : 0,
        assessment_attempts:    attempts,
        pool_remaining:         this._db.getPioneerPoolRemaining(),
        timestamp:              Date.now(),
      }));
    } catch (e) {
      global.sovLog.error('[PIONEER] GetStatus error:', e.message);
      ws.send(JSON.stringify({ type: 'PIONEER_STATUS_RESULT', success: false, error: e.message }));
    }
  }

  // ── PIONEER_START_ASSESSMENT — begin a specialisation quiz ────────────────
  handleStartAssessment(ws, msg) {
    const { sovereign_id, specialisation } = msg;
    const validSpecs = ['relay_engineer', 'enrollment_agent', 'protocol_specialist'];

    if (!sovereign_id || !specialisation) {
      return ws.send(JSON.stringify({ type: 'PIONEER_ASSESSMENT_STARTED', success: false, error: 'MISSING_FIELDS' }));
    }
    if (!validSpecs.includes(specialisation)) {
      return ws.send(JSON.stringify({ type: 'PIONEER_ASSESSMENT_STARTED', success: false, error: 'INVALID_SPECIALISATION' }));
    }

    try {
      const pioneer  = this._db._db.prepare('SELECT * FROM sov_pioneers WHERE sovereign_id = ?').get(sovereign_id);
      const certField = 'cert_' + specialisation;
      if (pioneer && pioneer[certField]) {
        return ws.send(JSON.stringify({ type: 'PIONEER_ASSESSMENT_STARTED', success: false, error: 'ALREADY_CERTIFIED', specialisation }));
      }

      // Cooldown: 3 fails within 48 hours
      const recentFails = this._db._db.prepare(
        'SELECT COUNT(*) as count FROM sov_pioneer_assessments WHERE sovereign_id = ? AND specialisation = ? AND passed = 0 AND started_at > ?'
      ).get(sovereign_id, specialisation, Date.now() - 172800000);

      if (recentFails && recentFails.count >= 3) {
        const oldest = this._db._db.prepare(
          'SELECT MIN(started_at) as oldest FROM sov_pioneer_assessments WHERE sovereign_id = ? AND specialisation = ? AND passed = 0 AND started_at > ?'
        ).get(sovereign_id, specialisation, Date.now() - 172800000);
        return ws.send(JSON.stringify({
          type:            'PIONEER_ASSESSMENT_STARTED',
          success:         false,
          error:           'COOLDOWN',
          cooldown_until:  ((oldest && oldest.oldest) ? oldest.oldest : 0) + 172800000,
        }));
      }

      // Select 15 random questions
      const questions = this._db._db.prepare(
        'SELECT id, question, option_a, option_b, option_c, option_d FROM sov_pioneer_questions WHERE specialisation = ? AND active = 1 ORDER BY RANDOM() LIMIT 15'
      ).all(specialisation);

      if (questions.length < 10) {
        return ws.send(JSON.stringify({ type: 'PIONEER_ASSESSMENT_STARTED', success: false, error: 'INSUFFICIENT_QUESTIONS' }));
      }

      const now        = Date.now();
      const attemptNum = (recentFails ? recentFails.count : 0) + 1;

      const assessmentId = this._db._db.prepare(
        'INSERT INTO sov_pioneer_assessments (sovereign_id, specialisation, questions_json, started_at, attempt_number) VALUES (?,?,?,?,?)'
      ).run(sovereign_id, specialisation, JSON.stringify(questions.map(q => q.id)), now, attemptNum).lastInsertRowid;

      ws.send(JSON.stringify({
        type:              'PIONEER_ASSESSMENT_STARTED',
        success:           true,
        assessment_id:     assessmentId,
        specialisation,
        attempt_number:    attemptNum,
        attempts_remaining: 3 - attemptNum,
        questions:         questions.map(q => ({
          id:      q.id,
          question: q.question,
          options: { A: q.option_a, B: q.option_b, C: q.option_c, D: q.option_d },
        })),
      }));
    } catch (e) {
      global.sovLog.error('[PIONEER] StartAssessment error:', e.message);
      ws.send(JSON.stringify({ type: 'PIONEER_ASSESSMENT_STARTED', success: false, error: e.message }));
    }
  }

  // ── PIONEER_SUBMIT_ASSESSMENT — grade and record ────────────────────────────
  handleSubmitAssessment(ws, msg) {
    const { sovereign_id, assessment_id, answers } = msg;
    if (!sovereign_id || !assessment_id || !answers) {
      return ws.send(JSON.stringify({ type: 'PIONEER_SUBMIT_RESULT', success: false, error: 'MISSING_FIELDS' }));
    }

    try {
      const assessment = this._db._db.prepare(
        'SELECT * FROM sov_pioneer_assessments WHERE id = ? AND sovereign_id = ?'
      ).get(assessment_id, sovereign_id);

      if (!assessment) {
        return ws.send(JSON.stringify({ type: 'PIONEER_SUBMIT_RESULT', success: false, error: 'ASSESSMENT_NOT_FOUND' }));
      }

      const questionIds  = JSON.parse(assessment.questions_json);
      const placeholders = questionIds.map(() => '?').join(',');
      const questions    = this._db._db.prepare(
        `SELECT id, correct_answer FROM sov_pioneer_questions WHERE id IN (${placeholders})`
      ).all(...questionIds);

      let correct = 0;
      for (const q of questions) {
        if (answers[q.id] === q.correct_answer) correct++;
      }

      const score  = Math.round((correct / questions.length) * 100);
      const passed = score >= 85;
      const now    = Date.now();

      this._db._db.prepare(
        'UPDATE sov_pioneer_assessments SET score = ?, passed = ?, completed_at = ? WHERE id = ?'
      ).run(score, passed ? 1 : 0, now, assessment_id);

      if (passed) {
        const spec        = assessment.specialisation;
        const certField   = 'cert_' + spec;
        const certAtField = spec + '_at';

        this._db._db.prepare(
          `INSERT INTO sov_pioneers (sovereign_id, ${certField}, ${certAtField}, rank, referral_count, total_earned_seeds, pioneer_code)
           VALUES (?, 1, ?, 'apprentice', 0, 0, ?)
           ON CONFLICT(sovereign_id) DO UPDATE SET ${certField} = 1, ${certAtField} = ?`
        ).run(
          sovereign_id,
          now,
          `PI-${crypto.createHash('sha256').update(sovereign_id).digest('hex').substring(0,8).toUpperCase()}`,
          now
        );

        // Update pioneer_badges on disc
        const disc = this._db._db.prepare("SELECT pioneer_badges FROM sov_disc WHERE sovereign_id = ?").get(sovereign_id);
        const currentBadges = ((disc && disc.pioneer_badges) ? disc.pioneer_badges : '').split(',').filter(Boolean);
        if (!currentBadges.includes(spec)) currentBadges.push(spec);
        this._db._db.prepare("UPDATE sov_disc SET pioneer_badges = ? WHERE sovereign_id = ?").run(currentBadges.join(','), sovereign_id);

        // Recalculate rank
        const pioneerRow = this._db._db.prepare('SELECT * FROM sov_pioneers WHERE sovereign_id = ?').get(sovereign_id);
        const certs = [pioneerRow.cert_relay_engineer, pioneerRow.cert_enrollment_agent, pioneerRow.cert_protocol_specialist].filter(Boolean).length;
        const refs  = pioneerRow.referral_count || 0;
        let rank = 'apprentice';
        if (certs === 3)      rank = 'master';
        else if (refs >= 100) rank = 'master';
        else if (refs >= 25)  rank = 'senior';
        else if (refs >= 1)   rank = 'pioneer';

        this._db._db.prepare('UPDATE sov_pioneers SET rank = ? WHERE sovereign_id = ?').run(rank, sovereign_id);

        global.sovLog.info(`[PIONEER] Certified: ${sovereign_id} | ${spec} | score: ${score} | rank: ${rank}`);
        ws.send(JSON.stringify({
          type:         'PIONEER_SUBMIT_RESULT',
          success:      true,
          passed:       true,
          score,
          specialisation: spec,
          badge_earned: spec,
          rank,
          message:      `Congratulations! You are now a certified ${spec.replace(/_/g, ' ')} on the SOV Network.`,
        }));

      } else {
        const totalFails = this._db._db.prepare(
          'SELECT COUNT(*) as count FROM sov_pioneer_assessments WHERE sovereign_id = ? AND specialisation = ? AND passed = 0 AND started_at > ?'
        ).get(sovereign_id, assessment.specialisation, Date.now() - 172800000);
        const failCount = totalFails ? totalFails.count : 1;

        ws.send(JSON.stringify({
          type:               'PIONEER_SUBMIT_RESULT',
          success:            true,
          passed:             false,
          score,
          pass_mark:          85,
          specialisation:     assessment.specialisation,
          attempts_used:      failCount,
          attempts_remaining: Math.max(0, 3 - failCount),
          message: `Score: ${score}%. Need 85% to pass. ${score >= 70 ? 'Close! Review the topics you missed.' : 'Study the knowledge guide and try again.'}`,
        }));
      }
    } catch (e) {
      global.sovLog.error('[PIONEER] SubmitAssessment error:', e.message);
      ws.send(JSON.stringify({ type: 'PIONEER_SUBMIT_RESULT', success: false, error: e.message }));
    }
  }

  // ── Called by EnrollmentEngine after a successful enrollment ──────────────
  // Checks if the enrollment payload contains a pioneer_code.
  // If so, credits the pioneer with their referral reward.
  // Also checks referred_by for certified-pioneer referral bonus.
  processPioneerReward(sovereignId, pioneerCode, referredBy) {
    // PI-33 (2026-06-04 claude-sov): the Pioneer subsystem is decommissioned, but
    // this reward path never honoured the `pioneer_rewards_active` governance gate
    // — it minted 50 SOV/referral + a 5-SOV cert bonus against a PHANTOM 5M cap in
    // getPioneerPoolRemaining() that is NOT part of the economy-v3b supply pools,
    // so any pioneer reward broke the 50M supply invariant (minting from nothing).
    // Enforce the gate: param != '1' → suppress ALL pioneer reward paths. Currently
    // pioneer_rewards_active=0 fleet-wide, so this closes the hole. Reversible via
    // governance. (Full code removal = owner-staged PI-33 surgical removal.)
    try {
      if (this._db.getGovParam('pioneer_rewards_active', '0') !== '1') return;
    } catch (_) { return; }
    if (pioneerCode) {
      try {
        const pioneerRecord = this._db._db.prepare(
          'SELECT * FROM sov_pioneers WHERE pioneer_code = ?'
        ).get(pioneerCode);
        if (pioneerRecord) {
          const poolRemaining = this._db.getPioneerPoolRemaining();
          if (poolRemaining > 0) {
            let rewardSov = poolRemaining > 500000 ? 50
              : poolRemaining > 100000 ? 25
              : 12;
            rewardSov = Math.min(rewardSov, poolRemaining);
            const rewardSeeds = rewardSov * 1_000_000;

            // Credit pioneer's balance
            this._db.ensureDiscEntry(pioneerRecord.sovereign_id);
            const credited = this._db.creditBalance(pioneerRecord.sovereign_id, rewardSeeds);
            if (credited) {
              // Update pioneer record
              this._db._db.prepare(
                'UPDATE sov_pioneers SET referral_count = referral_count + 1, total_earned = total_earned + ?, total_earned_seeds = total_earned_seeds + ? WHERE pioneer_code = ?'
              ).run(rewardSov, rewardSeeds, pioneerCode);

              // Recalculate rank
              this._updateRank(pioneerRecord.sovereign_id);

              global.sovLog.info(`[PIONEER] Referral reward: ${pioneerRecord.sovereign_id} +${rewardSov} SOV (code: ${pioneerCode})`);
            }
          }
        }
      } catch (e) {
        global.sovLog.warn('[PIONEER] processPioneerReward error:', e.message);
      }
    }

    // Certification-based referral bonus (5 SOV for certified pioneers)
    if (referredBy && typeof referredBy === 'string' && referredBy.startsWith('SOV-')) {
      try {
        const certPioneer = this._db._db.prepare(
          'SELECT sovereign_id FROM sov_pioneers WHERE sovereign_id = ? AND (cert_relay_engineer = 1 OR cert_enrollment_agent = 1 OR cert_protocol_specialist = 1)'
        ).get(referredBy);
        if (certPioneer) {
          const REFERRAL_REWARD_SEEDS = 5_000_000; // 5 SOV
          this._db.ensureDiscEntry(certPioneer.sovereign_id);
          const credited = this._db.creditBalance(certPioneer.sovereign_id, REFERRAL_REWARD_SEEDS);
          if (credited) {
            this._db._db.prepare(
              'UPDATE sov_pioneers SET referral_count = referral_count + 1, total_earned_seeds = total_earned_seeds + ? WHERE sovereign_id = ?'
            ).run(REFERRAL_REWARD_SEEDS, certPioneer.sovereign_id);
            this._updateRank(certPioneer.sovereign_id);
            global.sovLog.info(`[PIONEER] Cert referral bonus: ${certPioneer.sovereign_id} +5 SOV (referred: ${sovereignId})`);
          }
        }
      } catch (e) {
        global.sovLog.warn('[PIONEER] certReferral error:', e.message);
      }
    }
  }

  // ── Private — recalculate and store rank ────────────────────────────────────
  _updateRank(sovereignId) {
    try {
      const row = this._db._db.prepare('SELECT * FROM sov_pioneers WHERE sovereign_id = ?').get(sovereignId);
      if (!row) return;
      const certs = [row.cert_relay_engineer, row.cert_enrollment_agent, row.cert_protocol_specialist].filter(Boolean).length;
      const refs  = row.referral_count || 0;
      let rank = 'apprentice';
      if (certs === 3)      rank = 'master';
      else if (refs >= 100) rank = 'master';
      else if (refs >= 25)  rank = 'senior';
      else if (refs >= 1)   rank = 'pioneer';
      this._db._db.prepare('UPDATE sov_pioneers SET rank = ? WHERE sovereign_id = ?').run(rank, sovereignId);
    } catch (_) {}
  }
}

module.exports = { PioneerEngine };
