const path = require("path");
require("dotenv").config({ path: path.join(__dirname, ".env") });
const fs = require("fs");
const pool = require("./src/db/pool");

/**
 * Split SQL into executable statements, treating do $$ ... $$; blocks as single
 * atomic units (they contain inner semicolons that must not be split on).
 */
function parseStatements(sql) {
  const statements = [];
  // Regex: greedily matches a full do $$ … $$; block (non-greedy inner match)
  const doPattern = /DO\s+\$\$[\s\S]*?\$\$\s*;/g;

  let lastIndex = 0;
  let match;

  while ((match = doPattern.exec(sql)) !== null) {
    // Split the text *before* this do block on regular semicolons
    const before = sql.slice(lastIndex, match.index);
    before
      .split(";")
      .map((s) => s.trim())
      .filter((s) => s.replace(/--[^\n]*/g, "").trim().length > 0)
      .forEach((s) => statements.push(s));

    // Add the do $$ block as a single, unsplit statement
    statements.push(match[0].trim());
    lastIndex = match.index + match[0].length;
  }

  // Handle any SQL that comes after the last do block
  const after = sql.slice(lastIndex);
  after
    .split(";")
    .map((s) => s.trim())
    .filter((s) => s.replace(/--[^\n]*/g, "").trim().length > 0)
    .forEach((s) => statements.push(s));

  return statements;
}

async function runMigration007() {
  const client = await pool.connect();
  try {
    const sqlPath = path.join(
      __dirname,
      "migrations",
      "007_owner_booking_updates.sql",
    );
    const sql = fs.readFileSync(sqlPath, "utf8");

    const statements = parseStatements(sql);
    console.log(`Parsed ${statements.length} statement(s) from SQL file.\n`);

    let success = 0;
    let skipped = 0;

    for (const stmt of statements) {
      if (!stmt) continue;
      // Ensure every statement ends with exactly one semicolon
      const stmtToRun = stmt.endsWith(";") ? stmt : stmt + ";";
      try {
        await pool.query(stmtToRun);
        success++;
        console.log(`✅ OK:      ${stmt.substring(0, 80).replace(/\n/g, " ")}`);
      } catch (e) {
        if (
          e.message.includes("already exists") ||
          e.message.includes("duplicate")
        ) {
          skipped++;
          console.log(
            `⏭️  Skipped: ${stmt.substring(0, 80).replace(/\n/g, " ")}`,
          );
        } else {
          console.error(`❌ Error:   ${e.message}`);
          console.error(
            `   Stmt:    ${stmt.substring(0, 120).replace(/\n/g, " ")}`,
          );
        }
      }
    }

    console.log(
      `\n✅ Migration 007 complete: ${success} succeeded, ${skipped} skipped`,
    );
    process.exit(0);
  } catch (e) {
    console.error("Migration failed:", e.message);
    process.exit(1);
  } finally {
    client.release();
  }
}

runMigration007();
