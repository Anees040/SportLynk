/**
 * reconcile_wallets.js — repair drift between wallets.frozen_balance and the
 * bookings that are holding escrow.
 *
 * Why this exists
 * Escrow lives in two places that must agree:
 *
 *   wallets.frozen_balance   ==   sum(bookings.security_deposit)
 *                                 WHERE status in ('pending','confirmed')
 *
 * `security_deposit` — not `total_amount` — is the authority: routes/bookings.js
 * says "security_deposit holds what is ACTUALLY in escrow for this booking", and
 * both cancel paths, check-in and no-show all release exactly that column.
 *
 * The invariant broke because src/scripts/seed_venues.js used to DELETE a venue's
 * bookings and transactions without unwinding the escrow those bookings held. The
 * booking rows vanished; the frozen money did not. Every re-seed stranded more.
 * (seed_venues.js now unwinds first, so this script is a repair for damage already
 * done, not a recurring chore.)
 *
 * Left unrepaired, phantom escrow is not cosmetic: it is spendable balance the
 * user cannot reach, GET /api/wallet/frozen reports a non-zero `delta` forever,
 * and the S1 acceptance check "delta = 0" can never pass honestly.
 *
 * What it does
 * Per wallet, inside one transaction with FOR UPDATE (golden rule 4):
 *
 *   over-frozen  (frozen > owed)  → frozen -= diff, balance += diff,
 *                                   one `refund` ledger row for the audit trail
 *   under-frozen (frozen < owed)  → reported only, never auto-fixed
 *
 * Under-frozen is deliberately not touched. It would mean silently taking money
 * out of someone's spendable balance to satisfy a claim they may never have
 * agreed to, and it points at a different bug that a script should not paper over.
 *
 * The ledger stays append-only — the correction is a new row, never an edit or a
 * reversal of history. `refund` is used because transactions.type is the `txn_type`
 * enum and `refund` is its honest member for "money returning to spendable
 * balance"; inventing a label would need a schema migration for a one-off repair.
 *
 * USAGE
 *   node src/scripts/reconcile_wallets.js            # dry run — reports, changes nothing
 *   node src/scripts/reconcile_wallets.js --apply    # moves the money
 *
 * Dry run is the default on purpose: this touches real balances.
 */

const pool = require('../db/pool');
const { round2, asNum, applyWallet, logTxn } = require('../utils/escrow');

const APPLY = process.argv.includes('--apply');

/** Every wallet, with what it holds frozen vs what its bookings owe. */
const AUDIT_SQL = `
  SELECT u.id                AS user_id,
         u.name,
         u.role,
         w.id                AS wallet_id,
         w.balance,
         w.frozen_balance,
         COALESCE((
           SELECT SUM(b.security_deposit)
             FROM bookings b
            WHERE b.player_id = u.id
              AND b.status IN ('pending','confirmed')
         ), 0)               AS owed,
         COALESCE((
           SELECT COUNT(*)
             FROM bookings b
            WHERE b.player_id = u.id
              AND b.status IN ('pending','confirmed')
         ), 0)               AS active_bookings
    FROM wallets w
    JOIN users u ON u.id = w.user_id
   ORDER BY w.frozen_balance DESC`;

function pad(v, n) { return String(v).padStart(n); }

