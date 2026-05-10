# API Endpoints — Express.js

Base URL: http://localhost:3000/api

## Auth (No token required)
```
POST /auth/register/player  body:{name,phone,password,firebaseUid,email,avatarUrl} → {token,user}
POST /auth/register/owner   body:{personal,ground,documents} → {token,user,status}
POST /auth/login            body:{identifier,password} → {token,user,status}
POST /auth/verify-phone     body:{firebaseUid,phone}
POST /auth/forgot-password/send-otp
POST /auth/forgot-password/reset
```

## Users (Token required)
```
GET   /users/me                 → {user}
PATCH /users/me/update          body:{name,email,avatarUrl} → {user}
POST  /users/me/change-password body:{currentPassword,newPassword} → {success}
```

## Wallet (Token required)
```
GET  /wallet/me                 → {balance, frozen_balance}
GET  /wallet/transactions       → [{transaction}]
POST /wallet/topup              body:{amount,paymentMethod} → {newBalance}
```

## Venues (Token required)
```
GET /venues?city=&sport_type=&date=&min_price=&max_price=   → [{venue with amenities and media}]
GET /venues/:id?date=YYYY-MM-DD                 → {venue_with_slots}
```

## Bookings (Player token required)
```
POST  /bookings                 body:{slotId,venueId} → {bookingId, qrData, depositAmount} (Deducts 30% from Player, Freezes in Owner Wallet)
GET   /bookings/my              → [{booking with venue+slot info}]
PATCH /bookings/:id/cancel      → {success, refund issued}
```

## Owner (Owner token required)
```
GET  /owner/venues          → [{venue}]
POST /owner/venues          body:{name,description,sport_type,city,address,base_price} → {venue}
POST /owner/venues/:id/slots body:{date,slots:[{start_time,end_time,price}]} → [{slot}]
GET  /owner/bookings        → [{pending bookings with player info}]
PUT  /owner/bookings/:id/approve → {success}
PUT  /owner/bookings/:id/reject  → {success, refund issued}
POST /owner/checkin         body:{qrData,venueId} → {playerName,slotTime,bookingId}
PATCH /owner/checkin/decide body:{bookingId,action:'check_in'|'no_show'} → {success}
```

## Response format (always)
```json
// Success
{ "success": true, "data": {...}, "message": "..." }

// Error
{ "success": false, "message": "error description" }
```
