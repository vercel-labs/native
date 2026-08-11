# Console-desktop half of perf-input.ps1. This script must run through an
# interactive scheduled task: SetCursorPos/SendInput target the logged-in
# desktop, while an ssh session lives in an invisible service session.
param(
    [string]$ProcessName = "gpu-dashboard",
    [string]$WorkingDirectory,
    [string]$CliPath,
    [string]$SnapshotPath,
    [string]$OutputPath,
    [string]$HoverAId,
    [string]$HoverBId,
    [double]$HoverAX,
    [double]$HoverAY,
    [double]$HoverBX,
    [double]$HoverBY,
    [double]$WheelX,
    [double]$WheelY,
    [double]$SurfaceWidth,
    [double]$SurfaceHeight,
    [int]$HoverSamples = 10,
    [int]$WheelEvents = 120,
    [int]$WheelIntervalMs = 16
)

$ErrorActionPreference = "Stop"

$user32 = @'
using System;
using System.Runtime.InteropServices;

public static class NativeSdkInputPerf {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT {
        public uint Type;
        public INPUTUNION Data;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct INPUTUNION {
        [FieldOffset(0)] public MOUSEINPUT Mouse;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT {
        public int Dx;
        public int Dy;
        public uint MouseData;
        public uint Flags;
        public uint Time;
        public UIntPtr ExtraInfo;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string className, string title);

    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hwnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool ClientToScreen(IntPtr hwnd, ref POINT point);

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hwnd, int command);

    [DllImport("user32.dll")]
    static extern IntPtr GetDC(IntPtr hwnd);

    [DllImport("user32.dll")]
    static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);

    [DllImport("gdi32.dll")]
    static extern int GetDeviceCaps(IntPtr dc, int index);

    public static int DisplayRefreshHz(IntPtr hwnd) {
        IntPtr dc = GetDC(hwnd);
        if (dc == IntPtr.Zero) return 0;
        try {
            return GetDeviceCaps(dc, 116); // VREFRESH
        } finally {
            ReleaseDC(hwnd, dc);
        }
    }

    [DllImport("user32.dll", SetLastError = true)]
    static extern uint SendInput(uint inputCount, INPUT[] inputs, int inputSize);

    public static bool SendWheel(int delta) {
        INPUT input = new INPUT();
        input.Type = 0; // INPUT_MOUSE
        input.Data.Mouse.MouseData = unchecked((uint)delta);
        input.Data.Mouse.Flags = 0x0800; // MOUSEEVENTF_WHEEL
        return SendInput(1, new INPUT[] { input }, Marshal.SizeOf(typeof(INPUT))) == 1;
    }

    [DllImport("winmm.dll")]
    public static extern uint timeBeginPeriod(uint periodMilliseconds);

    [DllImport("winmm.dll")]
    public static extern uint timeEndPeriod(uint periodMilliseconds);
}
'@
Add-Type -TypeDefinition $user32

function Read-Snapshot {
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        try {
            if (Test-Path $SnapshotPath) {
                return [IO.File]::ReadAllText($SnapshotPath)
            }
        } catch {
            # The publisher replaces atomically, but antivirus/indexing can
            # still hold the old file for a moment. Retry like the CLI does.
        }
        [Threading.Thread]::Sleep(5)
    }
    return ""
}

function Snapshot-Fields([string]$snapshot) {
    $view = ($snapshot -split "`r?`n" | Select-String -Pattern 'view @w1/dashboard-canvas kind=gpu_surface' | Select-Object -First 1)
    if (-not $view) { return $null }
    $line = $view.Line
    $frame = [regex]::Match($line, 'gpu_frame=(\d+)')
    $frameTimestamp = [regex]::Match($line, 'gpu_timestamp_ns=(\d+)')
    $inputCount = [regex]::Match($line, 'gpu_input_count=(\d+)')
    $input = [regex]::Match($line, 'gpu_input_timestamp_ns=(\d+)')
    $latency = [regex]::Match($line, 'gpu_input_latency_ns=(\d+)')
    if (-not ($frame.Success -and $frameTimestamp.Success -and $inputCount.Success -and $input.Success -and $latency.Success)) { return $null }
    return [pscustomobject]@{
        Frame = [uint64]$frame.Groups[1].Value
        FrameTimestampNs = [uint64]$frameTimestamp.Groups[1].Value
        InputCount = [uint64]$inputCount.Groups[1].Value
        InputTimestampNs = [uint64]$input.Groups[1].Value
        InputLatencyNs = [uint64]$latency.Groups[1].Value
    }
}

