# Effects truth on a real Windows desktop: build effects-probe, launch via
# the task hop, drive spawn streaming, cancel mid-stream, and a clipboard
# write verified by reading the console session's clipboard through a
# second task hop. The effects_wake count proves the PostMessage wake path.
. "$PSScriptRoot\lib.ps1"
$app = "effects-probe"; $c = "probe-canvas"
Set-Location "$RepoRoot\examples\$app"
& $CLI build -Dplatform=windows -Dweb-engine=system -Dautomation=true -Doptimize=Debug *> "$env:TEMP\effects-build.log"
if ($LASTEXITCODE -ne 0) { Write-Output "BUILD FAIL"; Get-Content "$env:TEMP\effects-build.log" | Select-Object -Last 10; exit 1 }
Write-Output "build ok"
if (Test-Path (DropboxDir)) { Remove-Item -Recurse -Force (DropboxDir) }
$bat = "$env:TEMP\native-launch.bat"
Set-Content -Path $bat -Value @(
    "@echo off",
    "cd /d $RepoRoot\examples\$app",
    "start `"`" /min cmd /c `"zig-out\bin\$app.exe > %TEMP%\native-app.log 2>&1`""
)
schtasks /Create /TN native-truth /TR $bat /SC ONCE /ST 00:00 /IT /F | Out-Null
schtasks /Run /TN native-truth | Out-Null
& $CLI automate assert --timeout-ms 30000 "ready=true" *> $null
Write-Output "ready exit=$LASTEXITCODE"
Expect 'gpu_nonblank=true' 15000
Click-Widget $c button "Start stream"
Expect 'streaming:' 30000
Expect 'stream line 2' 60000
Click-Widget $c button "Cancel"
Expect 'cancelled: code' 30000
Click-Widget $c button "Copy status"
Expect 'Copied' 10000
# Read the console-session clipboard from a scheduled hop.
$clipPs1 = "$env:TEMP\native-clip.ps1"
Set-Content $clipPs1 'Get-Clipboard | Set-Content "$env:TEMP\native-clip.txt"'
schtasks /Create /TN native-clip /TR "powershell -NoProfile -WindowStyle Hidden -File $clipPs1" /SC ONCE /ST 00:00 /IT /F | Out-Null
schtasks /Run /TN native-clip | Out-Null
Start-Sleep -Seconds 3
Write-Output "clipboard: $(Get-Content "$env:TEMP\native-clip.txt" -ErrorAction SilentlyContinue)"
$wake = (Get-Content "$env:TEMP\native-app.log" -ErrorAction SilentlyContinue | Select-String 'event="effects_wake"').Count
Write-Output "effects_wake events: $wake"
Finish $app "$env:TEMP\native-truth-out\effects-probe-dir"
