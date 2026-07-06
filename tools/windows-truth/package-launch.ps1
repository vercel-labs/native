# Packaging truth: launch the `native package --target windows` calculator
# artifact onto the real desktop from its package bin directory and drive
# one click through the automation dropbox. Run `native package --target
# windows` in examples\calculator first.
. "$PSScriptRoot\lib.ps1"
$pkg = "C:\Users\rdp\repo\examples\calculator\zig-out\package\calculator-windows\bin"
taskkill /IM calculator.exe /F 2>$null | Out-Null
Set-Location $pkg
if (Test-Path (DropboxDir)) { Remove-Item -Recurse -Force (DropboxDir) }
$bat = "$env:TEMP\native-launch.bat"
Set-Content -Path $bat -Value @(
    "@echo off",
    "cd /d $pkg",
    "start `"`" /min cmd /c `"calculator.exe > %TEMP%\native-app.log 2>&1`""
)
schtasks /Create /TN native-truth /TR $bat /SC ONCE /ST 00:00 /IT /F | Out-Null
schtasks /Run /TN native-truth | Out-Null
& $CLI automate assert --timeout-ms 30000 "ready=true" *> $null
Write-Output "packaged app ready exit=$LASTEXITCODE"
Click-Widget "calc-canvas" button "7"
Expect 'name="7"'
Desktop-Shot "$env:TEMP\native-truth-out\packaged-calculator-desktop.png"
Stop-App "calculator"
