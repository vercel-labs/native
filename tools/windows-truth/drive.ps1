# Interaction drive pass: launch each showcase app on the real Windows
# desktop and run a representative scenario (clicks, text input, wheel
# scrolling, synthetic resize), screenshotting at defined points. Results
# land in %TEMP%\native-truth-out\drive\<app>\: drive.log (ok:/MISS:/WARN:
# lines), engine *.png screenshots, final snapshot, and the app's log.
# Run recon.ps1 first (it builds the apps); this script only launches.
#   powershell -NoProfile -File tools\windows-truth\drive.ps1 [app ...]
. "$PSScriptRoot\lib.ps1"

$DriveOut = "$OutRoot\drive"
New-Item -ItemType Directory -Force -Path $DriveOut | Out-Null

function Check-MinSize {
    Send-Cmd resize 50 50 | Out-Null
    Start-Sleep -Seconds 1
    Write-Output "bounds after resize 50x50 request: $(Window-Bounds)"
}

function Drive-Calculator {
    $out = "$DriveOut\calculator"; $c = "calc-canvas"
    if (-not (Launch-App "calculator")) { return }
    Click-Widget $c button "All clear"; Click-Widget $c button "7"; Click-Widget $c button "Multiply"
    Click-Widget $c button "8"; Click-Widget $c button "Equals"
    Expect 'name="56"'
    Shot $c "$out\1-compute.png"
    $id = Widget-Id $c textbox "Expression"
    Send-Cmd widget-action $c $id focus | Out-Null
    Send-Cmd widget-key $c 1 1 | Out-Null; Send-Cmd widget-key $c 2 2 | Out-Null
    Send-Cmd widget-key $c plus + | Out-Null
    Send-Cmd widget-key $c 3 3 | Out-Null; Send-Cmd widget-key $c equal = | Out-Null
    Expect 'name="15"' 5000
    Shot $c "$out\2-keyboard.png"
    Write-Output "bounds before resize: $(Window-Bounds)"
    Send-Cmd resize 420 640 | Out-Null; Start-Sleep -Seconds 1
    Write-Output "bounds after resize 420x640: $(Window-Bounds)"
    Check-MinSize
    Shot $c "$out\3-resized.png"
    Desktop-Shot "$out\4-desktop.png"
    Finish "calculator" $out
}

function Drive-Notes {
    $out = "$DriveOut\notes"; $c = "notes-canvas"
    if (-not (Launch-App "notes")) { return }
    Shot $c "$out\1-initial.png"
    # Notes persists its store across launches (app-dirs state), so assert
    # the count DELTA rather than an absolute count.
    $before = (Snapshot-Lines | Select-String -Pattern '(\d+) notes' | Select-Object -First 1)
    $count = if ($before) { [int]$before.Matches[0].Groups[1].Value } else { 0 }
    Click-Widget $c button "New note"
    Expect "$($count + 1) notes" 5000
    $id = Widget-Id $c textbox "Note editor"
    Send-Cmd widget-action $c $id focus | Out-Null
    Set-WidgetText $c textbox "Note editor" "Windows-live-truth"
    Expect 'Windows-live-truth' 5000
    Shot $c "$out\2-typed.png"
    Set-WidgetText $c textbox "Search notes" "Piranesi"
    Expect '1 shown' 5000
    Shot $c "$out\3-search.png"
    Set-WidgetText $c textbox "Search notes" ""
    Wheel-Widget $c button "New folder" 40
    Send-Cmd resize 900 600 | Out-Null; Start-Sleep -Seconds 1
    Write-Output "bounds after resize 900x600: $(Window-Bounds)"
    Check-MinSize
    Shot $c "$out\4-resized.png"
    Finish "notes" $out
}

function Drive-Soundboard {
    $out = "$DriveOut\soundboard"; $c = "soundboard-canvas"
    if (-not (Launch-App "soundboard")) { return }
    Shot $c "$out\1-initial.png"
    Click-Widget $c tab "Songs"
    $selected = "no"
    for ($i = 0; $i -lt 50; $i++) {
        $line = Snapshot-Lines | Select-String -Pattern 'role=tab name="Songs"[^|]*state=\[[a-z,]*selected' | Select-Object -First 1
        if ($line) { $selected = "yes"; break }
        Start-Sleep -Milliseconds 100
    }
    if ($selected -eq "yes") { Write-Output "ok: Songs tab selected" } else { Write-Output "MISS: Songs tab not selected" }
    Shot $c "$out\2-songs.png"
    Click-Widget $c button "Play or pause"
    Start-Sleep -Seconds 1
    Shot $c "$out\3-playing.png"
    Set-WidgetText $c textbox "Search library" "glass"
    Start-Sleep -Seconds 1
    Shot $c "$out\4-search.png"
    Wheel-Widget $c tab "Albums" -40
    Send-Cmd resize 1200 800 | Out-Null; Start-Sleep -Seconds 1
    Write-Output "bounds after resize 1200x800: $(Window-Bounds)"
    Check-MinSize
    Finish "soundboard" $out
}

