# Session record/replay truth: record a driven calculator session on the
# real desktop (the recorder CLI wraps the app and seals the journal on a
# clean exit — WM_CLOSE posted from the console session), then replay the
# journal headlessly with verification.
. "$PSScriptRoot\lib.ps1"
$app = "calculator"; $c = "calc-canvas"
Set-Location (AppDir $app)
taskkill /IM calculator.exe /F 2>$null | Out-Null
if (Test-Path (DropboxDir)) { Remove-Item -Recurse -Force (DropboxDir) }
Remove-Item "$env:TEMP\calc-session.journal" -ErrorAction SilentlyContinue
# Record on the real desktop via the scheduled-task hop; the recorder CLI
# wraps the app and seals the journal on clean exit.
$bat = "$env:TEMP\native-launch.bat"
Set-Content -Path $bat -Value @(
    "@echo off",
    "cd /d $(AppDir $app)",
    "start `"`" /min cmd /c `"$CLI automate record --out %TEMP%\calc-session.journal -- zig-out\bin\calculator.exe > %TEMP%\native-app.log 2>&1`""
)
schtasks /Create /TN native-truth /TR $bat /SC ONCE /ST 00:00 /IT /F | Out-Null
schtasks /Run /TN native-truth | Out-Null
& $CLI automate assert --timeout-ms 30000 "ready=true" *> $null
Write-Output "record ready exit=$LASTEXITCODE"
Click-Widget $c button "All clear"; Click-Widget $c button "7"; Click-Widget $c button "Multiply"
Click-Widget $c button "8"; Click-Widget $c button "Equals"
Expect 'name="56"'
Start-Sleep -Seconds 1
# Close gracefully from the console session so the journal seals.
schtasks /Create /TN native-close /TR "powershell -NoProfile -WindowStyle Hidden -File $PSScriptRoot\close-window.ps1 -Title Calculator" /SC ONCE /ST 00:00 /IT /F | Out-Null
schtasks /Run /TN native-close | Out-Null
for ($i = 0; $i -lt 60; $i++) {
    if (-not (Get-Process calculator -ErrorAction SilentlyContinue)) { break }
    Start-Sleep -Milliseconds 500
}
Write-Output "app closed: $(-not (Get-Process calculator -ErrorAction SilentlyContinue))"
Write-Output "journal size: $((Get-Item "$env:TEMP\calc-session.journal" -ErrorAction SilentlyContinue).Length)"
# Replay headlessly (ssh session) with verification.
& $CLI automate replay "$env:TEMP\calc-session.journal" --verify -- zig-out\bin\calculator.exe > "$env:TEMP\replay-out.log" 2> "$env:TEMP\replay-err.log"
Write-Output "replay exit=$LASTEXITCODE"
Get-Content "$env:TEMP\replay-err.log" -ErrorAction SilentlyContinue | Select-String -Pattern "replay|verify|checkpoint" | Select-Object -Last 5
