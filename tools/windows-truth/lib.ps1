# Shared helpers for driving automation-enabled showcase apps on a real
# Windows 11 desktop. Dot-sourced by recon.ps1 and drive.ps1; runs ON the
# Windows box (invoked over ssh with: powershell -NoProfile -File <script>).
#
# Session split: an ssh session lands in an invisible service session, so
# apps are launched onto the logged-in console desktop through a scheduled
# task created with /IT (interactive). The automation transport is plain
# files (the dropbox below), so this driving script reads and writes it
# from the ssh session while the app renders on the real desktop.
#
# Transport: the app (built with -Dautomation=true) publishes
# .zig-cache/native-sdk-automation/snapshot.txt and consumes a bounded
# queue of command-<n>.txt entries, oldest first, DELETING each entry as
# its consumption ack. The CLI already waits for its own entry's deletion
# before exiting; Wait-Done below is the belt-and-braces check that the
# whole queue drained.

$script:RepoRoot = "$env:USERPROFILE\repo"
$script:CLI = "$RepoRoot\zig-out\bin\native.exe"
$script:OutRoot = "$env:TEMP\native-truth-out"
$script:Apps = @("calculator", "notes", "soundboard", "markdown-viewer", "system-monitor", "gpu-dashboard", "deck", "feed", "kanban", "ui-inbox")

function AppDir([string]$app) { "$RepoRoot\examples\$app" }
function DropboxDir { ".zig-cache\native-sdk-automation" }

# Launch <app> onto the console desktop via the scheduled-task hop and
# block until the automation snapshot reports ready.
function Launch-App([string]$app, [int]$timeoutMs = 30000) {
    # Stragglers from an earlier run keep publishing snapshots into their
    # own dropbox and steal desktop focus; clear the field first.
    foreach ($name in $Apps) {
        taskkill /IM "$name.exe" /F 2>$null | Out-Null
    }
    Set-Location (AppDir $app)
    if (Test-Path (DropboxDir)) { Remove-Item -Recurse -Force (DropboxDir) }
    $bat = "$env:TEMP\native-launch.bat"
    # cmd /c keeps the app's stderr in a log file we can collect later;
    # /min keeps that console out of the desktop captures (the app window
    # itself still activates in the foreground).
    Set-Content -Path $bat -Value @(
        "@echo off",
        "cd /d $(AppDir $app)",
        "start `"`" /min cmd /c `"zig-out\bin\$app.exe > %TEMP%\native-app.log 2>&1`""
    )
    schtasks /Create /TN native-truth /TR $bat /SC ONCE /ST 00:00 /IT /F | Out-Null
    schtasks /Run /TN native-truth | Out-Null
    & $CLI automate assert --timeout-ms $timeoutMs "ready=true" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Output "LAUNCH FAIL: snapshot never ready"
        Get-Content "$env:TEMP\native-app.log" -ErrorAction SilentlyContinue | Select-Object -Last 20
        return $false
    }
    return $true
}

function Stop-App([string]$app) {
    taskkill /IM "$app.exe" /F 2>$null | Out-Null
}

# Pacing: block until the app has consumed every queued command (the
# app deletes each command-<n>.txt entry as it consumes it, so an empty
# queue means everything dispatched).
function Wait-Done {
    $pattern = Join-Path (DropboxDir) "command-*.txt"
    for ($i = 0; $i -lt 200; $i++) {
        if (-not (Test-Path $pattern)) { return $true }
        Start-Sleep -Milliseconds 50
    }
    Write-Output "WARN: command queue not drained within 10s"
    return $false
}

# Send one automate subcommand and wait for consumption.
function Send-Cmd {
    & $CLI automate @args | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Output "WARN: send $($args -join ' ') failed"; return $false }
    Wait-Done | Out-Null
    return $true
}

function Snapshot-Lines {
    (Get-Content (Join-Path (DropboxDir) "snapshot.txt") -Raw -ErrorAction SilentlyContinue) -split '\|'
}

# Resolve a widget id from the snapshot. Retries briefly: the app
# rewrites snapshot.txt on every published frame, so a single read can
# catch a partially written file.
function Widget-Id([string]$canvas, [string]$role, [string]$name) {
    for ($i = 0; $i -lt 20; $i++) {
        $match = Snapshot-Lines | Select-String -Pattern ('widget @w1/' + [regex]::Escape($canvas) + '#(\d+) role=' + [regex]::Escape($role) + ' name="' + [regex]::Escape($name) + '"') | Select-Object -First 1
        if ($match) { return $match.Matches[0].Groups[1].Value }
        Start-Sleep -Milliseconds 100
    }
    return $null
}