function Widget-Hovered([string]$snapshot, [string]$id) {
    $escaped = [regex]::Escape($id)
    $line = ($snapshot -split "`r?`n" | Select-String -Pattern ("widget @w1/dashboard-canvas#" + $escaped + " ") | Select-Object -First 1)
    if (-not $line) { return $false }
    return $line.Line -match 'state=\[[^\]]*hovered'
}

function Screen-Point([IntPtr]$canvas, [double]$logicalX, [double]$logicalY, [double]$scaleX, [double]$scaleY) {
    $point = New-Object NativeSdkInputPerf+POINT
    $point.X = [int][Math]::Round($logicalX * $scaleX)
    $point.Y = [int][Math]::Round($logicalY * $scaleY)
    if (-not [NativeSdkInputPerf]::ClientToScreen($canvas, [ref]$point)) {
        throw "ClientToScreen failed"
    }
    return $point
}

function Move-And-Measure([IntPtr]$canvas, [string]$id, [double]$x, [double]$y, [double]$scaleX, [double]$scaleY) {
    $before = Snapshot-Fields (Read-Snapshot)
    if (-not $before) { throw "GPU view telemetry missing before hover input" }
    $point = Screen-Point $canvas $x $y $scaleX $scaleY
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $lastFields = $before
    $lastHovered = $false
    if (-not [NativeSdkInputPerf]::SetCursorPos($point.X, $point.Y)) {
        throw "SetCursorPos failed"
    }
    while ($watch.ElapsedMilliseconds -lt 1000) {
        $snapshot = Read-Snapshot
        $fields = Snapshot-Fields $snapshot
        $hovered = $fields -and (Widget-Hovered $snapshot $id)
        if ($fields) {
            $lastFields = $fields
            $lastHovered = $hovered
        }
        if ($fields -and
            # Input receipt republishes its timestamp before the responding
            # present replaces the previous sample's latency. Require the
            # observable frame clock to have reached this exact input before
            # accepting the hover state and latency as one sample.
            $fields.InputCount -gt $before.InputCount -and
            $fields.InputTimestampNs -gt $before.InputTimestampNs -and
            $fields.FrameTimestampNs -ge $fields.InputTimestampNs -and
            $fields.InputLatencyNs -gt 0 -and
            $hovered) {
            $watch.Stop()
            return [pscustomobject]@{
                Target = $id
                ExternalMs = [Math]::Round($watch.Elapsed.TotalMilliseconds, 3)
                BuiltinMs = [Math]::Round($fields.InputLatencyNs / 1000000.0, 3)
                Frame = $fields.Frame
                InputCount = $fields.InputCount
                InputTimestampNs = $fields.InputTimestampNs
                FrameTimestampNs = $fields.FrameTimestampNs
                Hovered = $hovered
                TimedOut = $false
            }
        }
        [Threading.Thread]::Sleep(1)
    }
    $watch.Stop()
    return [pscustomobject]@{
        Target = $id
        ExternalMs = [Math]::Round($watch.Elapsed.TotalMilliseconds, 3)
        BuiltinMs = 0
        Frame = $before.Frame
        InputCount = $lastFields.InputCount
        InputTimestampNs = $lastFields.InputTimestampNs
        FrameTimestampNs = $lastFields.FrameTimestampNs
        Hovered = $lastHovered
        TimedOut = $true
    }
}

