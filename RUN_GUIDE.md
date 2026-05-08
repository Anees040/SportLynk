# 🏃 How to Run SportLynk

To run the project, you need to start **two separate servers**: the Backend (Node.js) and the Frontend (Flutter). If you close the terminal or the browser, the app will stop working.

## Step 1: Start the Backend (API)
The backend must be running for login and data to work.
1.  Open a new terminal (Command Prompt or PowerShell).
2.  Navigate to the backend folder:
    ```powershell
    cd D:\SportLynk\backend
    ```
3.  Run the start command:
    ```powershell
    npm start
    ```
4.  **Important:** Keep this terminal open. You should see `🚀 SportLynk API running on port 3000`.

## Step 1.5: Run the Auth Migration (once)
Run the migration script to update auth tables and enums:
```powershell
psql "<YOUR_DATABASE_URL>" -f .\src\scripts\migration_v2.sql
```
If you use pgAdmin, open and run the file in the Query Tool:
```text
backend\src\scripts\migration_v2.sql
```

## Step 2: Start the Frontend (Flutter)
1.  Open a **second** terminal.
2.  Navigate to the main project folder:
    ```powershell
    cd D:\SportLynk
    ```
3.  Run the app on Chrome:
    ```powershell
    flutter run -d chrome
    ```
4.  Wait for a Chrome window to open automatically.

## Step 2.5: Firebase Phone Auth Setup (required for real OTP)
OTP is mocked for demo by default. To enable real SMS OTP:
1. Install the Firebase and FlutterFire CLIs (one-time):
    ```powershell
    npm install -g firebase-tools
    dart pub global activate flutterfire_cli
    ```
2. Login to Firebase:
    ```powershell
    firebase login
    ```
3. Create a Firebase project named "SportLynk" in the console.
4. Add an Android app in Firebase:
    - Android package name: `com.example.sportlynk`
    - (Optional) Add SHA-1 if you plan to test on a physical device
5. Download `google-services.json` and place it in `android/app/`.
6. From the project root, run FlutterFire config:
    ```powershell
    flutterfire configure
    ```
    This generates `lib/firebase_options.dart` and updates Firebase config.
7. Enable **Phone** sign-in: Firebase Console → Authentication → Sign-in method → Phone → Enable.
8. Update OTP service mock flag to use real Firebase:
    - File: `lib/services/firebase_otp_service.dart`
    - Set `_useMock = false`
9. Rebuild the app:
    ```powershell
    flutter clean
    flutter pub get
    flutter run
    ```

## Step 3: Accessing the App
*   Once the Chrome window opens, you can use the app.
*   **Seeded Credentials (for testing):**
    *   **Player (email):** `bilal@test.pk` / `password123`
    *   **Owner (email):** `ahmed@sportlynk.pk` / `password123`
*   **Phone login:** Use a registered phone (03XXXXXXXXX). OTP is mocked unless Firebase is configured.

---

## 💡 Troubleshooting
*   **"Localhost link not working":** If you manually enter `localhost:PORT` in a new tab after closing the original browser, it might not work because Flutter stops the dev server when the window is closed. Always use `flutter run` to start a new session.
*   **Database Errors:** Ensure your PostgreSQL server is running on port 5432.
*   **API Connection Error:** If the app says "Connection refused", double-check that Terminal 1 (Backend) is still running and showing the "API running" message.