function Click-Widget([string]$canvas, [string]$role, [string]$name) {
    $id = Widget-Id $canvas $role $name
    if (-not $id) { Write-Output "WARN: widget $role `"$name`" not found on $canvas"; return }
    Send-Cmd widget-click $canvas $id | Out-Null
}

function Set-WidgetText([string]$canvas, [string]$role, [string]$name, [string]$text) {
    $id = Widget-Id $canvas $role $name
    if (-not $id) { Write-Output "WARN: widget $role `"$name`" not found for set-text"; return }
    Send-Cmd widget-action $canvas $id set-text $text | Out-Null
}

function Wheel-Widget([string]$canvas, [string]$role, [string]$name, [string]$deltaY) {
    $id = Widget-Id $canvas $role $name
    if (-not $id) { Write-Output "WARN: widget $role `"$name`" not found for wheel"; return }
    Send-Cmd widget-wheel $canvas $id $deltaY | Out-Null
}

# Assert the snapshot reaches a state. Embedded double quotes must be
# backslash-escaped for the native-command argument pass-through
# (PowerShell 5.1 drops them from the child's command line otherwise).
function Expect([string]$pattern, [int]$timeoutMs = 10000) {
    $escaped = $pattern -replace '"', '\"'
    & $CLI automate assert --timeout-ms $timeoutMs $escaped *> $null
    if ($LASTEXITCODE -eq 0) { Write-Output "ok: $pattern" } else { Write-Output "MISS: $pattern" }
}

# Engine screenshot (platform-honest pixels) of a canvas into $out.
function Shot([string]$canvas, [string]$out) {
    Send-Cmd screenshot $canvas | Out-Null
    $png = Join-Path (DropboxDir) "screenshot-$canvas.png"
    for ($i = 0; $i -lt 100; $i++) {
        if ((Test-Path $png) -and ((Get-Item $png).Length -gt 0)) { break }
        Start-Sleep -Milliseconds 50
    }
    if (Test-Path $png) { Copy-Item $png $out } else { Write-Output "WARN: engine screenshot $canvas missing" }
}

# Desktop capture (window chrome included). The capture must run in the
# console session to see the desktop, so it hops through a second
# scheduled task.
function Desktop-Shot([string]$out) {
    $ps1 = "$env:TEMP\native-desktop-shot.ps1"
    Set-Content -Path $ps1 -Value @'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$b = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
$g.Dispose()
$bmp.Save("$env:TEMP\desktop.png", [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
'@
    Remove-Item "$env:TEMP\desktop.png" -ErrorAction SilentlyContinue
    # -WindowStyle Hidden keeps the capture's own console out of the shot.
    schtasks /Create /TN native-shot /TR "powershell -NoProfile -WindowStyle Hidden -File $ps1" /SC ONCE /ST 00:00 /IT /F | Out-Null
    schtasks /Run /TN native-shot | Out-Null
    for ($i = 0; $i -lt 100; $i++) {
        if (Test-Path "$env:TEMP\desktop.png") { break }
        Start-Sleep -Milliseconds 100
    }
    if (Test-Path "$env:TEMP\desktop.png") { Copy-Item "$env:TEMP\desktop.png" $out } else { Write-Output "WARN: desktop capture failed" }
}

function Window-Bounds {
    $match = Snapshot-Lines | Select-String -Pattern 'window @w1 "[^"]*" bounds=\(([^)]*)\)' | Select-Object -First 1
    if ($match) { return $match.Matches[0].Groups[1].Value }
    return ""
}

# Final snapshot + log sweep for one app's drive.
function Finish([string]$app, [string]$out) {
    Start-Sleep -Milliseconds 500
    Snapshot-Lines | Set-Content "$out\final-snapshot.txt"
    $errors = (Get-Content "$out\final-snapshot.txt" | Select-String -Pattern 'dispatch_errors=\d+' | Select-Object -First 1)
    Write-Output "final: $(if ($errors) { $errors.Matches[0].Value } else { 'dispatch_errors not found' })"
    $log = "$env:TEMP\native-app.log"
    $flagged = @(Get-Content $log -ErrorAction SilentlyContinue | Select-String -Pattern "error|critical|warning|assert")
    Write-Output "app log flagged lines: $($flagged.Count)"
    $flagged | Select-Object -First 10 | Set-Content "$out\log-flags.txt"
    Copy-Item $log "$out\app.log" -ErrorAction SilentlyContinue
    Stop-App $app
}
