# Posts the input method's messages to a running app, the way a keyboard would.
#
#   powershell -NoProfile -File tests/ime/drive.ps1 -ProcessId 1234
#
# The app is started with NATIVE_IME_TEST set, which gives its window an IME context; this script
# posts the message that composes a preview ("にほん") and then the one that commits it ("日本").
# What the page made of them it prints itself.
param([Parameter(Mandatory = $true)][int]$ProcessId)

$ErrorActionPreference = "Stop"
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class ImeTest {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern uint RegisterWindowMessageW(string name);
  [DllImport("user32.dll")]
  public static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr wparam, IntPtr lparam);
}
"@

$process = Get-Process -Id $ProcessId -ErrorAction Stop
$deadline = (Get-Date).AddSeconds(20)
while ($process.MainWindowHandle -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 200
  $process.Refresh()
}
if ($process.MainWindowHandle -eq [IntPtr]::Zero) { Write-Error "no window for process $ProcessId"; exit 1 }

$message = [ImeTest]::RegisterWindowMessageW("native-ime-test")
if ($message -eq 0) { Write-Error "no test message registered"; exit 1 }
[void][ImeTest]::PostMessage($process.MainWindowHandle, $message, [IntPtr]::Zero, [IntPtr]::Zero)
Start-Sleep -Milliseconds 700
[void][ImeTest]::PostMessage($process.MainWindowHandle, $message, [IntPtr]1, [IntPtr]::Zero)
exit 0
