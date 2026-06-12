<#
.TGML Screenshot Capture Script
Captures screenshots of TGML files using Schneider's SE.Graphics.Editor.exe
without visually showing the editor window. Uses a single editor instance.

Usage:
    .\capture-tgml-screenshots.ps1 -InputPath "C:\TGML\Graphics"
    .\capture-tgml-screenshots.ps1 -InputPath "C:\TGML\Graphics" -EditorPath "C:\path\to\SE.Graphics.Editor.exe"
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

public class Win32Capture
{
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, int nFlags);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder text, int count);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    public const int SW_HIDE = 0;
    public const int SW_SHOWMINIMIZED = 2;
    public const int SW_FORCEMINIMIZE = 11;
    public const int WM_CLOSE = 0x0010;

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

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

    # Search Program Files as last resort
    $found = Get-ChildItem -Path "${env:ProgramFiles}", "${env:ProgramFiles(x86)}" `
        -Filter "SE.Graphics.Editor.exe" -Recurse -ErrorAction SilentlyContinue `
        | Select-Object -First 1

    if ($found) { return $found.FullName }
    return $null
}

# ─── Wait for window handle ────────────────────────────────────────────────
function Get-WindowHandle {
    param($Process, [string]$DisplayName, [int]$TimeoutSeconds)

    $hWnd = [IntPtr]::Zero
    $elapsed = 0
    $maxTries = $TimeoutSeconds * 2

    while ($hWnd -eq [IntPtr]::Zero -and $elapsed -lt $maxTries) {
        $Process.Refresh()
        $hWnd = $Process.MainWindowHandle
        if ($hWnd -eq [IntPtr]::Zero -and $Process.HasExited) { break }
        if ($hWnd -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 500 }
        $elapsed++
    }

    # Fallback: search by process name + ID
    if ($hWnd -eq [IntPtr]::Zero) {
        $fallback = Get-Process -Name "*Graphics*Editor*" -ErrorAction SilentlyContinue `
            | Where-Object { $_.Id -eq $Process.Id }
        if ($fallback -and $fallback.MainWindowHandle -ne [IntPtr]::Zero) {
            $hWnd = $fallback.MainWindowHandle
        }
    }

    return $hWnd
}

# ─── Validate inputs ───────────────────────────────────────────────────────
$editorExe = Find-Editor
if (-not $editorExe) {
    Write-Host "ERROR: Could not find SE.Graphics.Editor.exe"
    Write-Host "Install it or pass -EditorPath parameter."
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
Write-Host ""

# ─── Launch main editor instance (single-instance mode) ────────────────────
Write-Host "Starting editor instance..."

$mainProc = Start-Process -FilePath $editorExe -ArgumentList "`"$($tgmlFiles[0].FullName)`"" `
    -WindowStyle Normal -PassThru

Write-Host "  waiting for window... " -NoNewline
$mainHwnd = Get-WindowHandle -Process $mainProc -DisplayName "editor" -TimeoutSeconds $WindowTimeoutSeconds

if ($mainHwnd -eq [IntPtr]::Zero) {
    Write-Host "FAIL"
    if (-not $mainProc.HasExited) { $mainProc.Kill() }
    exit 1
}

# Hide off-screen — no flash since we only do this once
[Win32Capture]::SetWindowPos($mainHwnd, [IntPtr]::Zero, -3000, -3000, 1600, 900, 0x0014) | Out-Null
Write-Host "OK (hidden)"

# ─── Process each file ─────────────────────────────────────────────────────
$success = 0
$failed = 0

for ($i = 0; $i -lt $tgmlFiles.Count; $i++) {
    $file = $tgmlFiles[$i]
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
    $outFile = Join-Path $outDir "${baseName}.png"
    $fileNum = $i + 1

    if (Test-Path $outFile) {
        Write-Host "[$fileNum/$($tgmlFiles.Count)] SKIP  $baseName (already exists)"
        continue
    }

    Write-Host "[$fileNum/$($tgmlFiles.Count)] CAPT  $baseName ... " -NoNewline

    try {
        if ($i -eq 0) {
            # File 1: already loaded in the main instance
            Write-Host "render... " -NoNewline
        } else {
            # Files 2+: open in existing instance
            # Launch editor with file — if single-instance, it signals the main instance and exits
            Write-Host "open... " -NoNewline
            $childProc = Start-Process -FilePath $editorExe -ArgumentList "`"$($file.FullName)`"" `
                -WindowStyle Normal -PassThru

            # Wait for child to exit (single-instance apps exit quickly after sending the file)
            $childExited = $childProc.WaitForExit(5000)

            if ($childExited) {
                # Single-instance mode: file opened in main window, child exited
                Write-Host "sent... " -NoNewline
            } else {
                # Multi-instance mode: new window appeared
                $childHwnd = Get-WindowHandle -Process $childProc -DisplayName "child" -TimeoutSeconds 5
                if ($childHwnd -ne [IntPtr]::Zero) {
                    # Use child window for capture
                    [Win32Capture]::SetWindowPos($childHwnd, [IntPtr]::Zero, -3000, -3000, 1600, 900, 0x0014) | Out-Null
                    $mainHwnd = $childHwnd
                    $mainProc = $childProc
                }
                Write-Host "render... " -NoNewline
            }

            # Clear "already exists" for next file if single-instance
            Start-Sleep -Milliseconds 500
        }

        # Wait for rendering
        Write-Host "($RenderDelaySeconds sec)... " -NoNewline
        Start-Sleep -Seconds $RenderDelaySeconds

        # Capture
        $bmp = [Win32Capture]::CaptureWindow($mainHwnd)
        if ($bmp -eq $null) {
            Write-Host "FAIL (blank capture)"
            $failed++
            continue
        }

        $bmp.Save($outFile, [System.Drawing.Imaging.ImageFormat]::Png)
        $size = "($($bmp.Width)x$($bmp.Height))"
        $bmp.Dispose()

        Write-Host "OK $size"
        $success++
    }
    catch {
        Write-Host "FAIL ($($_.Exception.Message))"
        $failed++
    }
}

# ─── Clean up ──────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Closing editor..."
if (-not $mainProc.HasExited) {
    [Win32Capture]::SendMessage($mainHwnd, [Win32Capture]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    $closed = $mainProc.WaitForExit(10000)
    if (-not $closed) {
        $mainProc.Kill()
        Start-Sleep -Milliseconds 500
    }
}

# Kill any stray editor processes
Get-Process -Name "*Graphics*Editor*" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

Write-Host "Done: $success captured, $failed failed"