async function main() {
  console.log('');
  console.log('═══ Wallet escrow reconciliation ═══════════════════════════════');
  console.log(APPLY
    ? '  MODE: --apply  → balances WILL be changed'
    : '  MODE: dry run  → nothing will be changed (pass --apply to commit)');
  console.log('');

  const { rows } = await pool.query(AUDIT_SQL);

  const over = [];
  const under = [];
  for (const r of rows) {
    const drift = round2(asNum(r.frozen_balance) - asNum(r.owed));
    if (drift > 0.009) over.push({ ...r, drift });
    else if (drift < -0.009) under.push({ ...r, drift });
  }

  console.log(`  Wallets scanned      : ${rows.length}`);
  console.log(`  Already consistent   : ${rows.length - over.length - under.length}`);
  console.log(`  Over-frozen (fixable): ${over.length}`);
  console.log(`  Under-frozen (report): ${under.length}`);
  console.log('');

  if (!over.length && !under.length) {
    console.log('  ✅ Every wallet already agrees with its bookings. Nothing to do.');
    console.log('     GET /api/wallet/frozen will report delta = 0.');
    console.log('');
    return 0;
  }

  if (over.length) {
    console.log('  ── Over-frozen: escrow held against no active booking ─────────');
    console.log('     name                 balance     frozen       owed    release');
    for (const r of over) {
      console.log(`     ${String(r.name).padEnd(18)} ${pad(asNum(r.balance).toFixed(2), 10)} ${pad(asNum(r.frozen_balance).toFixed(2), 10)} ${pad(asNum(r.owed).toFixed(2), 10)} ${pad(r.drift.toFixed(2), 10)}`);
    }
    const total = round2(over.reduce((s, r) => s + r.drift, 0));
    console.log(`     ${' '.repeat(18)} ${' '.repeat(32)} ${pad(total.toFixed(2), 10)}  ← total to release`);
    console.log('');
  }

  if (under.length) {
    console.log('  ── Under-frozen: NOT auto-fixed, investigate these ────────────');
    for (const r of under) {
      console.log(`     ${String(r.name).padEnd(18)} frozen ${pad(asNum(r.frozen_balance).toFixed(2), 10)} but ${r.active_bookings} booking(s) claim ${pad(asNum(r.owed).toFixed(2), 10)} (short by ${Math.abs(r.drift).toFixed(2)})`);
    }
    console.log('     A booking is holding escrow the wallet never froze. Fixing this');
    console.log('     automatically would debit spendable balance without consent, so');
    console.log('     it is left alone — check whether those bookings are real.');
    console.log('');
  }

  if (!APPLY) {
    console.log('  Dry run complete. Re-run with --apply to release the over-frozen amounts.');
    console.log('');
    return 0;
  }

  if (!over.length) {
    console.log('  Nothing is auto-fixable. No changes made.');
    console.log('');
    return 0;
  }

  console.log('  ── Applying ───────────────────────────────────────────────────');
  let released = 0;
  let failures = 0;

  for (const r of over) {
    const client = await pool.connect();
    try {
      await client.query('BEGIN');

      // Re-read under FOR UPDATE and recompute inside the transaction. The audit
      // pass above is only a candidate scan — by the time this point is reached a booking
      // may have been made or cancelled, and acting on the stale number would
      // move the wrong amount.
      const locked = await client.query(
        'SELECT id, balance, frozen_balance FROM wallets WHERE id = $1 FOR UPDATE',
        [r.wallet_id],
      );
      if (!locked.rows.length) throw new Error('wallet disappeared');

      const owedNow = await client.query(
        `SELECT COALESCE(SUM(b.security_deposit), 0) AS owed
           FROM bookings b
          WHERE b.player_id = $1
            AND b.status IN ('pending','confirmed')`,
        [r.user_id],
      );

      const frozenNow = asNum(locked.rows[0].frozen_balance);
      const drift = round2(frozenNow - asNum(owedNow.rows[0].owed));

      if (drift <= 0.009) {
        await client.query('ROLLBACK');
        console.log(`     ${String(r.name).padEnd(18)} skipped — drift resolved before we got the lock`);
        continue;
      }

      const after = await applyWallet(client, r.wallet_id, {
        balance: drift,
        frozen: -drift,
      });

      await logTxn(client, {
        walletId: r.wallet_id,
        userId: r.user_id,
        bookingId: null,
        type: 'refund',
        amount: drift,
        balanceAfter: asNum(after.balance),
        description:
          `Escrow reconciliation — PKR ${drift.toFixed(2)} released to available ` +
          `balance. It was held frozen with no active booking against it.`,
        counterparty: 'SportLynk',
      });

      await client.query('COMMIT');
      released = round2(released + drift);
      console.log(`     ${String(r.name).padEnd(18)} released ${pad(drift.toFixed(2), 10)} → balance ${asNum(after.balance).toFixed(2)}, frozen ${asNum(after.frozen_balance).toFixed(2)}`);
    } catch (e) {
      await client.query('ROLLBACK').catch(() => {});
      failures++;
      console.error(`     ${String(r.name).padEnd(18)} FAILED — ${e.message}`);
    } finally {
      client.release();
    }
  }

  console.log('');
  console.log(`  Released ${released.toFixed(2)} across ${over.length - failures} wallet(s).${failures ? `  ${failures} failed.` : ''}`);

  // Prove it, rather than asserting it. Re-audit from scratch.
  const verify = await pool.query(AUDIT_SQL);
  const stillOver = verify.rows.filter(
    (r) => round2(asNum(r.frozen_balance) - asNum(r.owed)) > 0.009,
  );
  console.log('');
  console.log(stillOver.length === 0
    ? '  ✅ Verified: no wallet is over-frozen. GET /api/wallet/frozen → delta 0.'
    : `  ⚠️  ${stillOver.length} wallet(s) still over-frozen — re-run to see why.`);
  console.log('');
  return failures ? 1 : 0;
}

main()
  .then((code) => process.exit(code))
  .catch((e) => {
    console.error('');
    console.error('❌ Reconciliation failed:', e.message);
    console.error('   No partial changes: every wallet is committed or rolled back on its own.');
    process.exit(1);
  });
