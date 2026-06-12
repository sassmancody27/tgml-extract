<#
.TGML Screenshot Capture Script — Per-file launch with instant off-screen hiding.
Captures screenshots of TGML files using Schneider's SE.Graphics.Editor.exe
with minimal visual flash (<50ms).

Usage:
    .\capture-tgml-screenshots.ps1 -InputPath "C:\TGML\Graphics"
    .\capture-tgml-screenshots.ps1 -InputPath "C:\TGML\file.tgml" -OutputPath "C:\out"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,

    [string]$EditorPath = "",

    [string]$OutputPath = "screenshots",

    [int]$RenderDelaySeconds = 3,

    [int]$WindowTimeoutSeconds = 20
)

# ─── Win32 API definitions via C# ──────────────────────────────────────────
Add-Type -ReferencedAssemblies "System.Drawing" -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Collections.Generic;

public class Win32Capture
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, int nFlags);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    public const int WM_CLOSE = 0x0010;

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    public static List<IntPtr> FindWindowsByProcessId(uint pid)
    {
        var handles = new List<IntPtr>();
        EnumWindows((hWnd, lParam) => {
            uint winPid;
            GetWindowThreadProcessId(hWnd, out winPid);
            if (winPid == pid)
                handles.Add(hWnd);
            return true;
        }, IntPtr.Zero);
        return handles;
    }

    public static Bitmap CaptureWindow(IntPtr hWnd)
    {
        RECT rect;
        if (!GetWindowRect(hWnd, out rect))
            return null;

        int width = rect.Right - rect.Left;
        int height = rect.Bottom - rect.Top;
        if (width <= 0 || height <= 0) return null;

        Bitmap bmp = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(bmp))
        {
            IntPtr hdc = g.GetHdc();
            PrintWindow(hWnd, hdc, 0);
            g.ReleaseHdc(hdc);
        }
        return bmp;
    }
}
"@ -ErrorAction Stop

# ─── Find editor executable ────────────────────────────────────────────────
function Find-Editor {
    if ($EditorPath -and (Test-Path $EditorPath)) {
        return (Resolve-Path $EditorPath).Path
    }

    $paths = @(
        "${env:ProgramFiles}\Schneider Electric\SE.Graphics.Editor.exe",
        "${env:ProgramFiles(x86)}\Schneider Electric\SE.Graphics.Editor.exe",
        "${env:ProgramFiles}\Schneider Electric EcoStruxure\Building Operation *\WorkStation\SE.Graphics.Editor.exe",
        "${env:ProgramFiles(x86)}\Schneider Electric EcoStruxure\Building Operation *\WorkStation\SE.Graphics.Editor.exe"
    )

    foreach ($pattern in $paths) {
        $found = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { return $found.FullName }
    }

    $found = Get-ChildItem -Path "${env:ProgramFiles}", "${env:ProgramFiles(x86)}" `
        -Filter "SE.Graphics.Editor.exe" -Recurse -ErrorAction SilentlyContinue `
        | Select-Object -First 1
    if ($found) { return $found.FullName }
    return $null
}

# ─── Fast window handle detection (50ms polling) ──────────────────────────
function Get-WindowHandleFast {
    param($Process, [int]$TimeoutSeconds)

    $procId = $Process.Id
    $hWnd = [IntPtr]::Zero
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds -and $Process.HasExited -eq $false) {
        # Try MainWindowHandle first (fastest)
        $Process.Refresh()
        if ($Process.MainWindowHandle -ne [IntPtr]::Zero) {
            $hWnd = $Process.MainWindowHandle
            break
        }

        # Fallback: enumerate all windows by PID
        $windows = [Win32Capture]::FindWindowsByProcessId($procId)
        if ($windows.Count -gt 0) {
            $hWnd = $windows[0]
            break
        }

        Start-Sleep -Milliseconds 50
    }

    return $hWnd
}

# ─── Validate inputs ───────────────────────────────────────────────────────
$editorExe = Find-Editor
if (-not $editorExe) {
    Write-Host "ERROR: Could not find SE.Graphics.Editor.exe"
    exit 1
}

if (Test-Path -Path $InputPath -PathType Container) {
    $tgmlFiles = Get-ChildItem -Path $InputPath -Filter "*.tgml" -File | Sort-Object Name
} elseif (Test-Path -Path $InputPath -PathType Leaf) {
    $tgmlFiles = @(Get-Item -Path $InputPath)
} else {
    Write-Host "ERROR: Input path not found: $InputPath"
    exit 1
}

if ($tgmlFiles.Count -eq 0) {
    Write-Host "No .tgml files found."
    exit 0
}

$outDir = New-Item -ItemType Directory -Force -Path $OutputPath | Select-Object -ExpandProperty FullName
Write-Host "Editor: $editorExe"
Write-Host "Output: $outDir"
Write-Host "Files:  $($tgmlFiles.Count)"

# ─── Process each file ─────────────────────────────────────────────────────
$success = 0
$failed = 0

for ($i = 0; $i -lt $tgmlFiles.Count; $i++) {
    $file = $tgmlFiles[$i]
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
    $outFile = Join-Path $outDir "${baseName}.png"
    $fileNum = $i + 1

    if (Test-Path $outFile) {
        Write-Host "[$fileNum/$($tgmlFiles.Count)] SKIP $baseName"
        continue
    }

    Write-Host "[$fileNum/$($tgmlFiles.Count)] $baseName ... " -NoNewline

    try {
        # Launch editor with TGML file
        $proc = Start-Process -FilePath $editorExe `
            -ArgumentList "`"$($file.FullName)`"" `
            -WindowStyle Normal -PassThru

        # Wait for window to appear (50ms polling — catches it before it paints)
        $hWnd = Get-WindowHandleFast -Process $proc -TimeoutSeconds $WindowTimeoutSeconds

        if ($hWnd -eq [IntPtr]::Zero) {
            Write-Host "FAIL (no window)"
            if (-not $proc.HasExited) { $proc.Kill() }
            $failed++
            continue
        }

        # Minimize immediately — caught before ShowWindow() completes
        [Win32Capture]::ShowWindowAsync($hWnd, [Win32Capture]::SW_SHOWMINIMIZED) | Out-Null
        Start-Sleep -Milliseconds 200

        # Wait for rendering
        Start-Sleep -Seconds $RenderDelaySeconds

        # Capture
        $bmp = [Win32Capture]::CaptureWindow($hWnd)
        if ($bmp -eq $null) {
            Write-Host "FAIL (blank)"
            if (-not $proc.HasExited) { $proc.Kill() }
            $failed++
            continue
        }

        $bmp.Save($outFile, [System.Drawing.Imaging.ImageFormat]::Png)
        $size = "($($bmp.Width)x$($bmp.Height))"
        $bmp.Dispose()

        # Close editor
        if (-not $proc.HasExited) {
            [Win32Capture]::SendMessage($hWnd, [Win32Capture]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
            $closed = $proc.WaitForExit(10000)
            if (-not $closed) { $proc.Kill() }
        }

        Write-Host "OK $size"
        $success++
    }
    catch {
        Write-Host "FAIL ($($_.Exception.Message))"
        $failed++
    }
}

# Cleanup stray processes
Get-Process -Name "*Graphics*Editor*" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

Write-Host "Done: $success captured, $failed failed"