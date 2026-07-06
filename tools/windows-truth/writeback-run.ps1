# Provenance + markup write-back truth on kanban: the edit verb rewrites
# src/board.native byte-exact, the app's hot-reload watch (app-timer
# driven) picks it up and repaints, and the flip-back restores the file
# byte-identically. Requires kanban built with -Dautomation=true (recon).
. "$PSScriptRoot\lib.ps1"
$app = "kanban"; $c = "kanban-canvas"
if (-not (Launch-App $app)) { exit 1 }
Set-Location (AppDir $app)
Copy-Item src\board.native "$env:TEMP\board.native.backup" -Force
$id = Widget-Id $c button "Add card"
Write-Output "button id: $id"
$prov = & $CLI automate provenance $c $id 2>&1 | Out-String
if ($prov -match 'authored=markup' -and $prov -match 'root=src/board.native') { Write-Output "ok: provenance markup-authored" } else { Write-Output "MISS: provenance: $prov" }
# Write-back: flip the label; the app's own hot-reload watch (app-timer
# driven) picks the file change up and repaints.
& $CLI automate edit $c $id set-text "Add task" *> $null
Expect 'role=button name="Add task"' 15000
if (Select-String -Path src\board.native -Pattern ">Add task<" -Quiet) { Write-Output "ok: file writeback landed" } else { Write-Output "MISS: file writeback" }
& $CLI automate edit $c $id set-text "Add card" *> $null
Expect 'role=button name="Add card"' 15000
$orig = Get-Content "$env:TEMP\board.native.backup" -Raw
$now = Get-Content src\board.native -Raw
if ($orig -eq $now) { Write-Output "ok: flip-back restored byte-identical" } else { Write-Output "MISS: file differs after flip-back" }
Copy-Item "$env:TEMP\board.native.backup" src\board.native -Force
Stop-App $app