function Drive-MarkdownViewer {
    $out = "$DriveOut\markdown-viewer"; $c = "viewer-canvas"
    if (-not (Launch-App "markdown-viewer")) { return }
    Shot $c "$out\1-initial.png"
    $id = Widget-Id $c textbox "Markdown source"
    Send-Cmd widget-action $c $id focus | Out-Null
    Send-Cmd widget-key $c end | Out-Null
    Send-Cmd widget-key $c z | Out-Null
    Start-Sleep -Seconds 1
    Shot $c "$out\2-typed.png"
    Wheel-Widget $c link "https://github.com" 60
    Start-Sleep -Seconds 1
    Shot $c "$out\3-scrolled.png"
    Send-Cmd resize 1400 800 | Out-Null; Start-Sleep -Seconds 1
    Write-Output "bounds after resize 1400x800: $(Window-Bounds)"
    Check-MinSize
    Finish "markdown-viewer" $out
}

function Drive-SystemMonitor {
    $out = "$DriveOut\system-monitor"; $c = "monitor-canvas"
    if (-not (Launch-App "system-monitor")) { return }
    Start-Sleep -Seconds 3
    Shot $c "$out\1-initial.png"
    Click-Widget $c button "Sort by Memory"
    Start-Sleep -Seconds 1
    Shot $c "$out\2-sort-memory.png"
    Set-WidgetText $c textbox "Filter processes" "zig"
    Start-Sleep -Seconds 1
    Shot $c "$out\3-filter.png"
    Click-Widget $c button "Pause or resume sampling"
    Start-Sleep -Seconds 1
    # Settings opens a second window; the snapshot should grow a @w2.
    Click-Widget $c button "Open settings window"
    Start-Sleep -Seconds 2
    $w2 = Snapshot-Lines | Select-String -Pattern 'window @w2' | Select-Object -First 1
    if ($w2) { Write-Output "ok: settings window @w2 appeared" } else { Write-Output "MISS: settings window @w2" }
    Desktop-Shot "$out\4-two-windows-desktop.png"
    Send-Cmd resize 1300 800 | Out-Null; Start-Sleep -Seconds 1
    Write-Output "bounds after resize 1300x800: $(Window-Bounds)"
    Check-MinSize
    Finish "system-monitor" $out
}

function Drive-GpuDashboard {
    $out = "$DriveOut\gpu-dashboard"; $c = "dashboard-canvas"
    if (-not (Launch-App "gpu-dashboard")) { return }
    Expect 'gpu_nonblank=true' 15000
    Shot $c "$out\1-initial.png"
    $id = Widget-Id $c switch "Auto refresh"
    Send-Cmd widget-click $c $id | Out-Null
    Expect 'Auto refresh off.' 10000
    Set-WidgetText $c textbox "Segment search" "native-engine"
    Start-Sleep -Seconds 1
    $id = Widget-Id $c slider "Confidence threshold"
    Send-Cmd widget-action $c $id increment | Out-Null
    Start-Sleep -Seconds 1
    Shot $c "$out\2-interacted.png"
    Send-Cmd resize 1120 700 | Out-Null; Start-Sleep -Seconds 1
    Write-Output "bounds after resize 1120x700: $(Window-Bounds)"
    $relayout = Snapshot-Lines | Select-String -Pattern 'view @w1/dashboard-canvas kind=gpu_surface.*bounds=\(0,0 1120x700\)' | Select-Object -First 1
    if ($relayout) { Write-Output "ok: canvas relayout 1120x700" } else { Write-Output "MISS: canvas relayout after resize" }
    Check-MinSize
    Shot $c "$out\3-resized.png"
    Finish "gpu-dashboard" $out
}

function Drive-Deck {
    $out = "$DriveOut\deck"; $c = "deck-canvas"
    if (-not (Launch-App "deck")) { return }
    Shot $c "$out\1-initial.png"
    Click-Widget $c button "Play or pause"
    Start-Sleep -Seconds 1
    Shot $c "$out\2-playing.png"
    $id = Widget-Id $c slider "Volume"
    Send-Cmd widget-action $c $id decrement | Out-Null
    # Playlist opens a second window.
    Click-Widget $c button "Playlist window"
    Start-Sleep -Seconds 2
    $w2 = Snapshot-Lines | Select-String -Pattern 'window @w2' | Select-Object -First 1
    if ($w2) { Write-Output "ok: playlist window @w2 appeared" } else { Write-Output "MISS: playlist window @w2" }
    Desktop-Shot "$out\3-two-windows-desktop.png"
    Check-MinSize
    Finish "deck" $out
}

