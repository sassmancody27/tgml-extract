<#
.TGML Screenshot Capture Script
Captures screenshots of TGML files using Schneider's SE.Graphics.Editor.exe
without visually showing the editor window.

Usage:
    # Auto-detect editor + process a folder
    .\capture-tgml-screenshots.ps1 -InputPath "C:\TGML\Graphics"

    # Specify editor path + output folder
    .\capture-tgml-screenshots.ps1 -InputPath "C:\TGML\Graphics" `
        -EditorPath "C:\Program Files (x86)\Schneider Electric\SE.Graphics.Editor.exe" `
        -OutputPath "C:\TGML\Screenshots"

    # Single file mode
    .\capture-tgml-screenshots.ps1 -InputPath "C:\TGML\Graphics\AHU-1.tgml"

Requirements: Windows, SE.Graphics.Editor.exe installed
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,

    [string]$EditorPath = "",

    [string]$OutputPath = "screenshots",

    [int]$RenderDelaySeconds = 3,

    [int]$WindowTimeoutSeconds = 20,

    [string]$BgColor = "#F0F0F0"
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

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);

    public const int SW_HIDE = 0;
    public const int SW_SHOWNORMAL = 1;
    public const int SW_SHOWMINIMIZED = 2;
    public const int SW_FORCEMINIMIZE = 11;
    public const int HWND_NOTOPMOST = -2;
    public const int SWP_NOMOVE = 0x0002;
    public const int SWP_NOSIZE = 0x0001;
    public const int SWP_HIDEWINDOW = 0x0080;
    public const int WM_CLOSE = 0x0010;
    public const uint INFINITE = 0xFFFFFFFF;

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left, Top, Right, Bottom;
    }

    public static Bitmap CaptureWindow(IntPtr hWnd)
    {
        RECT rect;
        if (!GetWindowRect(hWnd, out rect))
            return null;

        int width = rect.Right - rect.Left;
        int height = rect.Bottom - rect.Top;

        if (width <= 0 || height <= 0)
            return null;

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

# ─── Helper: Find the editor executable ────────────────────────────────────
function Find-Editor {
    if ($EditorPath -and (Test-Path $EditorPath)) {
        return (Resolve-Path $EditorPath).Path
    }

    $candidates = @(
        "${env:ProgramFiles}\Schneider Electric\SE.Graphics.Editor.exe",
        "${env:ProgramFiles(x86)}\Schneider Electric\SE.Graphics.Editor.exe",
        "${env:ProgramFiles}\Schneider Electric\EcoStruxure\SE.Graphics.Editor.exe",
        "${env:ProgramFiles(x86)}\Schneider Electric\EcoStruxure\SE.Graphics.Editor.exe",
        "${env:LOCALAPPDATA}\Schneider Electric\SE.Graphics.Editor.exe",
        "${env:ProgramFiles}\SE.Graphics.Editor\SE.Graphics.Editor.exe",
        "${env:ProgramFiles(x86)}\SE.Graphics.Editor\SE.Graphics.Editor.exe",
        "C:\Program Files (x86)\Schneider Electric\Andover Continuum\Graphics Editor\SE.Graphics.Editor.exe"
    )

    foreach ($c in $candidates) {
        if (Test-Path $c) { return (Resolve-Path $c).Path }
    }

    # Last resort: search Program Files
    $found = Get-ChildItem -Path "${env:ProgramFiles}", "${env:ProgramFiles(x86)}" `
        -Filter "SE.Graphics.Editor.exe" -Recurse -ErrorAction SilentlyContinue `
        | Select-Object -First 1

    if ($found) { return $found.FullName }

    return $null
}

# ─── Helper: Wait for a window by title or class ───────────────────────────
function Wait-Window {
    param([string]$TitleMatch, [int]$TimeoutSeconds)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $sb = New-Object System.Text.StringBuilder 256
        [Win32Capture]::GetWindowText([Win32Capture]::FindWindow($null, $null), $sb, 256) | Out-Null

        # Find any window whose title matches
        $hWnd = [Win32Capture]::FindWindow($null, $null)
        $hwnds = @()
        # Enumerate by trying common patterns
        $proc = Get-Process | Where-Object { $_.ProcessName -like "*Graphics*Editor*" -or $_.ProcessName -like "*SE.Graphics*" }
        if (-not $proc) {
            Start-Sleep -Milliseconds 300
            continue
        }

        # Get main window handle
        $hMain = $proc.MainWindowHandle
        if ($hMain -ne [IntPtr]::Zero) {
            $title = $proc.MainWindowTitle
            if ($title -like "*$TitleMatch*") {
                return $hMain
            }
        }

        Start-Sleep -Milliseconds 300
    }
    return [IntPtr]::Zero
}

# ─── Validate inputs ───────────────────────────────────────────────────────
$editorExe = Find-Editor
if (-not $editorExe) {
    Write-Host "ERROR: Could not find SE.Graphics.Editor.exe"
    Write-Host "Install it or pass -EditorPath parameter."
    exit 1
}
Write-Host "Editor: $editorExe"

# Resolve input files
if (Test-Path -Path $InputPath -PathType Container) {
    $tgmlFiles = Get-ChildItem -Path $InputPath -Filter "*.tgml" -File | Sort-Object Name
}
elseif (Test-Path -Path $InputPath -PathType Leaf) {
    $tgmlFiles = @(Get-Item -Path $InputPath)
}
else {
    Write-Host "ERROR: Input path not found: $InputPath"
    exit 1
}

if ($tgmlFiles.Count -eq 0) {
    Write-Host "No .tgml files found."
    exit 0
}

