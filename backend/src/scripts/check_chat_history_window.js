/**
 * check_chat_history_window.js — read-only diagnostic for the "a new member sees
 * the whole backlog" report (migration 036 / chatCore.syncTeamMember).
 *
 * Writes nothing. It answers three questions:
 *   1. Does chat_channel_members.history_from exist at all (is 036 applied)?
 *   2. How many memberships carry NULL (which the history query reads as "no
 *      lower bound" — full backlog)?
 *   3. For the most recently joined members, is history_from set to their join,
 *      and how many earlier messages would therefore be hidden from them?
 *
 * Usage: node src/scripts/check_chat_history_window.js
 */
const pool = require('../db/pool');

async function hasColumn(table, column) {
  const { rows } = await pool.query(
    `SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2`,
    [table, column],
  );
  return rows.length > 0;
}

async function main() {
  const present = await hasColumn('chat_channel_members', 'history_from');
  console.log(`history_from column present (036 applied): ${present}`);
  if (!present) {
    console.log('\nRESULT: migration 036 is NOT applied to this database. With no '
      + 'history_from column the history endpoint cannot bound a new member, so '
      + 'they see the whole backlog. Apply 036 and new joins start fresh.');
    await pool.end();
    return;
  }

  const total = Number((await pool.query('SELECT count(*) AS n FROM chat_channel_members')).rows[0].n);
  const nulls = Number((await pool.query(
    'SELECT count(*) AS n FROM chat_channel_members WHERE history_from IS NULL AND left_at IS NULL',
  )).rows[0].n);
  console.log(`live memberships: ${total}`);
  console.log(`  with history_from NULL (see full backlog): ${nulls}`);

  // The most recent joins: is history_from being stamped, and would it hide the
  // backlog that predates it?
  const { rows } = await pool.query(
    `SELECT cm.channel_id, cm.user_id, u.name, cm.joined_at, cm.history_from,
            (SELECT count(*) FROM chat_messages msg
              WHERE msg.channel_id = cm.channel_id
                AND (cm.history_from IS NULL OR msg.created_at < cm.history_from)) AS older_messages
       FROM chat_channel_members cm
       LEFT JOIN users u ON u.id = cm.user_id
      WHERE cm.left_at IS NULL
      ORDER BY cm.joined_at DESC NULLS LAST
      LIMIT 8`,
  );
  console.log('\nmost recent joins (older_messages = backlog hidden from them):');
  for (const r of rows) {
    const bound = r.history_from ? r.history_from.toISOString() : 'NULL (no bound → sees all)';
    console.log(`  ${(r.name || r.user_id).padEnd(18)} joined=${r.joined_at ? r.joined_at.toISOString() : '?'}  history_from=${bound}  hidden=${r.older_messages}`);
  }
  await pool.end();
}

main().catch((e) => { console.error(e.message); process.exitCode = 1; });
