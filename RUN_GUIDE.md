# SportLynk — Run & Firebase Setup Guide

## Quick Run

### Backend
```bash
cd D:\SportLynk\backend
npm start
```
Backend runs on `http://localhost:3000`

### Flutter (Chrome/Web)
```bash
cd D:\SportLynk
flutter run -d chrome
```

### Flutter (Android Emulator)
```bash
cd D:\SportLynk
flutter run -d emulator-5554
```

---

## Firebase Phone Authentication Setup (Step-by-Step)

### 1. Create Firebase Project
1. Go to [Firebase Console](https://console.firebase.google.com)
2. Click **"Add project"** → Name it **"SportLynk"**
3. Disable Google Analytics (not needed) → **Create Project**

### 2. Add Android App
1. In Firebase Console → Click the **Android icon**
2. Package name: `com.example.sportlynk`
   - Find this in `android/app/build.gradle.kts` → `applicationId`
3. App nickname: `SportLynk Android`
4. SHA-1 (REQUIRED for phone auth):
   ```bash
   cd D:\SportLynk\android
   .\gradlew signingReport
   ```
   Copy the SHA-1 hash from the output → paste in Firebase
5. Click **Register App**
6. Download `google-services.json`
7. Place it in: `D:\SportLynk\android\app\google-services.json`

### 3. Enable Phone Authentication
1. Firebase Console → **Authentication** (left sidebar)
2. Click **"Get started"** if not already enabled
3. Go to **Sign-in method** tab
4. Click **Phone** → Toggle **Enable** → **Save**

### 4. Add Test Phone Numbers (for development)
1. Firebase Console → Authentication → Sign-in method → Phone
2. Scroll down to **"Phone numbers for testing"**
3. Add test numbers:
   - `+923001234567` → Code: `123456`
   - `+923009876543` → Code: `123456`
4. These bypass actual SMS sending (free, no quota)

### 5. Configure Flutter
Run FlutterFire CLI:
```bash
dart pub global activate flutterfire_cli
flutterfire configure --project=your-firebase-project-id
```
This generates `lib/firebase_options.dart`

### 6. Update main.dart
After firebase_options.dart is generated, update `main.dart`:
```dart
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const SportLynkApp());
}
```

### 7. Switch from Mock to Real Firebase
In `lib/services/firebase_otp_service.dart`:
1. Change `static const bool _useMock = true;` → `false`
2. Uncomment the real Firebase implementation blocks
3. Add `import 'package:firebase_auth/firebase_auth.dart';` at top

### 8. Android Permissions
In `android/app/src/main/AndroidManifest.xml`, add if not present:
```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.RECEIVE_SMS" />
<uses-permission android:name="android.permission.READ_SMS" />
```

---

## Current Mock OTP Behavior
- Any 6-digit code is accepted (e.g., `123456`)
- Returns a mock Firebase UID like `mock_uid_123456`
- 2-second simulated delay for realistic UX
- All registration/login flows work end-to-end without Firebase

## Seeded Test Accounts
| Name | Email | Phone | Password | Role |
|------|-------|-------|----------|------|
| Ahmed Khan | ahmed@sportlynk.pk | 03001234567 | password123 | owner |
| Sara Malik | sara@sportlynk.pk | 03009876543 | password123 | owner |
| Bilal Raza | bilal@test.pk | 03331122334 | password123 | player |
| Hina Farooq | hina@test.pk | 03211234567 | password123 | player |
| Usman Ali | usman@test.pk | 03451234567 | password123 | player |

> **Note**: Seeded owners were created before the verification system. They can login
> directly since they don't have owner_profiles with verification_status. New owners
> registered through the app will be marked `pending` and blocked from login.
