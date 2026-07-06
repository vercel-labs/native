# Recon pass: build every showcase app for Windows, launch each onto the
# real desktop, and dump its automation snapshot, widget inventory, status
# fields, engine screenshot, and a desktop capture to
# %TEMP%\native-truth-out\<app>\. Run over ssh from the repo root:
#   powershell -NoProfile -File tools\windows-truth\recon.ps1 [app ...]
. "$PSScriptRoot\lib.ps1"

$apps = if ($args.Count -gt 0) { $args } else { $Apps }
New-Item -ItemType Directory -Force -Path $OutRoot | Out-Null

foreach ($app in $apps) {
    $out = "$OutRoot\$app"
    New-Item -ItemType Directory -Force -Path $out | Out-Null
    Write-Output "==== $app ===="
    Set-Location (AppDir $app)
    # -Doptimize=Debug keeps recon binaries at the debug shape (`native
    # build` alone would inject ReleaseFast).
    & $CLI build -Dplatform=windows -Dweb-engine=system -Dautomation=true -Doptimize=Debug *> "$out\build.log"
    if ($LASTEXITCODE -ne 0) {
        Write-Output "BUILD FAIL"
        Get-Content "$out\build.log" | Select-Object -Last 20
        Set-Content "$out\status.txt" "build=FAIL"
        continue
    }
    Set-Content "$out\status.txt" "build=OK"
    if (-not (Launch-App $app)) {
        Add-Content "$out\status.txt" "launch=FAIL"
        Copy-Item "$env:TEMP\native-app.log" "$out\app.log" -ErrorAction SilentlyContinue
        Stop-App $app
        continue
    }
    Add-Content "$out\status.txt" "launch=OK"
    Start-Sleep -Seconds 2
    Snapshot-Lines | Set-Content "$out\snapshot.txt"
    Get-Content "$out\snapshot.txt" | Select-String -Pattern 'widget @w1/[^#]*#\d+ role=[a-z]* name="[^"]*"' -AllMatches | ForEach-Object { $_.Matches.Value } | Set-Content "$out\widgets.txt"
    Get-Content "$out\snapshot.txt" | Select-String -Pattern 'view @w1/[^ ]* kind=[a-z_]*' -AllMatches | ForEach-Object { $_.Matches.Value } | Set-Content "$out\views.txt"
    foreach ($field in @("runtime_uptime_ns=\d+", "dispatch_errors=\d+", "gpu_backend=[a-z]*", "gpu_nonblank=[a-z]*")) {
        $match = Get-Content "$out\snapshot.txt" | Select-String -Pattern $field | Select-Object -First 1
        if ($match) { Add-Content "$out\status.txt" $match.Matches[0].Value }
    }
    $canvas = (Get-Content "$out\views.txt" | Select-String -Pattern 'view @w1/([^ ]*) kind=gpu_surface' | Select-Object -First 1)
    if ($canvas) {
        Shot $canvas.Matches[0].Groups[1].Value "$out\engine.png"
    }
    Desktop-Shot "$out\desktop.png"
    Copy-Item "$env:TEMP\native-app.log" "$out\app.log" -ErrorAction SilentlyContinue
    Stop-App $app
    Write-Output "done"
}
Write-Output "recon complete"
