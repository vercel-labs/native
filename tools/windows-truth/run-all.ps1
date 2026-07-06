# Windows live-truth loop, end to end — drives the toolkit on a real
# Windows 11 desktop. Requirements: the repo cloned at %USERPROFILE%\repo
# on the box, Zig 0.16 on PATH, the desktop logged in and UNLOCKED, and an
# ssh alias (key auth) whose default shell is cmd.exe. All artifacts land
# in %TEMP%\native-truth-out\.
#
# Run over ssh from the repo root on the box:
#   powershell -NoProfile -File tools\windows-truth\run-all.ps1 [recon|drive|effects|record|writeback|package|all]
#
# Session model: ssh commands run in an invisible service session.
# Anything that must touch the real desktop (launch a window, screenshot,
# resize a window, read the clipboard) hops through a `schtasks /IT`
# one-shot task; the automation transport itself is plain files under the
# app cwd (.zig-cache\native-sdk-automation), which both sessions share.
#
# Steps:
#   recon     - build every showcase app (-Dautomation=true), launch onto
#               the desktop, dump snapshot/widgets/status, engine +
#               desktop screenshots (recon.ps1)
#   drive     - per-app interaction scenarios: clicks, text input, wheel
#               scrolling, synthetic resizes, dispatch-error sweep
#               (drive.ps1; recon builds first)
#   effects   - effects-probe: spawn streaming, cancel, the PostMessage
#               wake path, clipboard write verified via a console-session
#               Get-Clipboard hop (effects-run.ps1)
#   record    - record a calculator session on the desktop, seal the
#               journal via posted WM_CLOSE (close-window.ps1), replay
#               headlessly with verification (record-replay.ps1)
#   writeback - kanban provenance + markup write-back: the edit verb
#               rewrites src/board.native byte-exact and the app's
#               hot-reload watch (app-timer driven) repaints
#               (writeback-run.ps1)
#   package   - `native package --target windows` calculator artifact
#               launched onto the desktop and driven (package-launch.ps1)
#
# window-probe.ps1 is the ad-hoc OS-window probe (style bits + the size
# the window manager grants an absurdly small resize — min-size floor
# evidence); schedule it with /IT next to a running app.
#
# Known session quirks: `>nul` in a compound ssh command line breaks the
# remote cmd parse; PowerShell 5.1 drops embedded double quotes from
# native-command arguments (lib.ps1's Expect escapes them); GUI apps
# launched directly from the ssh session create windows in the invisible
# session — snapshots and engine screenshots still work there, but desktop
# captures and WM_CLOSE need the task hop.
param([string]$Step = "all")

$steps = @{
    "recon" = { & "$PSScriptRoot\recon.ps1" }
    "drive" = { & "$PSScriptRoot\drive.ps1" }
    "effects" = { & "$PSScriptRoot\effects-run.ps1" }
    "record" = { & "$PSScriptRoot\record-replay.ps1" }
    "writeback" = { & "$PSScriptRoot\writeback-run.ps1" }
    "package" = { & "$PSScriptRoot\package-launch.ps1" }
}
if ($Step -eq "all") {
    foreach ($name in @("recon", "drive", "effects", "record", "writeback", "package")) {
        Write-Output "#### $name"
        & $steps[$name]
    }
} elseif ($steps.ContainsKey($Step)) {
    & $steps[$Step]
} else {
    Write-Output "usage: run-all.ps1 [recon|drive|effects|record|writeback|package|all]"
}
