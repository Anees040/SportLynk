# SportLynk — Complete Prompt Guide
# READ THIS BEFORE USING ANY PROMPT

---

## HOW TO USE THESE PROMPTS

Each prompt is a SEPARATE Claude conversation.
Start fresh for each one. Do NOT continue from previous conversation.

### Order (NEVER skip, NEVER reorder):
1. PROMPT_1_SCHEMA_BACKEND.md   → SQL + backend routes
2. PROMPT_2_FIXED_HOME_PROFILE.md → Player home + profile screens
3. PROMPT_3_VENUES_BOOKING.md   → Venues + booking flow
4. PROMPT_4_WALLET_BOOKINGS.md  → Wallet + bookings history
5. PROMPT_5_TEAMS_UI.md         → Teams screens (UI only)

### How to paste:
- Open new Claude conversation
- Type: "You are a Flutter/Node.js developer. Here are your instructions:"
- Paste the entire .md file content
- Send

### After each prompt:
1. Save all files Claude gives you
2. Run: flutter analyze
3. Fix any import errors (usually just package name)
4. Run app and test the new screen
5. Only then move to next prompt

---

## COMMON FIXES AFTER EACH PROMPT

### Import error: "package:sportlynk/..."
Your package name might be different. Check pubspec.yaml name field.
Replace 'sportlynk' with your actual package name everywhere.

### HTTP error: connection refused
Backend not running. Open terminal → cd backend → npm run dev

### Null check error on token
AuthProvider.token is null = user not logged in.
Fix: ensure AuthGuard wraps the screen.

### Overflow errors
Add: mainAxisSize: MainAxisSize.min on Column
Or wrap in Flexible/Expanded
Or wrap in SingleChildScrollView

---

## WHAT EACH PROMPT BUILDS

### PROMPT 1 — Schema + Backend
- SQL migration (slots, bookings, transactions, teams tables)
- routes/venues.js (GET list, GET detail with slots)
- routes/bookings.js (POST create, GET my, PATCH cancel)
- routes/wallet.js (GET balance, GET transactions, POST topup)
- routes/player.js (GET home data)
- Test data: 3 venues + slots for 14 days

### PROMPT 2 — Player Home + Profile
- player_home_screen.dart with bottom navigation (5 tabs)
- player_profile_screen.dart (editable, loads from DB)
- trust_score_screen.dart (visual score ring)
- Stub files for bookings + wallet (replaced in Prompt 4)

### PROMPT 3 — Venues + Booking
- find_venues_screen.dart (search + sport filter)
- venue_detail_screen.dart (date picker + slot grid)
- confirm_booking_screen.dart (payment breakdown + confirm)

### PROMPT 4 — Wallet + Bookings
- wallet_screen.dart (balance card + top-up sheet)
- wallet_history_screen.dart (filterable transaction list + detail bottom sheet)
- bookings_screen.dart (Upcoming/Past tabs + cancel)

### PROMPT 5 — Teams UI
- teams_screen.dart (my team card + challenges + results)
- create_team_screen.dart (form UI)
- team_roster_screen.dart (members + AI recommended)
- find_opponents_screen.dart (competitiveness bars)
- team_rankings_screen.dart (city leaderboard)

---

## BEFORE PRESENTATION CHECKLIST

- [ ] Change AppConfig.devMode = false in lib/constants/app_config.dart
- [ ] Change API base from 10.0.2.2 to your server IP if testing on real device
- [ ] Add Firebase test phone numbers for OTP demo:
      Firebase Console → Auth → Phone → Test Numbers
      Add: +923001234567 with code 123456
- [ ] Top up a test wallet: Run in pgAdmin:
      UPDATE wallets SET balance = 10000
      WHERE user_id = (SELECT id FROM users WHERE role='player' LIMIT 1);
- [ ] Approve a test owner: Run in pgAdmin:
      UPDATE owner_profiles SET verification_status = 'approved'
      WHERE user_id = (SELECT id FROM users WHERE role='owner' LIMIT 1);
- [ ] flutter build apk --release
- [ ] Test the full flow: Register → Home → Find Venue → Book → Check Wallet

---

## KNOWN LIMITATIONS (mention in presentation)

1. Image upload: stores local file path. Production needs Supabase Storage (15min fix).
2. Real SMS OTP: needs Firebase Blaze plan ($). Test numbers work for demo.
3. Teams: UI only, full backend in v2.
4. Payments: simulated wallet only. Real payment via JazzCash/EasyPaisa in v2.
5. Maps: Google Maps link validation only. Full map view in v2.
