/**
 * probe_cloudinary_audio.js — which unsigned upload endpoint actually accepts a
 * voice note? Posts the same clip to /image/upload, /video/upload and
 * /auto/upload with the real cloud name and unsigned preset, and prints what
 * Cloudinary answers for each.
 *
 * Why this exists
 * Voice notes were failing with a null media_url, and the cause was argued from
 * two directions at once: an account-side preset restriction, or the resource
 * type named in the request path. Only the endpoints can settle it. The
 * cloudinary_public package carries the resource type solely in the URL path —
 * its form body has no resource_type field — so the path is the whole of what
 * the client controls, and posting the same bytes three ways isolates it.
 *
 * The /video/upload row is the decisive one. The client was already posting
 * there when the null URLs were recorded, so if that row comes back accepted,
 * the request path was never the cause and the null media_url has to be
 * explained by something else — the recording, the file handed to the uploader,
 * or the network — rather than by the resource type.
 *
 * The sample is a real app-recorded clip wherever one exists: the newest audio
 * row that has a media_url is downloaded and re-posted, so the bytes are exactly
 * what the recorder produces. Failing that (no such row, or the fetch fails) a
 * silent MPEG-1 Layer III file is synthesised and labelled as such in the
 * output, because a handmade sample proves less than a real one.
 *
 * This WRITES to Cloudinary. Every accepted upload leaves an asset in the folder
 * named below, and an unsigned upload cannot be deleted through the API without
 * the account's API secret, so the folder has to be emptied by hand from the
 * Media Library. Nothing is written to the database.
 *
 * Usage:  node src/scripts/probe_cloudinary_audio.js
 *         node src/scripts/probe_cloudinary_audio.js --file path/to/clip.m4a
 */
const fs = require('fs');
const path = require('path');

// The client's own public values, mirrored from lib/constants/app_config.dart.
// A cloud name and an unsigned preset are shipped inside the APK and are public
// by design, unlike the API secret, which this probe neither needs nor reads.
// Overridable so the same probe can be pointed at another cloud.
const CLOUD = process.env.CLOUDINARY_CLOUD_NAME || 'dzcklcydu';
const PRESET = process.env.CLOUDINARY_UPLOAD_PRESET || 'SportLynk';
const FOLDER = 'probe_cloudinary_audio';

/** The three resource types the path can name, in the order they are reported. */
const ENDPOINTS = ['image', 'video', 'auto'];

/**
 * A silent MPEG-1 Layer III file, used only when no recorded clip is reachable.
 *
 * Each frame is a 4-byte header followed by zeroed data: 0xFF 0xFB marks the
 * sync word with MPEG-1 Layer III and no CRC, 0x90 selects 128 kbit/s at
 * 44.1 kHz, and the frame length that pair implies is
 * floor(144 * 128000 / 44100) = 417 bytes.
 */
function synthesiseMp3(frames = 40) {
  const FRAME = 417;
  const buf = Buffer.alloc(FRAME * frames);
  for (let i = 0; i < frames; i += 1) {
    const at = i * FRAME;
    buf[at] = 0xff;
    buf[at + 1] = 0xfb;
    buf[at + 2] = 0x90;
    buf[at + 3] = 0x00;
  }
  return buf;
}

/** The newest voice note that has a URL, downloaded so the real bytes are used. */
async function sampleFromDatabase() {
  let pool;
  try {
    pool = require('../db/pool');
  } catch (e) {
    return { error: `the database pool could not be loaded (${e.message})` };
  }
  try {
    const { rows } = await pool.query(`
      SELECT media_url, media_mime
        FROM chat_messages
       WHERE kind = 'audio' AND media_url IS NOT NULL
       ORDER BY created_at DESC
       LIMIT 1
    `);
    if (rows.length === 0) return { error: 'no audio row has a media_url' };
    const { media_url: url, media_mime: mime } = rows[0];
    const res = await fetch(url);
    if (!res.ok) return { error: `the stored clip returned HTTP ${res.status}` };
    const bytes = Buffer.from(await res.arrayBuffer());
    const name = path.basename(new URL(url).pathname) || 'voice.m4a';
    return { bytes, name, mime: mime || 'audio/mp4', source: `a recorded voice note (${name})` };
  } catch (e) {
    return { error: e.message };
  } finally {
    await pool.end().catch(() => {});
  }
}