# Create output directory
$outDir = New-Item -ItemType Directory -Force -Path $OutputPath | Select-Object -ExpandProperty FullName
Write-Host "Editor: $editorExe"
Write-Host "Output: $outDir"
Write-Host "Files:  $($tgmlFiles.Count)"
Write-Host ""

# ─── Process each file ─────────────────────────────────────────────────────
$success = 0
$failed = 0
$fileIndex = 0

foreach ($file in $tgmlFiles) {
    $fileIndex++
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
    $outFile = Join-Path $outDir "${baseName}.png"

    if (Test-Path $outFile) {
        Write-Host "[$fileIndex/$($tgmlFiles.Count)] SKIP  $baseName (already exists)"
        continue
    }

    Write-Host "[$fileIndex/$($tgmlFiles.Count)] CAPT  $baseName ... " -NoNewline

    try {
                # Launch editor with TGML file
                Write-Host "launching... " -NoNewline
                $proc = Start-Process -FilePath $editorExe -ArgumentList "`"$($file.FullName)`"" `
                    -WindowStyle Minimized -PassThru

                # Wait for main window to appear
                Write-Host "waiting for window... " -NoNewline
                $hWnd = $proc.MainWindowHandle
                $waited = 0
                $maxWait = $WindowTimeoutSeconds * 2  # poll every 500ms
                while ($hWnd -eq [IntPtr]::Zero -and $waited -lt $maxWait) {
                    Start-Sleep -Milliseconds 500
                    $proc.Refresh()
                    $hWnd = $proc.MainWindowHandle
                    $waited++
                }

                if ($hWnd -eq [IntPtr]::Zero) {
                    Write-Host "FAIL (no window handle after $WindowTimeoutSeconds seconds)"
                    # Try finding by process name as fallback
                    $fallbackProc = Get-Process -Name "*Graphics*Editor*" -ErrorAction SilentlyContinue | 
                        Where-Object { $_.Id -eq $proc.Id }
                    if ($fallbackProc -and $fallbackProc.MainWindowHandle -ne [IntPtr]::Zero) {
                        $hWnd = $fallbackProc.MainWindowHandle
                        Write-Host "     fallback: found handle via Get-Process"
                    }
                }

                if ($hWnd -eq [IntPtr]::Zero) {
                    Write-Host "FAIL (no window)"
                    if (-not $proc.HasExited) { $proc.Kill() }
                    $failed++
                    continue
                }

                # Hide the window immediately
                Write-Host "hiding... " -NoNewline
                [Win32Capture]::ShowWindowAsync($hWnd, [Win32Capture]::SW_HIDE) | Out-Null

                # Wait for rendering to complete
                Write-Host "rendering ($RenderDelaySeconds sec)... " -NoNewline
                Start-Sleep -Seconds $RenderDelaySeconds

        # Capture window content
        $bmp = [Win32Capture]::CaptureWindow($hWnd)
        if ($bmp -eq $null) {
            Write-Host "FAIL (blank capture)"
            if (-not $proc.HasExited) { $proc.Kill() }
            $failed++
            continue
        }

        # Check if image is blank (all-white or near-empty)
        $pixelCount = $bmp.Width * $bmp.Height
        $totalArgb = 0L
        for ($y = 0; $y -lt [Math]::Min($bmp.Height, 10); $y++) {
            for ($x = 0; $x -lt [Math]::Min($bmp.Width, 10); $x++) {
                $px = $bmp.GetPixel($x, $y)
                $totalArgb += $px.ToArgb()
            }
        }
        # If sampled pixels are all same = likely blank/error state
        $avgArgbFrac = [double]$totalArgb / 100.0
        $samplePoints = @()
        $stepX = [Math]::Max(1, [int]($bmp.Width / 10))
        $stepY = [Math]::Max(1, [int]($bmp.Height / 10))
        for ($x = 0; $x -lt $bmp.Width; $x += $stepX) {
            for ($y = 0; $y -lt $bmp.Height; $y += $stepY) {
                $samplePoints += $bmp.GetPixel($x, $y).ToArgb()
            }
        }
        $uniqueColors = ($samplePoints | Select-Object -Unique).Count
        if ($uniqueColors -le 3) {
            Write-Host "WARN (blank/solid image, $uniqueColors unique colors)"
            # Try once more with visible window
            [Win32Capture]::ShowWindowAsync($hWnd, [Win32Capture]::SW_SHOWMINIMIZED) | Out-Null
            Start-Sleep -Milliseconds 1500
            $bmp.Dispose()
            $bmp2 = [Win32Capture]::CaptureWindow($hWnd)
            if ($bmp2 -ne $null) {
                $bmp2.Save($outFile, [System.Drawing.Imaging.ImageFormat]::Png)
                $bmp2.Dispose()
                Write-Host "OK (retry visible)"
                $success++
                if (-not $proc.HasExited) { $proc.Kill() }
                continue
            }
        }

        # Save
        $bmp.Save($outFile, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        Write-Host "OK ($($bmp.Width)x$($bmp.Height))"

        # Close editor
        if (-not $proc.HasExited) {
            [Win32Capture]::SendMessage($hWnd, [Win32Capture]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
            # Wait up to 10s for clean exit, then force kill
            $waitResult = $proc.WaitForExit(10000)
            if (-not $waitResult) {
                $proc.Kill()
                Start-Sleep -Milliseconds 500
            }
        }

        $success++
    }
    catch {
        Write-Host "FAIL ($($_.Exception.Message))"
        $failed++
        # Clean up any lingering process
        Get-Process -Name "*Graphics*Editor*" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "Done: $success captured, $failed failed"