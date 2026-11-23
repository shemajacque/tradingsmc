param(
  [int]$Port = 8010,
  [string]$TunnelUrl = ""
)
$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot

$exe = Join-Path $PSScriptRoot "cloudflared.exe"
if (-not (Test-Path -LiteralPath $exe)) {
  $source = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"
  Invoke-WebRequest -Uri $source -OutFile $exe
  Write-Host "Downloaded cloudflared.exe" -ForegroundColor Cyan
}

$target = "http://127.0.0.1:$Port"
if ($TunnelUrl) {
  Write-Host "Tunnel target: $target" -ForegroundColor Cyan
  & $exe tunnel --no-autoupdate --url $TunnelUrl $target
} else {
  Write-Host "Starting quick tunnel to $target" -ForegroundColor Cyan
  Write-Host "The https://*.trycloudflare.com URL changes each time this script restarts." -ForegroundColor Yellow
  & $exe tunnel --no-autoupdate --url $target
}