function Drive-Feed {
    $out = "$DriveOut\feed"; $c = "feed-canvas"
    if (-not (Launch-App "feed")) { return }
    Shot $c "$out\1-initial.png"
    Click-Widget $c button "Like post 0"
    Start-Sleep -Milliseconds 500
    Shot $c "$out\2-liked.png"
    # Windowed list scroll: wheel down hard, the visible post range must move.
    $before = (Snapshot-Lines | Select-String -Pattern 'posts \d+–\d+' | Select-Object -First 1)
    Wheel-Widget $c button "Like post 3" 400
    Start-Sleep -Seconds 1
    Wheel-Widget $c button "Like post 6" 400
    Start-Sleep -Seconds 1
    $after = (Snapshot-Lines | Select-String -Pattern 'posts \d+–\d+' | Select-Object -First 1)
    $beforeText = if ($before) { $before.Matches[0].Value } else { "" }
    $afterText = if ($after) { $after.Matches[0].Value } else { "" }
    Write-Output "scroll: '$beforeText' -> '$afterText'"
    if ($beforeText -ne $afterText) { Write-Output "ok: windowed scroll moved" } else { Write-Output "MISS: scroll did not move visible range" }
    Shot $c "$out\3-scrolled.png"
    Send-Cmd resize 700 900 | Out-Null; Start-Sleep -Seconds 1
    Write-Output "bounds after resize 700x900: $(Window-Bounds)"
    Check-MinSize
    Finish "feed" $out
}

function Drive-Kanban {
    $out = "$DriveOut\kanban"; $c = "kanban-canvas"
    if (-not (Launch-App "kanban")) { return }
    Shot $c "$out\1-initial.png"
    Click-Widget $c button "Add card"
    Expect '3 todo' 5000
    # Move the first card right.
    $match = Snapshot-Lines | Select-String -Pattern 'widget @w1/kanban-canvas#(\d+) role=button name=">"' | Select-Object -First 1
    if ($match) { Send-Cmd widget-click $c $match.Matches[0].Groups[1].Value | Out-Null }
    Expect '2 doing' 5000
    Shot $c "$out\2-moved.png"
    Send-Cmd resize 1100 700 | Out-Null; Start-Sleep -Seconds 1
    Write-Output "bounds after resize 1100x700: $(Window-Bounds)"
    Check-MinSize
    Finish "kanban" $out
}

function Drive-UiInbox {
    $out = "$DriveOut\ui-inbox"; $c = "inbox-canvas"
    if (-not (Launch-App "ui-inbox")) { return }
    Shot $c "$out\1-initial.png"
    $match = Snapshot-Lines | Select-String -Pattern 'widget @w1/inbox-canvas#(\d+) role=textbox name=""' | Select-Object -First 1
    if ($match) { Send-Cmd widget-action $c $match.Matches[0].Groups[1].Value set-text "verify-windows-truth" | Out-Null }
    Click-Widget $c button "Add task"
    Expect '4 open' 5000
    # Complete the first task via its checkbox, then filter to done.
    Click-Widget $c checkbox "Done"
    Expect '1 done' 5000
    Click-Widget $c tab "done"
    Start-Sleep -Milliseconds 500
    Shot $c "$out\2-done-filter.png"
    Click-Widget $c button "Clear done"
    Expect '0 done' 5000
    Send-Cmd resize 900 700 | Out-Null; Start-Sleep -Seconds 1
    Write-Output "bounds after resize 900x700: $(Window-Bounds)"
    Check-MinSize
    Shot $c "$out\3-resized.png"
    Finish "ui-inbox" $out
}

$driveFns = @{
    "calculator" = { Drive-Calculator }; "notes" = { Drive-Notes }
    "soundboard" = { Drive-Soundboard }; "markdown-viewer" = { Drive-MarkdownViewer }
    "system-monitor" = { Drive-SystemMonitor }; "gpu-dashboard" = { Drive-GpuDashboard }
    "deck" = { Drive-Deck }; "feed" = { Drive-Feed }
    "kanban" = { Drive-Kanban }; "ui-inbox" = { Drive-UiInbox }
}

$apps = if ($args.Count -gt 0) { $args } else { $Apps }
foreach ($app in $apps) {
    Write-Output "==== drive $app ===="
    New-Item -ItemType Directory -Force -Path "$DriveOut\$app" | Out-Null
    & $driveFns[$app] *>&1 | Tee-Object "$DriveOut\$app\drive.log"
}
Write-Output "drive complete"
