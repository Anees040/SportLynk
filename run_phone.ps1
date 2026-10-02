# ============================================================
# SportLynk — Run on Phone (one command does everything)
# ============================================================
# Usage:  Open PowerShell in D:\sportlynk, then run:
#         .\run_phone.ps1
#
# This script:
#   1. Sets up the ADB port bridge (so phone can reach localhost)
#   2. Launches the Flutter app on your connected phone
# ============================================================

$ADB = "C:\Users\Anees\AppData\Local\Android\Sdk\platform-tools\adb.exe"

Write-Host ""
Write-Host "=== SportLynk Phone Runner ===" -ForegroundColor Cyan
Write-Host ""

# Step 1: ADB port bridge
Write-Host "[1/2] Setting up ADB port bridge..." -ForegroundColor Yellow
& $ADB reverse tcp:3000 tcp:3000 | Out-Null
& $ADB reverse tcp:5000 tcp:5000 | Out-Null
Write-Host "  OK  Port 3000 (backend) + 5000 (ML) bridged to phone" -ForegroundColor Green

# Step 2: Launch Flutter
Write-Host "[2/2] Launching app on phone..." -ForegroundColor Yellow
Write-Host ""
flutter run -d 0683225191101020 --dart-define=API_BASE_URL=http://localhost:3000/api
