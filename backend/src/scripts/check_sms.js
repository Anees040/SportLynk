/**
 * check_sms.js — confirm the textbee SMS gateway is configured, and (optionally)
 * send one real test message. The API key is never printed; only the device id
 * and base URL, which are identifiers rather than secrets, are shown.
 *
 * Usage:
 *   node src/scripts/check_sms.js                      # status only, sends nothing
 *   node src/scripts/check_sms.js --to 03001234567     # also sends one test SMS
 *
 * Reads backend/.env, the same file the server reads. Set TEXTBEE_API_KEY and
 * TEXTBEE_DEVICE_ID there first (optionally TEXTBEE_BASE_URL).
 */
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '..', '.env') });

const sms = require('../services/smsService');

async function main() {
  const s = sms.status();
  console.log('Textbee SMS gateway');
  console.log(`  configured: ${s.configured}`);
  if (!s.configured) {
    console.log(`  reason:     ${s.reason}`);
    console.log('\nSet TEXTBEE_API_KEY and TEXTBEE_DEVICE_ID in backend/.env, then re-run.');
    process.exitCode = 1;
    return;
  }
  console.log(`  baseUrl:    ${s.baseUrl}`);
  console.log(`  deviceId:   ${s.deviceId}`);

  const i = process.argv.indexOf('--to');
  const to = i >= 0 ? process.argv[i + 1] : null;
  if (!to) {
    console.log('\nConfigured. Pass --to 03XXXXXXXXX to send one real test SMS.');
    return;
  }

  console.log(`\nSending a test SMS to ${to} …`);
  const r = await sms.sendSms(to, 'SportLynk test message — your gateway works.');
  if (r.ok) {
    console.log('  sent ✓  (check the handset that received it)');
  } else {
    console.log(`  failed: ${r.error || r.reason || 'unknown error'}`);
    process.exitCode = 1;
  }
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
