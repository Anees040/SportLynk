/**
 * CSV writing, with the one thing every naive CSV writer gets wrong.
 *
 * THE INJECTION PROBLEM (the reason this file exists)
 * Excel, LibreOffice and Google Sheets treat a cell whose text begins with
 * `=`, `+`, `-`, `@`, a tab or a carriage return as a FORMULA, not as text. A
 * venue named `=cmd|'/c calc'!A1` therefore executes when an owner opens the
 * export their own dashboard produced. It is a real, catalogued vulnerability
 * (CSV / formula injection) and the export surface is exactly where it lands,
 * because every field in it is a name somebody else typed.
 *
 * The fix is to prefix such a field with a single quote, which those programs
 * read as "the rest of this cell is literal text". `'` is stripped again by the
 * spreadsheet on display, so the sheet shows the venue's real name and the
 * formula never runs.
 *
 * WHY NOT JUST WRAP EVERYTHING IN QUOTES
 * Because quoting does not help: `"=1+1"` is still evaluated. Quoting solves
 * commas and newlines; the leading apostrophe solves formulas. Both are needed,
 * and this file does both.
 *
 * THE OTHER TWO RULES
 *   - a field containing `"` `,` `\n` or `\r` is wrapped in quotes and its own
 *     quotes are DOUBLED (RFC 4180),
 *   - the file opens with a UTF-8 BOM. Without it Excel on Windows reads the
 *     bytes as the system codepage and every Urdu venue name, every ₨ and every
 *     em dash in the export turns to mojibake.
 */

/** The characters a spreadsheet reads as "this cell is a formula". */
const FORMULA_START = /^[=+\-@\t\r]/;

/**
 * One field, escaped for a spreadsheet AND for the CSV grammar, in that order.
 *
 * Order matters: the apostrophe has to go on before the quoting decision, or a
 * field like `-5,00` gets quoted for its comma, escapes the formula check on the
 * quoted form, and arrives as a formula anyway.
 */
function cell(value) {
  if (value === null || value === undefined) return '';
  let s = typeof value === 'string' ? value : String(value);
  // Nothing to protect against in a number we produced ourselves, and prefixing
  // one would turn it into text and break every SUM() in the sheet.
  if (typeof value === 'number') return String(value);

  if (FORMULA_START.test(s)) s = `'${s}`;
  if (/["\n\r,;]/.test(s)) s = `"${s.replace(/"/g, '""')}"`;
  return s;
}

/** One CSV line, terminated CRLF as RFC 4180 requires. */
function row(values) {
  return `${values.map(cell).join(',')}\r\n`;
}

/** Excel needs this to read the file as UTF-8. */
const BOM = '﻿';

/**
 * A money value as a plain decimal string with two places.
 *
 * pg returns DECIMAL as a string, so `asNum` first (the golden rule), and never
 * `toLocaleString` — a thousands separator inside an unquoted CSV field is a new
 * column, and inside a quoted one it stops the cell being a number at all.
 */
function money(v) {
  const n = typeof v === 'number' ? v : Number.parseFloat(String(v ?? '0'));
  return Number.isFinite(n) ? n.toFixed(2) : '0.00';
}

/** `2026-08-31` from a Date or a pg date string, in UTC. Never a locale format. */
function isoDate(v) {
  if (!v) return '';
  if (v instanceof Date) return v.toISOString().slice(0, 10);
  const s = String(v);
  return /^\d{4}-\d{2}-\d{2}/.test(s) ? s.slice(0, 10) : s;
}

/** `HH:MM` from a pg `time` value. */
function hhmm(v) {
  if (!v) return '';
  const s = String(v);
  return /^\d{2}:\d{2}/.test(s) ? s.slice(0, 5) : s;
}

/**
 * A filename safe on Windows, macOS and in a Content-Disposition header.
 * Anything outside `[A-Za-z0-9._-]` becomes `_`, because a quote or a semicolon in
 * a filename is a header-injection question nobody should have to think about.
 */
function safeFilename(name) {
  return String(name || 'export').replace(/[^A-Za-z0-9._-]/g, '_').slice(0, 80);
}

module.exports = { cell, row, money, isoDate, hhmm, BOM, safeFilename, FORMULA_START };
