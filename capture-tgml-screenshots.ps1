<#
.TGML Screenshot Capture Script — simple approach.
Launches editor for each file, captures after full render, closes.

Usage:
    .\capture-tgml-screenshots.ps1 -InputPath "C:\TGML\Graphics"
    .\capture-tgml-screenshots.ps1 -InputPath "C:\TGML\file.tgml" -OutputPath "C:\out"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,

    [string]$EditorPath = "",

    [string]$OutputPath = "screenshots",

    [int]$RenderDelaySeconds = 5,

    [int]$WindowTimeoutSeconds = 30
)

# ─── Win32 API definitions via C# ──────────────────────────────────────────
Add-Type -ReferencedAssemblies "System.Drawing" -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class Win32Capture
{
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, int nFlags);

    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    public const int WM_CLOSE = 0x0010;

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    public static Bitmap CaptureWindow(IntPtr hWnd)
    {
        RECT rect;
        if (!GetWindowRect(hWnd, out rect)) return null;
        int w = rect.Right - rect.Left;
        int h = rect.Bottom - rect.Top;
        if (w <= 0 || h <= 0) return null;

        Bitmap bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
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
        # Launch editor — window opens normally
        $proc = Start-Process -FilePath $editorExe `
            -ArgumentList "`"$($file.FullName)`"" `
            -WindowStyle Normal -PassThru

        # Wait for main window handle
        $hWnd = [IntPtr]::Zero
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($hWnd -eq [IntPtr]::Zero -and $sw.Elapsed.TotalSeconds -lt $WindowTimeoutSeconds) {
            if ($proc.HasExited) { break }
            $proc.Refresh()
            $hWnd = $proc.MainWindowHandle
            if ($hWnd -eq [IntPtr]::Zero) {
                Start-Sleep -Milliseconds 200
            }
        }

        if ($hWnd -eq [IntPtr]::Zero) {
            Write-Host "FAIL (no window)"
            if (-not $proc.HasExited) { $proc.Kill() }
            $failed++
            continue
        }

        # Let TGML content render
        Start-Sleep -Seconds $RenderDelaySeconds

        # Capture
        $bmp = [Win32Capture]::CaptureWindow($hWnd)
        if ($bmp -eq $null) {
            Write-Host "FAIL (blank capture)"
            if (-not $proc.HasExited) { $proc.Kill() }
            $failed++
            continue
        }

        $bmp.Save($outFile, [System.Drawing.Imaging.ImageFormat]::Png)
        $dim = "($($bmp.Width)x$($bmp.Height))"
        $bmp.Dispose()

        # Close editor
        if (-not $proc.HasExited) {
            [Win32Capture]::SendMessage($hWnd, [Win32Capture]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
            $closed = $proc.WaitForExit(10000)
            if (-not $closed) { $proc.Kill() }
        }

        Write-Host "OK $dim"
        $success++
    }
    catch {
        Write-Host "FAIL ($($_.Exception.Message))"
        $failed++
        Get-Process -Name "*Graphics*Editor*" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

Get-Process -Name "*Graphics*Editor*" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Write-Host "Done: $success captured, $failed failed"