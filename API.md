# API Endpoints — Express.js

Base URL: http://localhost:3000/api

## Auth (No token required)
```
POST /auth/register  body:{name,email,password,role,phone} → {token,user}
POST /auth/login     body:{email,password} → {token,user}
GET  /auth/me        header:Bearer token → {user}
```

## Venues (Public — no token)
```
GET /venues?city=&sport_type=   → [{venue}]
GET /venues/:id                  → {venue}
GET /venues/:id/slots?date=YYYY-MM-DD → [{slot}]
```

## Bookings (Player token required)
```
POST /bookings              body:{slotId,venueId} → {bookingId,qrData,depositAmount}
GET  /bookings/my           → [{booking with venue+slot info}]
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
