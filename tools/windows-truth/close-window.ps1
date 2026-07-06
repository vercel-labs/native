# Post WM_CLOSE to a window by title (console session).
param([string]$Title)
$sig = @'
[DllImport("user32.dll", CharSet=CharSet.Unicode)]
public static extern IntPtr FindWindowW(string cls, string title);
[DllImport("user32.dll")]
public static extern bool PostMessageW(IntPtr hwnd, uint msg, IntPtr w, IntPtr l);
'@
Add-Type -MemberDefinition $sig -Name Closer -Namespace Native
$hwnd = [Native.Closer]::FindWindowW($null, $Title)
if ($hwnd -eq [IntPtr]::Zero) {
    $proc = Get-Process | Where-Object { $_.MainWindowTitle -like "*$Title*" } | Select-Object -First 1
    if ($proc) { $hwnd = $proc.MainWindowHandle }
}
if ($hwnd -ne [IntPtr]::Zero) { [Native.Closer]::PostMessageW($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null }
