/**
 * test/geo_distance.test.js — the proximity re-rank helpers (utils/geoDistance).
 *
 * Pure functions, no DB: these pin the distance maths and, more importantly, the two
 * rules that keep it honest — a missing coordinate is null (never zero), and a null
 * distance always sorts last (never masquerades as "very close").
 */
const test = require('node:test');
const assert = require('node:assert/strict');

const { haversineKm, annotateDistance, sortByNearest } = require('../src/utils/geoDistance');

test('haversineKm: one degree of longitude at the equator is ~111 km', () => {
  const d = haversineKm(0, 0, 0, 1);
  assert.ok(Math.abs(d - 111.2) < 1, `expected ~111.2, got ${d}`);
});

test('haversineKm: a known city pair (Lahore→Islamabad) is ~250-270 km', () => {
  const d = haversineKm(31.5204, 74.3587, 33.6844, 73.0479);
  assert.ok(d > 240 && d < 280, `expected ~268, got ${d}`);
});

test('haversineKm: the same point is zero', () => {
  assert.equal(haversineKm(31.5, 74.3, 31.5, 74.3), 0);
});

test('haversineKm: a missing or out-of-range coordinate is null, not a number', () => {
  assert.equal(haversineKm(0, 0, null, 5), null);
  assert.equal(haversineKm(0, 0, undefined, 5), null);
  assert.equal(haversineKm(0, 0, 'x', 5), null);
  assert.equal(haversineKm(0, 0, 200, 5), null, 'a latitude of 200 is bad data, not a place');
});

test('annotateDistance: no origin leaves the list untouched', () => {
  const vs = [{ id: 'a', latitude: 31.5, longitude: 74.3 }];
  const out = annotateDistance(vs, {});
  assert.equal(out[0].distance_km, undefined, 'a caller that sent no location sees no distance');
});

test('annotateDistance: adds distance_km, null when a venue has no coordinates', () => {
  const vs = [
    { id: 'near', latitude: 31.51, longitude: 74.36 },
    { id: 'nocoord', latitude: null, longitude: null },
  ];
  const out = annotateDistance(vs, { lat: 31.5204, lng: 74.3587 });
  assert.ok(typeof out[0].distance_km === 'number' && out[0].distance_km < 5);
  assert.equal(out[1].distance_km, null, 'no coordinates means unknown distance, not zero');
  assert.deepEqual(out.map((v) => v.id), ['near', 'nocoord'], 'order is unchanged by annotation');
});

test('sortByNearest: nearest first, unknown distance always last, stable within ties', () => {
  const vs = [
    { id: 'far', distance_km: 10 },
    { id: 'unknown', distance_km: null },
    { id: 'near', distance_km: 2 },
    { id: 'tieA', distance_km: 5 },
    { id: 'tieB', distance_km: 5 },
  ];
  const out = sortByNearest(vs).map((v) => v.id);
  assert.deepEqual(out, ['near', 'tieA', 'tieB', 'far', 'unknown']);
});
