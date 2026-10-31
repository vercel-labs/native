# Release-mode real-desktop performance gate for the Windows retained-canvas
# input path. Builds gpu-dashboard, launches it through the interactive task
# hop, then measures actual cursor hover and sustained Win32 wheel delivery.
# Artifacts land in %TEMP%\native-truth-out\perf-input\.
param(
    [int]$HoverSamples = 10,
    [int]$WheelEvents = 120,
    [int]$WheelIntervalMs = 16,
    [int]$MinDeliveredWheelEvents = 80,
    [int]$MaxWheelFrameDeficit = 2,
    [int]$MinAnimationFrames = 45,
    [double]$MaxAnimationIntervalP90Ms = 20,
    [double]$MaxAnimationIntervalMs = 34,
    [double]$MaxHoverP90Ms = 80,
    [double]$MaxBuiltinHoverP90Ms = 20,
    [double]$MaxTelemetryDeltaP90Ms = 60,
    [double]$MaxWheelIntervalP90Ms = 25,
    [double]$MaxWheelIntervalMs = 50
)

. "$PSScriptRoot\lib.ps1"

$PerfOut = "$OutRoot\perf-input"
$ResultPath = "$PerfOut\result.json"
$SnapshotPath = "$(AppDir 'gpu-dashboard')\.zig-cache\native-sdk-automation\snapshot.txt"
New-Item -ItemType Directory -Force -Path $PerfOut | Out-Null
Remove-Item $ResultPath -ErrorAction SilentlyContinue

function Snapshot-Widget([string]$role, [string]$name) {
    $pattern = 'widget @w1/dashboard-canvas#(\d+) role=' + [regex]::Escape($role) +
        ' name="' + [regex]::Escape($name) + '" bounds=\(([-0-9.]+),([-0-9.]+) ([-0-9.]+)x([-0-9.]+)\)'
    $match = Snapshot-Lines | Select-String -Pattern $pattern | Select-Object -First 1
    if (-not $match) { return $null }
    return [pscustomobject]@{
        Id = $match.Matches[0].Groups[1].Value
        X = [double]$match.Matches[0].Groups[2].Value
        Y = [double]$match.Matches[0].Groups[3].Value
        Width = [double]$match.Matches[0].Groups[4].Value
        Height = [double]$match.Matches[0].Groups[5].Value
    }
}

function Percentile([double[]]$values, [double]$fraction) {
    if ($values.Count -eq 0) { return [double]::PositiveInfinity }
    $sorted = @($values | Sort-Object)
    $index = [Math]::Max(0, [Math]::Ceiling($sorted.Count * $fraction) - 1)
    return [double]$sorted[$index]
}

