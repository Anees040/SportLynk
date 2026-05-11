# SportLynk Owner Screen Development Guide

This guide contains everything you need to know about the SportLynk backend architecture, database schema, and established patterns to successfully implement the Venue Owner Screen MVP.

## 1. Core Architecture & Schema

### User Roles
The system has `player` and `owner` roles. Owners manage venues and slots.
```sql
CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  email VARCHAR(255) UNIQUE NOT NULL,
  role user_role DEFAULT 'player', -- Can be 'player' or 'owner'
  -- ...
);
```

### Venues & Dynamic Pricing
Owners can create multiple venues. Venues have dynamic pricing fields added in migration `005`.
```sql
CREATE TABLE IF NOT EXISTS venues (
  id UUID PRIMARY KEY,
  owner_id UUID REFERENCES users(id),
  name VARCHAR(255) NOT NULL,
  sport_type VARCHAR(50),
  price_per_hour DECIMAL(10,2), -- Base Price
  upfront_percent DECIMAL(5,2) DEFAULT 30.00, -- Dynamic percentage required at booking
  discount_percent DECIMAL(5,2) DEFAULT 0.00, -- Discount if paying full in advance
  is_active BOOLEAN DEFAULT true
);
```

### Slot Management
Slots are the inventory. The player's booking flow relies on a real-time optimistic locking system (`temporarily_locked`) before actual booking (`booked`).
```sql
CREATE TABLE IF NOT EXISTS slots (
  id UUID PRIMARY KEY,
  venue_id UUID REFERENCES venues(id),
  slot_date DATE NOT NULL,
  start_time TIME NOT NULL,
  end_time TIME NOT NULL,
  status slot_status DEFAULT 'available', -- 'available', 'temporarily_locked', 'booked'
  locked_by UUID REFERENCES users(id),    -- Set when a player clicks a slot
  locked_at TIMESTAMP                     -- Auto-released after 2 mins if not booked
);
```

### Bookings & Escrow Flow (CRITICAL)
When a player books a slot, their `security_deposit` is **Frozen** in their wallet. It is NOT transferred to the owner immediately.

```sql
CREATE TABLE IF NOT EXISTS bookings (
  id UUID PRIMARY KEY,
  player_id UUID REFERENCES users(id),
  venue_id UUID REFERENCES venues(id),
  slot_id UUID REFERENCES slots(id),
  status booking_status DEFAULT 'confirmed', -- 'pending', 'confirmed', 'checked_in', 'completed', 'no_show', 'cancelled'
  security_deposit DECIMAL(10,2) DEFAULT 0,  -- The amount frozen in the player's wallet
  total_amount DECIMAL(10,2) NOT NULL        -- The total price of the slot
);
```

#### The Resolution Flow (Owner Action)
When the booking date arrives, the Owner must mark the booking as `completed` (if the player pays the remainder and plays) or `no_show` (if they fail to arrive).
You must call `POST /api/bookings/:id/resolve` with `{ "status": "completed" | "no_show" }`.
This API automatically:
1. Deducts the `security_deposit` from the Player's `frozen_balance`.
2. Adds the `security_deposit` to the Owner's `balance`.
3. Creates detailed `transactions` for both parties.

## 2. Wallet Ecosystem
Every user (player and owner) has a single wallet.
```sql
CREATE TABLE IF NOT EXISTS wallets (
  id UUID PRIMARY KEY,
  user_id UUID UNIQUE REFERENCES users(id),
  balance DECIMAL(10,2) DEFAULT 500.00,        -- Available to withdraw/spend
  frozen_balance DECIMAL(10,2) DEFAULT 0.00    -- Escrow holdings (players only)
);
```
**For the Owner UI:**
- Show the Owner's `balance`.
- Show recent `transactions` using `GET /api/wallet/history`.

## 3. UI/UX Guidelines
- **Custom Loader:** Use the `CustomLoader` widget from `lib/widgets/custom_loader.dart` instead of standard `CircularProgressIndicator`.
- **Aesthetics:** Use `AppColors` and `GoogleFonts.poppins`. Avoid plain Material standard UIs. Build modern, overlapping card-based designs with subtle shadows.
- **Pull-to-refresh:** Use `RefreshIndicator` wrapping a `ListView.builder(physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()))`.

## 4. Owner Endpoints (Ready to Use)
The backend is already fully equipped with all the endpoints required to build the Owner Interface. You DO NOT need to build these in Node.js, they are already working:
1. `GET /api/owner/venues` - Retrieves all venues owned by the logged-in owner.
2. `POST /api/owner/venues` - Creates a new venue.
3. `PUT /api/owner/venues/:id` - Updates venue details (price, upfront %, etc).
4. `GET /api/owner/venues/:id/slots` - Gets slots generated for a specific venue.
5. `POST /api/owner/venues/:id/slots` - Generates slots for a specific date range.
6. `GET /api/owner/bookings` - Lists all bookings for all venues owned by the owner.
7. `POST /api/bookings/:id/resolve` - (CRITICAL) Resolves a booking (completed/no_show) to release the escrow frozen balance to the owner.

## 5. Required Owner Flutter Screens
To complete the Owner App, the agent should generate the following screens exactly in this order:

### A. `owner_home_screen.dart`
- **Purpose:** The main dashboard.
- **UI:** A beautiful top gradient header displaying total lifetime earnings and current available wallet balance. Below the header, a 2x2 grid with: "My Venues", "Manage Slots", "Active Bookings", and "Wallet/Transactions".
- **API:** Fetch summary data from `GET /api/owner/bookings` and `GET /api/wallet`.

### B. `owner_venues_screen.dart`
- **Purpose:** List and edit venues.
- **UI:** A list of cards showing venue cover photos, names, and pricing. A floating action button (FAB) to add a new venue.
- **API:** `GET /api/owner/venues`.

### C. `owner_create_venue_screen.dart`
- **Purpose:** Form to create or edit a venue.
- **Fields:** Name, Address, Sport Type (Dropdown), Base Price, Upfront % (Default 30%), Discount %.
- **Media:** Must allow taking/picking photos and uploading to Cloudinary (use existing `CloudinaryService`).

### D. `owner_slots_screen.dart`
- **Purpose:** The inventory manager.
- **UI:** A calendar widget at the top. Below, a list of slots for the selected date. A button to "Generate Slots".
- **API:** `POST /api/owner/venues/:id/slots` where the owner inputs start hour, end hour, and duration (e.g., 60 mins).

### E. `owner_bookings_screen.dart` (Escrow Resolution)
- **Purpose:** The most important operational screen. Shows upcoming and past bookings.
- **UI:** Tab view (Upcoming / Past).
- **Action:** For "Upcoming" bookings that are on the current date, show a "Resolve" button. Pressing this opens a bottom sheet asking if the player arrived.
- **API:** Calls `POST /api/bookings/:id/resolve` with `{ "status": "completed" }` or `{ "status": "no_show" }`. This securely releases the player's frozen deposit into the owner's withdrawable wallet balance.

## 6. Implementation Rules for the AI Agent
1. **Never use generic material colors.** Always use `AppColors.primary`, `AppColors.accent`, and `AppColors.background`.
2. **Never use standard CircularProgressIndicator.** Always use `CustomLoader()` from `widgets/custom_loader.dart`.
3. **Never write raw HTTP requests.** Always use `ApiService.get()`, `ApiService.post()`, etc., which automatically handles auth tokens.
4. **Always run `flutter analyze`** after creating a screen to ensure zero warnings.
5. **Wallet Focus:** Make sure the financial numbers (Escrow transfers) are extremely prominent and professional. Owners care about their money.
