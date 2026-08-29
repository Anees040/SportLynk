# Tournaments — the evidence pack

**This file is generated. Do not edit it by hand.** Every line below was written by a
verification script that had just asserted it against the live database, inside one
transaction that was then rolled back — so the run leaves no rows behind and the
document is reproducible rather than a description of a state somebody once had. To
regenerate:

```
cd backend && node src/scripts/check_tournaments.js --evidence
```

A block absent from this file was not run — it is not a pass.

<!-- tournament-evidence:tournaments BEGIN -->

## S.7 Wave A -- the tournament module, driven through `tournamentService`

Five tournaments -- one cancelled under its minimum, an 8-team knockout played to a champion, a 5-team knockout with byes, a 4-team round-robin decided on goal difference, and one driven through the S.2 captain-submit door -- created, paid into, drawn onto real venue hours, played out and audited, all inside ONE transaction that is rolled back at the end. Every money assertion reads the WALLET and the LEDGER rather than the return value: the return value is the thing under test, not the evidence.

**FAIL 2/3** · 0 skipped · produced Aug 29, 2026, 22:35:26 PKT (2026-08-29T17:35:26.444Z)

| provenance | value |
|---|---|
| command | `cd backend && node src/scripts/check_tournaments.js --evidence` |
| commit | `fe1c425` — feat: implement Wave S6-D Scout (Flutter UI & End-to-End Integration) · **47 uncommitted path(s) in the tree** |
| node | v22.19.0 on win32 |

### Every assertion, in the order it was made

**The rollback**

- ✓ after ROLLBACK not one captain this run created still exists
- ✓ and not one tournament — the database is exactly as it was

<!-- tournament-evidence:tournaments END -->
