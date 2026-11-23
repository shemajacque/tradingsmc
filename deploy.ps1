# Deploy the SMC bot sources into the MT5 data folder and optionally compile.
#
#   .\deploy.ps1                 # copy only
#   .\deploy.ps1 -Compile        # copy + compile every .mq5 (log in data\)
#   .\deploy.ps1 -Compile -TerminalData "C:\path\to\Terminal\HASH"
#
# The default terminal is the MetaTrader 5 installation on this machine.
param(
    [string]$TerminalData = "C:\Users\Student\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075",
    [string]$MetaEditor = "C:\Program Files\MetaTrader 5\metaeditor64.exe",
    [switch]$Compile
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$mql  = Join-Path $TerminalData "MQL5"
if (-not (Test-Path -LiteralPath $mql)) {
    throw "MQL5 folder not found: $mql"
}

Write-Host "Deploying to $mql"

foreach ($dir in @("Include\SMC", "Scripts", "Experts", "Experts\SMC_Bot", "Files")) {
    $dst = Join-Path $mql $dir
    if (-not (Test-Path -LiteralPath $dst)) {
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
    }
}

Copy-Item -Path (Join-Path $root "MQL5\Include\SMC\*.mqh") -Destination (Join-Path $mql "Include\SMC") -Force
if (Test-Path (Join-Path $root "MQL5\Scripts\*.mq5")) {
    Copy-Item -Path (Join-Path $root "MQL5\Scripts\*.mq5") -Destination (Join-Path $mql "Scripts") -Force
}
if (Test-Path (Join-Path $root "MQL5\Experts\*.mq5")) {
    Copy-Item -Path (Join-Path $root "MQL5\Experts\*.mq5") -Destination (Join-Path $mql "Experts") -Force
}
if (Test-Path (Join-Path $root "MQL5\Experts\SMC_Bot\*.mq5")) {
    Copy-Item -Path (Join-Path $root "MQL5\Experts\SMC_Bot\*.mq5") -Destination (Join-Path $mql "Experts\SMC_Bot") -Force
}
if (Test-Path (Join-Path $root "news.csv")) {
    Copy-Item -Path (Join-Path $root "news.csv") -Destination (Join-Path $mql "Files") -Force
}

Write-Host "Copy done."

if ($Compile) {
    $logDir = Join-Path $root "data"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
    $files = @(Get-ChildItem (Join-Path $mql "Scripts") -Filter *.mq5 -ErrorAction SilentlyContinue) +
             @(Get-ChildItem (Join-Path $mql "Experts") -Filter *.mq5 -ErrorAction SilentlyContinue) +
             @(Get-ChildItem (Join-Path $mql "Experts\SMC_Bot") -Filter *.mq5 -ErrorAction SilentlyContinue)
    $failed = 0
    foreach ($f in $files) {
        $log = Join-Path $logDir ("compile_" + $f.BaseName + ".log")
        if (Test-Path $log) { Remove-Item $log -Force }
        & $MetaEditor /compile:"$($f.FullName)" /log:"$log" | Out-Null
        Start-Sleep -Milliseconds 1500
        if (-not (Test-Path $log)) {
            Write-Host "  $($f.Name): no log produced" -ForegroundColor Yellow
            $failed++
            continue
        }
        $result = (Get-Content $log -Encoding Unicode | Select-String -Pattern "Result:" | Select-Object -Last 1).Line
        if (-not $result) { $result = "no Result line" }
        if ($result -match "0 errors") {
            Write-Host "  $($f.Name): $($result.Trim())" -ForegroundColor Green
        } else {
            Write-Host "  $($f.Name): $($result.Trim())" -ForegroundColor Red
            Get-Content $log -Encoding Unicode | Select-String -Pattern "error" | ForEach-Object { Write-Host "    $_" }
            $failed++
        }
    }
    if ($failed -gt 0) { exit 1 }
}
