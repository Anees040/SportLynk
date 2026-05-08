6.2  Day 2 Prompts — Auth Screens + Venue Listing

Prompt 2-A: Login and Register Screens

Create beautiful Flutter login and register screens for SportLynk (a sports booking app).
Design should use a dark navy (#1F3864) and bright blue (#2E75B6) color scheme.
SportLynk logo area should be at top with a sports-themed gradient header.

Login screen: email field, password field, login button, link to register.
Register screen: full name field, email, phone, password, role selection
(two cards: 'I am a Player' and 'I am a Venue Owner'), register button.

On login success, navigate to PlayerHomeScreen or OwnerDashboardScreen based on role.
Use AuthService for all calls. Show loading indicator during API calls.
Show SnackBar on errors. Use go_router for navigation.
Save files to lib/screens/auth/login_screen.dart and register_screen.dart

Prompt 2-B: Venue Service

Create lib/core/services/venue_service.dart for SportLynk.
Supabase tables involved: venues, venue_slots.

Include these methods:
- getAllVenues({String? sportFilter, String? cityFilter}) — fetches active venues
- getVenueById(venueId) — full venue details
- getSlotsForVenue(venueId, date) — slots for a specific date
- createVenue(Venue venue) — owner creates venue
- updateSlotStatus(slotId, status) — change slot to booked/blocked/available
- generateSlotsForDate(venueId, date, openTime, closeTime, slotDuration, price)
  — creates hourly slot rows for a given date

Return Venue and VenueSlot model objects. Handle Supabase errors.

Prompt 2-C: Venue List Screen (Player View)

Create lib/screens/player/venue_list_screen.dart for SportLynk.
This is the main player home screen showing available venues.

Design requirements:
- Search bar at top to filter by city or name
- Sport filter chips below: All, Football, Cricket
- ListView of venue cards showing: venue image (using cached_network_image),
  venue name, city, sport types, price per hour
- Tap on a card navigates to VenueDetailScreen passing venueId
- Pull-to-refresh functionality
- Loading state with shimmer-like placeholder cards
- Empty state when no venues found

Use VenueService.getAllVenues() to fetch data. Use Provider for state.
Bottom navigation: Home (venues), Bookings, Wallet, Profile.

Prompt 2-D: Venue Detail Screen

Create lib/screens/player/venue_detail_screen.dart for SportLynk.
This screen receives a venueId as parameter via go_router.

Show:
- PageView of venue images at top (swipeable gallery)
- Venue name, address, city
- Sport type chips
- Description text
- Price per hour
- A date selector (show next 7 days as horizontal scrollable date chips)
- Slot availability timeline: hourly slots shown as colored blocks
  Green = available, Red = booked, Gray = blocked
- Tap on a green slot navigates to BookingScreen

Fetch venue with VenueService.getVenueById() and
VenueService.getSlotsForVenue() when date changes.

6.3  Day 3 Prompts — Booking Flow & Wallet

Prompt 3-A: Wallet Service

Create lib/core/services/wallet_service.dart for SportLynk.
Supabase tables: wallets, wallet_transactions.

Methods needed:
- getWallet(userId) — fetch wallet for user
- topUpWallet(userId, amount) — increase available_balance
- freezeDeposit(userId, amount, bookingId) — move amount from available to frozen
  and create a wallet_transaction row of type 'freeze'
- releaseDeposit(userId, amount, bookingId) — move from frozen to available for refund
  and create a wallet_transaction row of type 'release'
- payOwner(playerId, ownerId, amount, bookingId) — deduct from player's frozen,
  add to owner's available, create transaction rows for both
- getTransactionHistory(userId) — recent wallet_transactions for wallet

IMPORTANT: freezeDeposit must check available_balance >= amount before proceeding.
Throw an exception with message 'Insufficient wallet balance' if not enough.

Prompt 3-B: Booking Service

Create lib/core/services/booking_service.dart for SportLynk.
Supabase tables: bookings, venue_slots.

Methods:
- createBooking(playerId, slotId, venueId, totalAmount) — creates booking with
  depositAmount = totalAmount * 0.20, status = 'pending',
  qrCode = generated booking ID, then freezes deposit in wallet
  then sets slot status to 'booked'
- getPlayerBookings(playerId) — all bookings for a player
- getOwnerBookings(venueId) — all bookings for owner's venue
- approveBooking(bookingId) — owner confirms booking, status = 'confirmed'
- checkInBooking(bookingId) — owner scans QR, status = 'checked_in',
  triggers payOwner() in wallet service
- markNoShow(bookingId) — status = 'no_show', deposit transferred to owner
- cancelBooking(bookingId) — status = 'cancelled', deposit refunded to player

All operations must be atomic where possible (do all steps or rollback).

Prompt 3-C: Booking Screen

Create lib/screens/player/booking_screen.dart for SportLynk.
This screen receives: venueId, slotId, slotDate, slotStartTime, slotEndTime, slotPrice.

Show a booking summary:
- Venue name
- Date and time of slot
- Total price: slotPrice
- Security deposit (20%): slotPrice * 0.20 — highlighted in amber color
- Balance due at venue: slotPrice * 0.80
- Current wallet available balance (fetch from WalletService)
- Warning if balance < deposit amount: 'Insufficient balance - please top up wallet'
- Top Up Wallet button if insufficient (for demo: simple dialog to add balance)
- Confirm Booking button

On Confirm: call BookingService.createBooking(), on success navigate to
BookingConfirmationScreen passing the new booking object.

Prompt 3-D: Booking Confirmation + QR Screen

Create lib/screens/player/booking_confirmation_screen.dart for SportLynk.
Receives a Booking object.

Show:
- Big green checkmark animation at top
- 'Booking Confirmed!' title
- Booking ID
- Venue name, date, time
- Deposit frozen: show amount in amber
- A QR code generated using qr_flutter package
  QR data = booking.qrCode (the booking ID)
- Instruction: 'Show this QR code to the venue owner when you arrive'
- Done button that goes back to home screen

Also create lib/screens/player/wallet_screen.dart showing:
- Available Balance (green)
- Frozen Balance (amber) with note 'Reserved for active bookings'
- Transaction history list from WalletService.getTransactionHistory()
- Each transaction: icon, type, amount, date, reference
- A top-up button (demo only: dialog to enter amount and call topUpWallet)

6.4  Day 4 Prompts — Owner Dashboard

Prompt 4-A: Owner Dashboard Home

Create lib/screens/owner/owner_dashboard_screen.dart for SportLynk.
This is the main screen for venue owners after login.

Show:
- Welcome header with owner's name
- Summary cards: Today's Bookings count, Pending Approvals count, Today's Earnings
- Quick actions: 'Manage Slots', 'View Bookings', 'My Venues', 'Wallet'
- Bottom navigation: Dashboard, Bookings, Venues, Wallet, Profile

Use BookingService.getOwnerBookings() filtered to today.
Fetch owner's venues using VenueService filtered by ownerId.

Prompt 4-B: Venue Creation Form

Create lib/screens/owner/venue_form_screen.dart for SportLynk.
This is the form where an owner creates a new venue.

Fields:
- Venue name (required)
- Description (multiline)
- Address (required)
- City dropdown: Islamabad, Lahore, Karachi, Rawalpindi
- Sport types checkboxes: Football, Cricket (at least one required)
- Base price per hour (number input)
- Images: allow picking up to 5 images from gallery using image_picker,
  upload to Supabase Storage bucket called 'venue-images'
  store returned URLs in venue.images array

On submit: validate all fields, call VenueService.createVenue()
Show success message and navigate back to dashboard.

Prompt 4-C: Slot Management Screen

Create lib/screens/owner/slot_management_screen.dart for SportLynk.
Receives venueId. Owner manages slots for their venue.

Show:
- Horizontal date selector for next 14 days
- For selected date: grid of hourly slots (8 AM to 10 PM)
  Each slot: time range, price, status color (green/red/gray)
  Tap to toggle between available and blocked
- Button: 'Generate Slots for This Date' — calls VenueService.generateSlotsForDate()
  which creates 14 hourly slot rows from 8 AM to 10 PM at base_price each
- Save Changes button

Use VenueService.getSlotsForVenue() and VenueService.updateSlotStatus().

Prompt 4-D: Booking Requests + QR Check-In

Create lib/screens/owner/booking_requests_screen.dart for SportLynk.
Shows all bookings for the owner's venues.

Two tabs: 'Pending' and 'Confirmed'

Each booking card shows:
- Player name, date, time, slot
- Amount, deposit
- For Pending: Approve button and Reject button
- For Confirmed: 'Scan QR Check-In' button

Also create lib/screens/owner/qr_checkin_screen.dart:
- Uses mobile_scanner package to open camera and scan QR
- When QR detected, extract booking ID from QR data
- Call BookingService.checkInBooking(bookingId)
- Show success: 'Check-in confirmed! Payment released to your wallet'
- Show error if booking ID not found or already checked in
