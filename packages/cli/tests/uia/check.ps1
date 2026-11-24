# Walks a running app's accessibility tree the way a screen reader does, over UI Automation.
#
#   powershell -NoProfile -File tests/uia/check.ps1 -ProcessId 1234
#
# Prints one JSON object: the window's name and control type, then the buttons a client can find
# under it, the names of everything in the tree before and after invoking the first invokable
# button. A client that cannot see the tree at all prints {"error": "..."} and exits 1.
param([Parameter(Mandatory = $true)][int]$ProcessId, [int]$TimeoutMs = 30000)

$ErrorActionPreference = "Stop"
# The JSON this prints carries element names, and one of the counter's buttons is a real minus
# sign: UTF-8 keeps it intact whatever code page the console has.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$OutputEncoding = [Console]::OutputEncoding
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

function Fail($message) {
  @{ error = $message } | ConvertTo-Json -Compress
  exit 1
}

$root = [System.Windows.Automation.AutomationElement]::RootElement
$deadline = (Get-Date).AddMilliseconds($TimeoutMs)
$window = $null
while ($window -eq $null -and (Get-Date) -lt $deadline) {
  try {
    $found = $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
  } catch {
    # A window whose provider is slow to answer is worth another look until the deadline.
    $found = $null
  }
  if ($found -ne $null) {
    for ($i = 0; $i -lt $found.Count; $i++) {
      if ($found[$i].Current.ProcessId -eq $ProcessId) { $window = $found[$i] }
    }
  }
  if ($window -eq $null) { Start-Sleep -Milliseconds 500 }
}
if ($window -eq $null) { Fail "no window for process $ProcessId" }
if ($window.Current.Name -ne "Counter") { Fail "window name is '$($window.Current.Name)', expected 'Counter'" }

$true_condition = [System.Windows.Automation.Condition]::TrueCondition
function NamesUnder($element) {
  $items = $element.FindAll([System.Windows.Automation.TreeScope]::Descendants, $true_condition)
  $names = @()
  for ($i = 0; $i -lt $items.Count; $i++) { $names += [string]$items[$i].Current.Name }
  return $names
}
function ButtonsUnder($element) {
  $condition = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Button)
  $items = $element.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
  $names = @()
  for ($i = 0; $i -lt $items.Count; $i++) { $names += [string]$items[$i].Current.Name }
  return ,$items, $names
}

# The tree is built once a client asks for it, and a walk of the window is that ask: until the
# page's buttons answer, the tree is still on its way.
$buttons = $null
$buttonNames = @()
while ($buttons -eq $null -and (Get-Date) -lt $deadline) {
  $pair = ButtonsUnder $window
  if ($pair[0].Count -gt 0) {
    $buttons = $pair[0]
    $buttonNames = $pair[1]
  } else {
    Start-Sleep -Milliseconds 250
  }
}
$before = NamesUnder $window

# Invoke the last button: the counter's "+", whose click the page answers by changing the count.
$invoked = $false
if ($buttons -ne $null -and $buttons.Count -gt 0) {
  $target = $buttons[$buttons.Count - 1]
  $pattern = $null
  if ($target.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
    $pattern.Invoke()
    Start-Sleep -Milliseconds 800
    $invoked = $true
  }
}
$after = NamesUnder $window

@{
  window = $window.Current.Name
  class = $window.Current.ClassName
  buttons = $buttonNames
  invoked = $invoked
  before = $before
  after = $after
} | ConvertTo-Json -Compress
