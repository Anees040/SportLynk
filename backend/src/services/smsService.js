/**
 * smsService.js — the single place the backend sends an SMS.
 *
 * Why this ships dormant
 * SportLynk sends SMS through textbee, a gateway that runs on a spare Android phone
 * holding a SIM: that phone does the sending, and this module only POSTs the message to
 * textbee's HTTP API. That needs an API key and a device id, neither of which belongs in
 * git, so the module is written to be entirely absent until `TEXTBEE_API_KEY` and
 * `TEXTBEE_DEVICE_ID` are set. Until then `isConfigured()` answers false, `sendSms()`
 * returns `{ ok:false, disabled:true }` with no network call, and a single warning is
 * printed rather than one per attempt. This mirrors pushService's discipline: the whole
 * password-reset flow can be built, tested and reviewed with no gateway in existence, and
 * adding the two env vars switches real delivery on with no code change.
 *
 * Why it never fakes success
 * A reset code generated and stored but never actually delivered would lock a user out —
 * they would be asked for a code that never arrives. So a send that cannot happen
 * (disabled) or that the gateway rejects (error) is reported as a failure to the caller,
 * which then stores no code (see passwordResetService.sendCode). Honest failure is the
 * only safe failure here.
 *
 * Node 20 (see package.json engines) provides a global `fetch`, so textbee's one call
 * needs no new dependency; its absence is still guarded so an older runtime degrades to
 * disabled rather than throwing at first send.
 */

// Resolved once, on first use. 'unknown' means init() has not run; once it has, the
// answer is fixed for the life of the process.
let _state = 'unknown'; // 'unknown' | 'ready' | 'disabled'
let _reason = null;
let _apiKey = null;
let _deviceId = null;
let _baseUrl = null;

const DEFAULT_BASE_URL = 'https://api.textbee.dev/api/v1';

/**
 * Read the textbee configuration, at most once. Every failure path sets `_state` to
 * 'disabled' with a `_reason` that names the fix and returns false; nothing here throws,
 * so a request handler can ask "can I send?" without a try/catch.
 */
function init() {
  if (_state !== 'unknown') return _state === 'ready';

  const key = (process.env.TEXTBEE_API_KEY || '').trim();
  if (!key) { _state = 'disabled'; _reason = 'TEXTBEE_API_KEY is not set'; return false; }

  const device = (process.env.TEXTBEE_DEVICE_ID || '').trim();
  if (!device) { _state = 'disabled'; _reason = 'TEXTBEE_DEVICE_ID is not set'; return false; }

  if (typeof fetch !== 'function') {
    _state = 'disabled';
    _reason = 'global fetch is unavailable (Node 18+ required)';
    return false;
  }

  _apiKey = key;
  _deviceId = device;
  _baseUrl = (process.env.TEXTBEE_BASE_URL || '').trim().replace(/\/+$/, '') || DEFAULT_BASE_URL;
  _state = 'ready';
  return true;
}

/** True when a real SMS send can happen. */
function isConfigured() {
  return init();
}

/**
 * The diagnostic view for a boot banner or status check. `reason` is the actionable
 * half. The API key is never surfaced; the device id is an identifier, not a credential,
 * and naming it answers "which phone is the gateway?".
 */
function status() {
  init();
  return {
    configured: _state === 'ready',
    reason: _state === 'ready' ? null : _reason,
    baseUrl: _state === 'ready' ? _baseUrl : null,
    deviceId: _state === 'ready' ? _deviceId : null,
  };
}

let _warned = false;
function warnOnce() {
  if (_warned) return;
  _warned = true;
  console.warn(`[sms] disabled — ${_reason}. Password-reset codes cannot be delivered `
    + 'until a textbee gateway is configured.');
}

/**
 * Normalise a Pakistani mobile number to E.164 for the gateway. The app validates
 * `03XXXXXXXXX` before it reaches here, so that is the shape that matters; a `92`/`+92`
 * prefix is accepted defensively. Anything else returns null, and the caller reports a
 * send failure rather than handing the gateway a number it will silently drop.
 */
function toE164Pakistan(phone) {
  const raw = String(phone || '').replace(/[\s-]/g, '');
  if (/^03\d{9}$/.test(raw)) return `+92${raw.slice(1)}`;
  if (/^92\d{10}$/.test(raw)) return `+${raw}`;
  if (/^\+92\d{10}$/.test(raw)) return raw;
  return null;
}

/**
 * Send one SMS through textbee. Returns exactly one of:
 *   • `{ ok:true, data }`                   — the gateway accepted the message
 *   • `{ ok:false, disabled:true, reason }` — no gateway configured (no network call)
 *   • `{ ok:false, error }`                 — bad number, unreachable gateway, or non-2xx
 *
 * Never throws, and never reports a send it did not make: the caller stores a reset code
 * only after `{ ok:true }`.
 */
async function sendSms(phone, message) {
  if (!isConfigured()) {
    warnOnce();
    return { ok: false, disabled: true, reason: _reason };
  }
  const to = toE164Pakistan(phone);
  if (!to) return { ok: false, error: 'unrecognised phone number format' };

  let resp;
  try {
    resp = await fetch(`${_baseUrl}/gateway/send-sms`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-api-key': _apiKey },
      body: JSON.stringify({ recipients: [to], message, deviceId: _deviceId }),
    });
  } catch (e) {
    // No network, DNS failure, or the gateway phone offline at the transport layer.
    return { ok: false, error: `sms gateway unreachable: ${e.message}` };
  }

  if (!resp.ok) {
    // A non-2xx: a bad key (401), an unregistered or sleeping device, or an exhausted
    // quota. The body is read for the log line only; nothing from it reaches the user.
    let detail = '';
    try { detail = (await resp.text()).slice(0, 200); } catch { detail = ''; }
    return { ok: false, error: `sms gateway returned ${resp.status}${detail ? `: ${detail}` : ''}` };
  }

  let data = null;
  try { data = await resp.json(); } catch { data = null; }
  return { ok: true, data };
}

module.exports = {
  init,
  isConfigured,
  status,
  sendSms,
  toE164Pakistan,
};
