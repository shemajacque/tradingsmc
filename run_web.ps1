# Start the SMC Bot Manager web dashboard (local only by default).
param(
    [int]$Port = 8020,
    [string]$Password = "smc-admin",
    [string]$BindHost = "127.0.0.1"
)

$env:SMC_WEB_PASSWORD = $Password
$root = $PSScriptRoot
Set-Location -LiteralPath $root

Write-Host "SMC Bot Manager -> http://$BindHost`:$Port"
Write-Host "Password: $Password"
Write-Host "Press Ctrl+C to stop."
python -m uvicorn web.app:app --host $BindHost --port $Port