function Reset-Profile {
    & $CliPath automate profile off | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "automation profile off failed" }
    & $CliPath automate profile on | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "automation profile on failed" }
}

function Profile-Intervals([string]$snapshot) {
    $profile = ($snapshot -split "`r?`n" | Select-String -Pattern '^frame_profile ' | Select-Object -First 1)
    if (-not $profile) { throw "frame_profile telemetry missing" }
    $p50 = [regex]::Match($profile.Line, 'interval_p50_us=(\d+)')
    $p90 = [regex]::Match($profile.Line, 'interval_p90_us=(\d+)')
    $max = [regex]::Match($profile.Line, 'interval_max_us=(\d+)')
    $count = [regex]::Match($profile.Line, 'interval_n=(\d+)')
    if (-not ($p50.Success -and $p90.Success -and $max.Success -and $count.Success)) {
        throw "frame_profile interval fields missing"
    }
    return [pscustomobject]@{
        P50Ms = [Math]::Round(([uint64]$p50.Groups[1].Value) / 1000.0, 3)
        P90Ms = [Math]::Round(([uint64]$p90.Groups[1].Value) / 1000.0, 3)
        MaxMs = [Math]::Round(([uint64]$max.Groups[1].Value) / 1000.0, 3)
        Samples = [uint64]$count.Groups[1].Value
    }
}

$result = [ordered]@{
    Error = $null
    DisplayRefreshHz = 0
    Hover = @()
    Animation = $null
    Wheel = $null
}

