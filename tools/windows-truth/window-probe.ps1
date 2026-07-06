# OS-window truth probe: runs IN the console session (schedule it with
# /IT — window handles do not cross window stations), finds the target
# app window by title, dumps its style bits, then requests an absurdly
# small resize and reports the size the window manager actually granted
# (the WM_GETMINMAXINFO floor shows up here). Results are appended to
# %TEMP%\window-probe.txt for the ssh session to read.
#   powershell -NoProfile -File window-probe.ps1 -Title <window title>
param([string]$Title)

$sig = @'
[DllImport("user32.dll", CharSet=CharSet.Unicode)]
public static extern IntPtr FindWindowW(string cls, string title);
[DllImport("user32.dll")]
public static extern long GetWindowLongPtrW(IntPtr hwnd, int index);
[DllImport("user32.dll")]
public static extern bool MoveWindow(IntPtr hwnd, int x, int y, int w, int h, bool repaint);
[DllImport("user32.dll")]
public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
public struct RECT { public int Left, Top, Right, Bottom; }
'@
Add-Type -MemberDefinition $sig -Name Probe -Namespace Native

$out = "$env:TEMP\window-probe.txt"
$hwnd = [Native.Probe]::FindWindowW($null, $Title)
if ($hwnd -eq [IntPtr]::Zero) {
    # Fall back to the process main window, and list candidates so a
    # title mismatch is diagnosable from the ssh session.
    $titles = Get-Process | Where-Object { $_.MainWindowTitle } | ForEach-Object { "$($_.ProcessName)=$($_.MainWindowTitle)" }
    Add-Content $out "PROBE ${Title}: FindWindow miss; visible main windows: $($titles -join '; ')"
    $proc = Get-Process | Where-Object { $_.MainWindowTitle -like "*$Title*" } | Select-Object -First 1
    if (-not $proc) { exit 0 }
    $hwnd = $proc.MainWindowHandle
}
$style = [Native.Probe]::GetWindowLongPtrW($hwnd, -16) # GWL_STYLE
$caption = if ($style -band 0x00C00000) { "caption" } else { "no-caption" }
$thick = if ($style -band 0x00040000) { "thickframe" } else { "no-thickframe" }
$maxbox = if ($style -band 0x00010000) { "maximizebox" } else { "no-maximizebox" }
[Native.Probe]::MoveWindow($hwnd, 60, 60, 200, 150, $true) | Out-Null
Start-Sleep -Milliseconds 300
$rect = New-Object Native.Probe+RECT
[Native.Probe]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
$w = $rect.Right - $rect.Left
$h = $rect.Bottom - $rect.Top
Add-Content $out "PROBE ${Title}: style=$caption,$thick,$maxbox requested=200x150 granted=${w}x${h}"