$app = "gpu-dashboard"
$failed = $false
try {
    Set-Location (AppDir $app)
    Write-Output "building release gpu-dashboard..."
    & $CLI build -Dplatform=windows -Dweb-engine=system -Dautomation=true -Doptimize=ReleaseFast *> "$PerfOut\build.log"
    if ($LASTEXITCODE -ne 0) {
        Get-Content "$PerfOut\build.log" | Select-Object -Last 30
        throw "gpu-dashboard build failed"
    }
    if (-not (Launch-App $app 30000)) { throw "gpu-dashboard launch failed" }
    & $CLI automate assert --timeout-ms 15000 "gpu_nonblank=true" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "gpu-dashboard never presented a nonblank frame" }

    $view = Snapshot-Lines | Select-String -Pattern 'view @w1/dashboard-canvas kind=gpu_surface.*bounds=\(([-0-9.]+),([-0-9.]+) ([-0-9.]+)x([-0-9.]+)\)' | Select-Object -First 1
    if (-not $view) { throw "dashboard canvas bounds missing" }
    $surfaceWidth = [double]$view.Matches[0].Groups[3].Value
    $surfaceHeight = [double]$view.Matches[0].Groups[4].Value
    # Measure controls whose hover state changes pixels. The switch and
    # slider expose semantic `hovered` state but intentionally have no hover
    # chrome, so they produce no responding present and therefore no honest
    # glass-latency sample to correlate.
    $hoverA = Snapshot-Widget "button" "Refresh dashboard"
    $hoverB = Snapshot-Widget "button" "Live render status"
    $wheel = Snapshot-Widget "group" "Recent activity"
    if (-not ($hoverA -and $hoverB -and $wheel)) { throw "performance probe widgets missing" }

    $bat = "$env:TEMP\native-perf-input.bat"
    $desktopLog = "$PerfOut\desktop.log"
    $desktopScript = "$PSScriptRoot\perf-input-desktop.ps1"
    $desktopCommand = "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$desktopScript`""
    $desktopCommand += " -WorkingDirectory `"$(AppDir $app)`""
    $desktopCommand += " -CliPath `"$CLI`""
    $desktopCommand += " -SnapshotPath `"$SnapshotPath`""
    $desktopCommand += " -OutputPath `"$ResultPath`""
    $desktopCommand += " -HoverAId `"$($hoverA.Id)`" -HoverBId `"$($hoverB.Id)`""
    $desktopCommand += " -HoverAX $($hoverA.X + $hoverA.Width / 2) -HoverAY $($hoverA.Y + $hoverA.Height / 2)"
    $desktopCommand += " -HoverBX $($hoverB.X + $hoverB.Width / 2) -HoverBY $($hoverB.Y + $hoverB.Height / 2)"
    $desktopCommand += " -WheelX $($wheel.X + $wheel.Width / 2) -WheelY $($wheel.Y + $wheel.Height / 2)"
    $desktopCommand += " -SurfaceWidth $surfaceWidth -SurfaceHeight $surfaceHeight"
    $desktopCommand += " -HoverSamples $HoverSamples -WheelEvents $WheelEvents -WheelIntervalMs $WheelIntervalMs"
    $desktopCommand += " > `"$desktopLog`" 2>&1"
    Set-Content -Path $bat -Value @("@echo off", $desktopCommand)
    schtasks /Create /TN native-perf-input /TR $bat /SC ONCE /ST 00:00 /IT /F | Out-Null
    schtasks /Run /TN native-perf-input | Out-Null
    for ($attempt = 0; $attempt -lt 900; $attempt++) {
        if (Test-Path $ResultPath) { break }
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path $ResultPath)) { throw "interactive input probe timed out" }
    $result = Get-Content $ResultPath -Raw | ConvertFrom-Json
    if ($result.Error) { throw "interactive input probe failed: $($result.Error)" }

    $hover = @($result.Hover)
    $timeouts = @($hover | Where-Object { $_.TimedOut }).Count
    $external = [double[]]@($hover | ForEach-Object { [double]$_.ExternalMs })
    $builtin = [double[]]@($hover | ForEach-Object { [double]$_.BuiltinMs })
    $deltas = [double[]]@($hover | ForEach-Object { [Math]::Abs([double]$_.ExternalMs - [double]$_.BuiltinMs) })
    $externalP90 = Percentile $external 0.9
    $builtinP90 = Percentile $builtin 0.9
    $deltaP90 = Percentile $deltas 0.9
    Write-Output ("hover: samples={0} timeouts={1} external_p90_ms={2:N3} builtin_p90_ms={3:N3} telemetry_delta_p90_ms={4:N3}" -f $hover.Count, $timeouts, $externalP90, $builtinP90, $deltaP90)

    $animationResult = $result.Animation
    $displayRefreshHz = [int]$result.DisplayRefreshHz
    if ($displayRefreshHz -le 1) { $displayRefreshHz = 60 }
    $displayIntervalMs = 1000.0 / $displayRefreshHz
    # The RDP console can expose a real 32 Hz Microsoft Remote Display
    # Adapter even when the physical GPU is 60 Hz. Judge animation against
    # the HWND's active display cadence: require most available refreshes,
    # a p90 within one refresh plus scheduling slack, and no gap longer than
    # two refreshes. A 30 fps app on a 60 Hz display still fails all three.
    $effectiveMinAnimationFrames = [int][Math]::Min(
        $MinAnimationFrames, [Math]::Floor($displayRefreshHz * 0.9))
    $effectiveAnimationP90Ms = [Math]::Max(
        $MaxAnimationIntervalP90Ms, $displayIntervalMs + 3.0)
    $effectiveAnimationMaxMs = [Math]::Max(
        $MaxAnimationIntervalMs, 2.0 * $displayIntervalMs + 3.0)
    $profiledAnimationFrames = [int]$animationResult.IntervalSamples + 1
    Write-Output ("display: refresh_hz={0} frame_interval_ms={1:N3} animation_budgets=frames>={2},p90<={3:N3}ms,max<={4:N3}ms" -f
        $displayRefreshHz, $displayIntervalMs, $effectiveMinAnimationFrames,
        $effectiveAnimationP90Ms, $effectiveAnimationMaxMs)
    Write-Output ("animation: profiled_frames={0} frame_index_delta={1} interval_p50_ms={2:N3} interval_p90_ms={3:N3} interval_max_ms={4:N3} samples={5}" -f
        $profiledAnimationFrames, $animationResult.Frames, $animationResult.IntervalP50Ms,
        $animationResult.IntervalP90Ms, $animationResult.IntervalMaxMs,
        $animationResult.IntervalSamples)

    $wheelResult = $result.Wheel
    Write-Output ("wheel: attempted={0} delivered={1} elapsed_ms={2:N3} frames={3} interval_p50_ms={4:N3} interval_p90_ms={5:N3} interval_max_ms={6:N3} samples={7}" -f
        $wheelResult.Events, $wheelResult.DeliveredInputs, $wheelResult.ElapsedMs, $wheelResult.Frames,
        $wheelResult.IntervalP50Ms, $wheelResult.IntervalP90Ms,
        $wheelResult.IntervalMaxMs, $wheelResult.IntervalSamples)

    if ($timeouts -ne 0) { Write-Output "FAIL: hover samples timed out"; $failed = $true }
    if ($externalP90 -gt $MaxHoverP90Ms) { Write-Output "FAIL: hover external p90 exceeded $MaxHoverP90Ms ms"; $failed = $true }
    if ($builtinP90 -gt $MaxBuiltinHoverP90Ms) { Write-Output "FAIL: hover built-in p90 exceeded $MaxBuiltinHoverP90Ms ms"; $failed = $true }
    if ($deltaP90 -gt $MaxTelemetryDeltaP90Ms) { Write-Output "FAIL: built-in/external hover telemetry diverged by more than $MaxTelemetryDeltaP90Ms ms p90"; $failed = $true }
    if ($profiledAnimationFrames -lt $effectiveMinAnimationFrames) { Write-Output "FAIL: retained animation produced fewer than $effectiveMinAnimationFrames display-adjusted profiled frames"; $failed = $true }
    if ([double]$animationResult.IntervalP90Ms -gt $effectiveAnimationP90Ms) { Write-Output "FAIL: animation interval p90 exceeded the display-adjusted $effectiveAnimationP90Ms ms budget"; $failed = $true }
    if ([double]$animationResult.IntervalMaxMs -gt $effectiveAnimationMaxMs) { Write-Output "FAIL: animation interval max exceeded the display-adjusted $effectiveAnimationMaxMs ms budget"; $failed = $true }
    if ([int]$wheelResult.DeliveredInputs -lt $MinDeliveredWheelEvents) { Write-Output "FAIL: Windows delivered fewer than $MinDeliveredWheelEvents wheel events"; $failed = $true }
    $frameDeficit = [int]$wheelResult.DeliveredInputs - [int]$wheelResult.Frames
    if ($frameDeficit -gt $MaxWheelFrameDeficit) { Write-Output "FAIL: sustained wheel lost $frameDeficit responding frames (budget $MaxWheelFrameDeficit)"; $failed = $true }
    if ([double]$wheelResult.IntervalP90Ms -gt $MaxWheelIntervalP90Ms) { Write-Output "FAIL: wheel interval p90 exceeded $MaxWheelIntervalP90Ms ms"; $failed = $true }
    if ([double]$wheelResult.IntervalMaxMs -gt $MaxWheelIntervalMs) { Write-Output "FAIL: wheel interval max exceeded $MaxWheelIntervalMs ms"; $failed = $true }

    Snapshot-Lines | Set-Content "$PerfOut\final-snapshot.txt"
    Copy-Item "$env:TEMP\native-app.log" "$PerfOut\app.log" -ErrorAction SilentlyContinue
} catch {
    Write-Output "FAIL: $($_.Exception.Message)"
    $failed = $true
} finally {
    Stop-App $app
    schtasks /Delete /TN native-perf-input /F 2>$null | Out-Null
}

if ($failed) { exit 1 }
Write-Output "windows input performance gate passed"
