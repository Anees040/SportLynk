param (
    [string]$Password = ""
)

$HostName = "aws-1-ap-northeast-1.pooler.supabase.com"
$Port = 6543
$DbName = "postgres"
$User = "postgres.bfbyjltvnmhjrhsaekio"

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  SportLynk Local -> Supabase Sync Tool  " -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""

if ($Password -eq "") {
    $Password = Read-Host "Enter your Supabase Database Password (Input will be hidden)" -AsSecureString
    $Password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password))
}

Write-Host "`n[1/3] Dumping local database 'sportlynk'..." -ForegroundColor Yellow
# Local password from .env
$env:PGPASSWORD = "sportlynk123"
pg_dump -U postgres -d sportlynk -f sportlynk_export.sql --no-owner --no-privileges --clean --if-exists

if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Failed to dump local database. Is your local PostgreSQL running?" -ForegroundColor Red
    $env:PGPASSWORD = $null
    exit 1
}
$env:PGPASSWORD = $null
Write-Host "✅ Local database dumped successfully to sportlynk_export.sql." -ForegroundColor Green

Write-Host "`n[2/3] Uploading database to Supabase Cloud (Tokyo)..." -ForegroundColor Yellow
$env:PGPASSWORD = $Password
psql -h $HostName -p $Port -d $DbName -U $User -f sportlynk_export.sql

if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Failed to import to Supabase. Check your connection/password." -ForegroundColor Red
    $env:PGPASSWORD = $null
    exit 1
}
$env:PGPASSWORD = $null
Write-Host "✅ Supabase cloud database synchronized successfully." -ForegroundColor Green

Write-Host "`n[3/3] Cleaning up..." -ForegroundColor Yellow
Remove-Item -Path "sportlynk_export.sql" -ErrorAction SilentlyContinue
Write-Host "✅ Cleanup complete." -ForegroundColor Green

Write-Host "`n=========================================" -ForegroundColor Cyan
Write-Host "  Sync Completed Successfully!           " -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
