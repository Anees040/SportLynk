/**
 * geoDistance.js — straight-line distance between the user and a venue, as a re-ranking
 * signal on top of the content recommender.
 *
 * Why this is a re-rank and not a model feature
 * The venue recommender (model #3) is frozen behind a fingerprint and deliberately
 * carries no distance block — its own notes call a fabricated distance "fabricated
 * precision" because venue coordinates are sparse. So proximity is applied HERE, after
 * the model has chosen relevant venues: the model answers "which grounds suit this
 * player", and this answers "which of those is near them right now". Candidate
 * generation by relevance, re-rank by distance — the shape a hotel or flight search
 * uses, and it leaves the released model and its fingerprint untouched.
 *
 * Honesty about the number: this is the great-circle (haversine) distance, not a road
 * distance. It is labelled "X km away" rather than a travel time precisely because the
 * data cannot support a travel time. A venue with no stored coordinates gets a null
 * distance and is never pretended to be at zero — it simply keeps its relevance rank
 * and sorts after the venues a distance is known for.
 */

const EARTH_RADIUS_KM = 6371;

const toRad = (deg) => (deg * Math.PI) / 180;

/** A finite number or null — strings from node-postgres NUMERIC columns included.
 *  null/undefined/'' are null, NOT 0: Number(null) is 0, and a missing coordinate
 *  read as the equator (0,0) is exactly the "confident wrong distance" to avoid. */
function finiteOrNull(value) {
  if (value === null || value === undefined || value === '') return null;
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

/**
 * Great-circle distance in kilometres, or null when any coordinate is missing or
 * out of range. Latitudes outside [-90, 90] and longitudes outside [-180, 180] are
 * treated as absent rather than computed, so a bad row cannot produce a confident
 * wrong distance.
 */
function haversineKm(aLat, aLng, bLat, bLng) {
  const la1 = finiteOrNull(aLat);
  const lo1 = finiteOrNull(aLng);
  const la2 = finiteOrNull(bLat);
  const lo2 = finiteOrNull(bLng);
  if (la1 === null || lo1 === null || la2 === null || lo2 === null) return null;
  if (Math.abs(la1) > 90 || Math.abs(la2) > 90 || Math.abs(lo1) > 180 || Math.abs(lo2) > 180) {
    return null;
  }
  const dLat = toRad(la2 - la1);
  const dLng = toRad(lo2 - lo1);
  const h = Math.sin(dLat / 2) ** 2
    + Math.cos(toRad(la1)) * Math.cos(toRad(la2)) * Math.sin(dLng / 2) ** 2;
  const km = EARTH_RADIUS_KM * 2 * Math.atan2(Math.sqrt(h), Math.sqrt(1 - h));
  return Math.round(km * 10) / 10;
}

/**
 * Attach `distance_km` to each venue, measured from the given origin. Venues keep
 * their input order; only the field is added. When the origin is not a usable
 * coordinate pair the list is returned unchanged, so a caller that did not send a
 * location pays nothing and sees no distance field.
 *
 * `venues` rows are expected to carry `latitude`/`longitude` (the venues table's own
 * columns). A row missing either gets `distance_km: null`.
 */
function annotateDistance(venues, { lat, lng } = {}) {
  const oLat = finiteOrNull(lat);
  const oLng = finiteOrNull(lng);
  if (!Array.isArray(venues) || oLat === null || oLng === null) return venues || [];
  if (Math.abs(oLat) > 90 || Math.abs(oLng) > 180) return venues;
  return venues.map((v) => ({
    ...v,
    distance_km: haversineKm(oLat, oLng, v.latitude, v.longitude),
  }));
}

/**
 * A copy of the list ordered nearest-first. A null distance (no coordinates) always
 * sorts last, because "distance unknown" must never masquerade as "very close". The
 * sort is stable within equal distances, so venues the model ranked higher keep their
 * order when they are the same distance away.
 */
function sortByNearest(venues) {
  if (!Array.isArray(venues)) return [];
  return venues
    .map((v, i) => ({ v, i }))
    .sort((a, b) => {
      const da = finiteOrNull(a.v.distance_km);
      const db = finiteOrNull(b.v.distance_km);
      if (da === null && db === null) return a.i - b.i;
      if (da === null) return 1;
      if (db === null) return -1;
      return da === db ? a.i - b.i : da - db;
    })
    .map((x) => x.v);
}

module.exports = { haversineKm, annotateDistance, sortByNearest };