/** Post one copy of the sample to one resource-type endpoint. */
async function post(type, sample) {
  const url = `https://api.cloudinary.com/v1_1/${CLOUD}/${type}/upload`;
  const form = new FormData();
  form.append('upload_preset', PRESET);
  form.append('folder', FOLDER);
  form.append('file', new Blob([sample.bytes], { type: sample.mime }), sample.name);

  try {
    const res = await fetch(url, { method: 'POST', body: form });
    const text = await res.text();
    let body;
    try {
      body = JSON.parse(text);
    } catch {
      body = null;
    }
    return { status: res.status, body, text };
  } catch (e) {
    return { status: 0, transport: e.message };
  }
}

async function main() {
  const fileArg = process.argv.indexOf('--file');
  let sample;

  if (fileArg !== -1 && process.argv[fileArg + 1]) {
    const p = process.argv[fileArg + 1];
    if (!fs.existsSync(p)) {
      console.error(`No such file: ${p}`);
      process.exitCode = 1;
      return;
    }
    sample = {
      bytes: fs.readFileSync(p),
      name: path.basename(p),
      mime: 'audio/mp4',
      source: `the file given on the command line (${path.basename(p)})`,
    };
  } else {
    const found = await sampleFromDatabase();
    if (found.bytes) {
      sample = found;
    } else {
      sample = {
        bytes: synthesiseMp3(),
        name: 'probe-silence.mp3',
        mime: 'audio/mpeg',
        source: `a synthesised silent MP3 — no recorded clip was usable (${found.error})`,
      };
    }
  }

  console.log(`Cloud   : ${CLOUD}`);
  console.log(`Preset  : ${PRESET} (unsigned)`);
  console.log(`Folder  : ${FOLDER}`);
  console.log(`Sample  : ${sample.source}, ${sample.bytes.length} bytes\n`);

  const results = {};
  for (const type of ENDPOINTS) {
    const r = await post(type, sample);
    results[type] = r;
    console.log(`POST /${type}/upload`);
    if (r.status === 0) {
      console.log(`    transport failure: ${r.transport}\n`);
      continue;
    }
    console.log(`    HTTP ${r.status}`);
    if (r.status === 200) {
      console.log(`    resource_type : ${r.body?.resource_type}`);
      console.log(`    format        : ${r.body?.format}`);
      console.log(`    duration      : ${r.body?.duration ?? '(none reported)'}`);
      console.log(`    secure_url    : ${r.body?.secure_url}`);
    } else {
      console.log(`    error: ${r.body?.error?.message ?? r.text?.slice(0, 300)}`);
    }
    console.log();
  }

  const ok = (t) => results[t]?.status === 200;
  console.log('RESULT');
  for (const type of ENDPOINTS) {
    console.log(`  /${type}/upload : ${ok(type) ? 'accepted' : 'refused'}`);
  }
  if (ok('auto')) {
    console.log(`\n/auto/upload accepts this clip and delivers it from `
      + `${new URL(results.auto.body.secure_url).pathname.split('/')[2]}/upload/, `
      + `which is the path the client now posts to.`);
  } else {
    console.log('\n/auto/upload did NOT accept this clip. The resource type in the '
      + 'request path is not the cause, and the account-side preset or the sample '
      + 'itself has to be looked at next.');
  }
  console.log(`\nAccepted uploads left assets in ${FOLDER}/ — delete that folder `
    + 'from the Cloudinary Media Library by hand (an unsigned upload cannot be '
    + 'removed through the API).');
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
