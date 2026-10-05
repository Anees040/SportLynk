/**
 * validateMediaUrl — the guard that decides whether a URL may stand in for
 * app-hosted media (a team logo, a chat image, a voice note).
 *
 * Run:  npm test            (from backend/), or  node --test test/mediaUrl.test.js
 *
 * The function is pure, so the database is irrelevant here. What matters is the
 * boundary it draws: the field is echoed to every member and rendered by the
 * app, so a URL that resolves anywhere the attacker chooses turns a roster or a
 * thread into a request to a host of their choosing. Pinning the host closed the
 * obvious case; pinning the Cloudinary *account* closes the subtler one, since
 * res.cloudinary.com is a shared CDN and `res.cloudinary.com/<someone-else>/...`
 * is a perfectly valid URL on the trusted host. These tests pin both.
 */
const test = require('node:test');
const assert = require('node:assert/strict');

const access = require('../src/utils/teamAccess');

// The value the module itself resolves — kept in step so the test is correct
// whether or not CLOUDINARY_CLOUD_NAME is set in the environment.
const CLOUD = process.env.CLOUDINARY_CLOUD_NAME || 'dzcklcydu';
const own = (path) => `https://res.cloudinary.com/${CLOUD}/${path}`;

test('a well-formed URL on the app\'s own cloud is accepted and preserved', () => {
  const url = own('video/upload/v1/chat_audio/note.mp4');
  const r = access.validateMediaUrl(url, { label: 'Voice note', required: true });
  assert.equal(r.ok, true);
  assert.equal(r.value, url);
});

test('a delivery transform on the app\'s own cloud is still accepted', () => {
  const url = own('image/upload/c_limit,w_800,q_auto,f_auto/v1/teams/logo.jpg');
  assert.equal(access.validateMediaUrl(url, { label: 'Logo' }).ok, true);
});

test('a non-https link is rejected', () => {
  const url = own('image/upload/v1/x.jpg').replace('https:', 'http:');
  assert.equal(access.validateMediaUrl(url).ok, false);
});

test('a host that is not the media CDN is rejected', () => {
  assert.equal(
    access.validateMediaUrl('https://evil.example.com/pixel.gif').ok, false);
});

// The point of the account pin: a different Cloudinary account on the same
// trusted host must not pass, or a member could embed a tracking asset from a
// cloud they control.
test('a different Cloudinary account on the trusted host is rejected', () => {
  const r = access.validateMediaUrl(
    'https://res.cloudinary.com/attacker-cloud/image/upload/v1/track.gif',
    { label: 'Image' });
  assert.equal(r.ok, false);
});

test('the bare media host with no account segment is rejected', () => {
  assert.equal(access.validateMediaUrl('https://res.cloudinary.com/').ok, false);
});

test('an over-long URL is rejected before anything else', () => {
  const url = own(`image/upload/v1/${'a'.repeat(600)}.jpg`);
  assert.equal(access.validateMediaUrl(url).ok, false);
});

test('an empty value is required-aware', () => {
  assert.equal(access.validateMediaUrl('', { required: true }).ok, false);
  const optional = access.validateMediaUrl('', { required: false });
  assert.equal(optional.ok, true);
  assert.equal(optional.value, null);
});
