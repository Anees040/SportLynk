/**
 * check_voice_notes.js — read-only: what voice notes are actually in the database?
 *
 * Why this exists
 * "Voice notes do not play" has three very different causes and the bubble looks
 * similar for two of them: the clip never uploaded (media_url null, so there is
 * nothing to play), the clip uploaded to a URL the player cannot decode, or the
 * clip is fine and playback is failing on the device. Only the rows can tell
 * those apart, so this prints them rather than guessing.
 *
 * Strictly read-only: SELECTs only, no transaction, nothing written.
 *
 * Usage:  node src/scripts/check_voice_notes.js
 */
const pool = require('../db/pool');

async function main() {
  const { rows: totals } = await pool.query(`
    SELECT count(*)                                             AS total,
           count(*) FILTER (WHERE media_url IS NULL)             AS no_url,
           count(*) FILTER (WHERE deleted_at IS NOT NULL)        AS deleted,
           count(*) FILTER (WHERE duration_ms IS NULL
                               OR duration_ms = 0)               AS no_duration,
           count(*) FILTER (WHERE waveform IS NULL)              AS no_waveform
      FROM chat_messages
     WHERE kind = 'audio'
  `);
  const t = totals[0];
  console.log('Voice notes in chat_messages');
  console.log(`  total:                 ${t.total}`);
  console.log(`  with NO media_url:     ${t.no_url}   <- these can never play`);
  console.log(`  deleted:               ${t.deleted}`);
  console.log(`  duration 0/null:       ${t.no_duration}`);
  console.log(`  no waveform samples:   ${t.no_waveform}`);

  if (Number(t.total) === 0) {
    console.log('\nNo audio rows at all — the send never reached the server.');
    await pool.end();
    return;
  }

  const { rows } = await pool.query(`
    SELECT id, created_at, media_url, media_mime, duration_ms,
           jsonb_array_length(COALESCE(waveform, '[]'::jsonb)) AS bars
      FROM chat_messages
     WHERE kind = 'audio'
     ORDER BY created_at DESC
     LIMIT 10
  `);
  console.log('\nMost recent 10:');
  for (const r of rows) {
    const when = new Date(r.created_at).toISOString().slice(0, 19).replace('T', ' ');
    console.log(`\n  ${when}  ${r.id}`);
    console.log(`    media_mime  : ${r.media_mime}`);
    console.log(`    duration_ms : ${r.duration_ms}`);
    console.log(`    waveform    : ${r.bars} bars`);
    console.log(`    media_url   : ${r.media_url}`);
  }

  // The shape of the URL decides whether just_audio can decode it: Cloudinary
  // serves audio under its /video/ resource path, and a URL that is missing the
  // extension or carries a transformation segment is the common failure.
  const { rows: shapes } = await pool.query(`
    SELECT count(*) FILTER (WHERE media_url LIKE '%/video/upload/%') AS video_path,
           count(*) FILTER (WHERE media_url LIKE '%/image/upload/%') AS image_path,
           count(*) FILTER (WHERE media_url LIKE '%/raw/upload/%')   AS raw_path,
           count(*) FILTER (WHERE media_url ~ '\\.[A-Za-z0-9]+$')     AS has_extension
      FROM chat_messages
     WHERE kind = 'audio' AND media_url IS NOT NULL
  `);
  const s = shapes[0];
  console.log('\nURL shape (of the rows that have a URL):');
  console.log(`  /video/upload/ : ${s.video_path}`);
  console.log(`  /image/upload/ : ${s.image_path}`);
  console.log(`  /raw/upload/   : ${s.raw_path}`);
  console.log(`  ends with a file extension: ${s.has_extension}`);

  await pool.end();
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
