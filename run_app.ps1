param(
  [int]$Port = 8010,
  [string]$AdminPassword = "",
  [switch]$BindAll
)
$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot

if (-not $AdminPassword) {
  $AdminPassword = $env:SMC_ADMIN_PASSWORD
}
if (-not $AdminPassword) {
  $bytes = New-Object byte[] 24
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  $AdminPassword = [Convert]::ToBase64String($bytes)
  Write-Host "Generated admin password: $AdminPassword" -ForegroundColor Yellow
  Write-Host "Set it yourself with `$env:SMC_ADMIN_PASSWORD to keep it." -ForegroundColor Yellow
}

$env:SMC_ADMIN_PASSWORD = $AdminPassword
$env:PORT = "$Port"
$bind = if ($BindAll) { "0.0.0.0" } else { "127.0.0.1" }
Write-Host "SMC Control Center: http://127.0.0.1:$Port" -ForegroundColor Cyan
Write-Host "Binding $bind. Use -BindAll only behind HTTPS; direct mode can trade this MT5 account." -ForegroundColor DarkGray
python -m uvicorn app.main:app --host $bind --port $Port