try {
    Set-Location $WorkingDirectory
    $process = Get-Process -Name $ProcessName -ErrorAction Stop |
        Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } |
        Select-Object -First 1
    if (-not $process) { throw "visible $ProcessName process not found" }
    $root = $process.MainWindowHandle
    $canvas = [NativeSdkInputPerf]::FindWindowExW($root, [IntPtr]::Zero, "NativeSdkGpuSurface", $null)
    if ($canvas -eq [IntPtr]::Zero) { throw "NativeSdkGpuSurface child window not found" }
    $result.DisplayRefreshHz = [NativeSdkInputPerf]::DisplayRefreshHz($canvas)

    [NativeSdkInputPerf]::ShowWindow($root, 5) | Out-Null # SW_SHOW
    [NativeSdkInputPerf]::SetForegroundWindow($root) | Out-Null
    $rect = New-Object NativeSdkInputPerf+RECT
    if (-not [NativeSdkInputPerf]::GetClientRect($canvas, [ref]$rect)) { throw "GetClientRect failed" }
    if ($SurfaceWidth -le 0 -or $SurfaceHeight -le 0) { throw "invalid logical surface size" }
    $scaleX = ($rect.Right - $rect.Left) / $SurfaceWidth
    $scaleY = ($rect.Bottom - $rect.Top) / $SurfaceHeight
    [NativeSdkInputPerf]::timeBeginPeriod(1) | Out-Null

    # Start away from both hover probes so the first sample is a real edge.
    $warm = Screen-Point $canvas $WheelX $WheelY $scaleX $scaleY
    [NativeSdkInputPerf]::SetCursorPos($warm.X, $warm.Y) | Out-Null
    [Threading.Thread]::Sleep(100)

    # The task hop and foreground activation can discard its first pointer
    # edge. Prime both targets before collecting the measured population so
    # process/window startup never masquerades as hover latency.
    Move-And-Measure $canvas $HoverAId $HoverAX $HoverAY $scaleX $scaleY | Out-Null
    Move-And-Measure $canvas $HoverBId $HoverBX $HoverBY $scaleX $scaleY | Out-Null

    $hoverResults = @()
    for ($index = 0; $index -lt $HoverSamples; $index++) {
        if (($index % 2) -eq 0) {
            $hoverResults += Move-And-Measure $canvas $HoverAId $HoverAX $HoverAY $scaleX $scaleY
        } else {
            $hoverResults += Move-And-Measure $canvas $HoverBId $HoverBX $HoverBY $scaleX $scaleY
        }
    }
    $result.Hover = $hoverResults

    # The explicit automation-only command starts a retained animation that
    # loops until the stop command, without overriding the operator's
    # reduce-motion preference. With no subsequent driver input, this isolates
    # the app-owned frame wake-up cadence.
    Reset-Profile
    $animationStart = Snapshot-Fields (Read-Snapshot)
    if (-not $animationStart) { throw "GPU view telemetry missing before animation" }
    & $CliPath automate native-command dashboard.perf-animation dashboard-canvas | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "performance animation command failed" }
    [Threading.Thread]::Sleep(1100)
    # Steady GPU completions do not republish automation text once their
    # discrete facts settle. `profile on` while already enabled preserves
    # the sample window and wakes one fresh snapshot for this measurement.
    & $CliPath automate profile on | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "animation profile publication failed" }
    $animationSnapshot = Read-Snapshot
    $animationFinish = Snapshot-Fields $animationSnapshot
    if (-not $animationFinish) { throw "GPU view telemetry missing after animation" }
    $animationIntervals = Profile-Intervals $animationSnapshot
    $result.Animation = [pscustomobject]@{
        Frames = [uint64]($animationFinish.Frame - $animationStart.Frame)
        IntervalP50Ms = $animationIntervals.P50Ms
        IntervalP90Ms = $animationIntervals.P90Ms
        IntervalMaxMs = $animationIntervals.MaxMs
        IntervalSamples = $animationIntervals.Samples
    }
    & $CliPath automate native-command dashboard.perf-animation-stop dashboard-canvas | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "performance animation stop command failed" }

    # Settle the pointer first, then reset the frame profiler immediately
    # before the sustained native wheel burst. That keeps the positioning
    # frame and its idle tail out of the interval distribution. The CLI waits
    # until the command is consumed.
    $wheelPoint = Screen-Point $canvas $WheelX $WheelY $scaleX $scaleY
    [NativeSdkInputPerf]::SetCursorPos($wheelPoint.X, $wheelPoint.Y) | Out-Null
    [Threading.Thread]::Sleep(100)
    Reset-Profile
    $start = Snapshot-Fields (Read-Snapshot)
    if (-not $start) { throw "GPU view telemetry missing before wheel burst" }

    $wheelWatch = [Diagnostics.Stopwatch]::StartNew()
    for ($index = 0; $index -lt $WheelEvents; $index++) {
        # Alternate one notch in each direction so the dashboard's short
        # scroll range never saturates and every message remains meaningful.
        $delta = if (($index % 2) -eq 0) { 120 } else { -120 }
        if (-not [NativeSdkInputPerf]::SendWheel($delta)) {
            throw "SendInput(MOUSEEVENTF_WHEEL) failed"
        }
        [Threading.Thread]::Sleep($WheelIntervalMs)
    }
    $wheelWatch.Stop()
    [Threading.Thread]::Sleep(250)
    $finalSnapshot = Read-Snapshot
    $finish = Snapshot-Fields $finalSnapshot
    if (-not $finish) { throw "GPU view telemetry missing after wheel burst" }
    $wheelIntervals = Profile-Intervals $finalSnapshot
    $result.Wheel = [pscustomobject]@{
        Events = $WheelEvents
        DeliveredInputs = [uint64]($finish.InputCount - $start.InputCount)
        ElapsedMs = [Math]::Round($wheelWatch.Elapsed.TotalMilliseconds, 3)
        Frames = [uint64]($finish.Frame - $start.Frame)
        IntervalP50Ms = $wheelIntervals.P50Ms
        IntervalP90Ms = $wheelIntervals.P90Ms
        IntervalMaxMs = $wheelIntervals.MaxMs
        IntervalSamples = $wheelIntervals.Samples
    }
} catch {
    $result.Error = $_.Exception.Message
}

[NativeSdkInputPerf]::timeEndPeriod(1) | Out-Null

$result | ConvertTo-Json -Depth 6 | Set-Content -Path $OutputPath -Encoding UTF8
