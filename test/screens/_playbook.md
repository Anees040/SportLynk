# Screen-test authoring playbook (SportLynk) — temporary, delete when done

You are writing Flutter **widget tests** for SportLynk screens. This file is the
contract. Follow it exactly. Do not deviate, do not invent shortcuts.

## Step 0 — orient

Read these, in full, before writing a line of test code:

1. `D:\sportlynk\CLAUDE.md` — house rules (comment register, UI rules, four states).
2. `D:\sportlynk\test\screens\screen_harness.dart` — the shared harness. Learn the
   exact signatures of: `FakeApi` (`install`, `on`, `ok`, `fail`, `offline`, `to`,
   `countTo`, `requests`), `FakeResponse` (`ok`, `fail`, `offline`), `RecordedRequest`
   (`method`, `uri`, `body`, `path`, `param`), `FakeAuth({role,id,name,token})`,
   `pumpScreen(tester, screen, {auth, providers, textScale, size, navigatorKey})`,
   `settleData(tester, {step})`, `expectTapTarget(tester, finder, {minimum})`,
   `expectNoOverflow`, `ignoreOverflow`, `expectLoading`, `tapVisible`, `RouteLog`.
3. `D:\sportlynk\test\screens\player\create_team_screen_test.dart` — exemplar for a
   **form that POSTs**: first-frame render, client-side validation that makes no
   request, request-body assertions via `jsonDecode(api.to(path).single.body!)`,
   success vs failure branch, snackbar draining, tap-target + doubled-scale.
4. `D:\sportlynk\test\screens\shared\chats_screen_test.dart` — exemplar for a
   **socket-backed list**: the four states, pagination, badges, pull-to-refresh,
   doubled-scale under `ignoreOverflow`.

These two exemplars are the ground truth for how to call the harness. Mirror them.

## Step 1 — read each screen, then its services

For every screen assigned: open `lib/screens/<role>/<name>.dart` and read all of it.
Then open every `lib/services/*.dart` it calls and read the method it uses, to learn
the **exact endpoint path suffix** and the request/response JSON shape. Never guess an
endpoint or a field name — read it. `ApiConstants` in `lib/constants/api_constants.dart`
resolves the path constants.

## Step 2 — hazard scan (decides how you mount)

- Calls `RealtimeService().ensureConnected(token)` (grep the screen): mount with
  `FakeAuth(token: null)`. The screen reads `token ?? ''` and `ensureConnected`
  returns early on an empty token, so no socket connect-timer is registered. Omitting
  this makes the test fail with a pending 20-second timer. `_myId` still resolves
  because `FakeAuth` always builds its user.
- Only `RealtimeService().<stream>.listen(...)` with no `ensureConnected`: safe, the
  broadcast stream registers no timer.
- Starts a `Timer.periodic` / `Stream.periodic` **on mount**: end the test by
  unmounting — `await tester.pumpWidget(const SizedBox());` — which triggers the
  screen's `dispose` and cancels the timer, so no pending-timer failure. Do this as
  the last line of any such test.
- Debounce `Timer` created only on a text change (search/quote fields): mount is safe;
  when a test types into the field, advance past the debounce with
  `await tester.pump(const Duration(milliseconds: <debounce+50>));`.
- Calls `Firebase.*`, or uses a camera/QR/scanner plugin, or any mandatory platform
  channel with no test shim: the screen is likely **unmountable** in a widget test.
  Do NOT force it and do NOT write a fake that only pretends to test it. SKIP it and
  report why.
- Uses `ImagePicker` / a file picker: never tap the picker (it opens a platform
  sheet). Test everything around it.

## Step 3 — what to cover

CLAUDE.md requires four visible states of every network-waiting widget, so cover the
ones that apply:

- **loading** — a delayed fixture (`api.ok(path, data, delay: const Duration(milliseconds: 300))`),
  assert the `CircularProgressIndicator` is up, then drain with
  `settleData(tester, step: const Duration(milliseconds: 400))`.
- **empty** — fixture returns `[]`; assert the empty copy the screen actually shows.
- **error with retry** — `api.fail(path, 'msg')` or `api.offline(path)`; assert the
  message AND the retry control; then restub `api.ok(path, ...)`, tap retry, assert
  the content arrives.
- **loaded** — assert the real content from a representative fixture.

For a form: first-frame render; validation that blocks a bad submit and makes no
request (`api.countTo(path)` is 0); the request body is correct (decode it); success
branch; failure branch surfaces the server's message and keeps the screen; no
double-submit while a request is in flight.

## Step 4 — rules that keep tests green

- Mount only through `pumpScreen`. Its default size is `Size(430, 915)` (phone width).
- **The test font renders square-em glyphs, roughly twice the width of the app's
  Poppins.** A `RenderFlex` overflow at this width is the harness's artifact, not a
  product defect. NEVER assert `expectNoOverflow` on a content-dense row or a loaded
  card. For any doubled-text-scale test, call `ignoreOverflow()` first, then assert the
  content is present (`find.text` finds off-screen widgets too). Reserve
  `expectNoOverflow` for genuinely short, simple layouts.
- After asserting a snackbar's text, drain its dismiss timer:
  `await tester.pump(const Duration(seconds: 4)); await tester.pumpAndSettle();`.
- Assert reach on icon-only buttons with `expectTapTarget`; they should carry a
  tooltip/semantics label — if one does not, note it as a defect (do not fix it).
- Comments in the test: formal, third person, stating the contract the test pins.
  No "we/let's/you", no hedging ("just", "simply"), no emoji, no caps. Match the
  exemplars' register. Explain *why* a non-obvious assertion holds.
- One file per screen: `test/screens/<role>/<name>_test.dart`, mirroring the lib path.
- Do not touch `lib/`. Do not run any git command. No dummy or placeholder assertions.
  Assert only on things you read in the source.

## Step 5 — verify if the environment allows

Try `flutter test test/screens/<role>/<name>_test.dart`. On Windows the compact
reporter is CR-separated, so read it as:
`flutter test <file> 2>&1 | tr '\r' '\n' | grep -E "All tests passed|Some tests failed|\+[0-9]+"`.
If Bash is unavailable in your environment (a model-classifier outage may block it),
do NOT block — author carefully against the exemplars and report that you could not
verify. If it runs and any test fails, iterate until green.

## Step 6 — report

For each screen: the file path, the number of tests, whether you verified it and the
pass count, any screen you SKIPPED and the reason, and any product defect you noticed
(listed, not fixed).
