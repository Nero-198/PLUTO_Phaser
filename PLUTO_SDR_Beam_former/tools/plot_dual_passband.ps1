[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputCsv,
    [Parameter(Mandatory)][string]$OutputPng
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing.Common

$rows = Import-Csv -LiteralPath $InputCsv
if ($rows.Count -lt 2) {
    throw 'At least two measurement rows are required.'
}

$data = foreach ($row in $rows) {
    [pscustomobject]@{
        frequency_ghz = [double]$row.actual_frequency_mhz / 1000.0
        ch1_relative_db = [double]$row.ch1_relative_db
        ch2_relative_db = [double]$row.ch2_relative_db
        channel_delta_db = [double]$row.channel_delta_db
    }
}

$outputDirectory = Split-Path -Parent $OutputPng
if ($outputDirectory) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$width = 1600
$height = 1000
$bitmap = [Drawing.Bitmap]::new($width, $height)
$graphics = [Drawing.Graphics]::FromImage($bitmap)
$graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.TextRenderingHint = [Drawing.Text.TextRenderingHint]::ClearTypeGridFit
$graphics.Clear([Drawing.Color]::White)

$fontTitle = [Drawing.Font]::new('Segoe UI', 26, [Drawing.FontStyle]::Bold)
$fontSubtitle = [Drawing.Font]::new('Segoe UI', 14)
$fontAxis = [Drawing.Font]::new('Segoe UI', 15, [Drawing.FontStyle]::Bold)
$fontTick = [Drawing.Font]::new('Segoe UI', 12)
$fontLegend = [Drawing.Font]::new('Segoe UI', 13, [Drawing.FontStyle]::Bold)
$fontNote = [Drawing.Font]::new('Segoe UI', 12)
$brushText = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(32, 38, 45))
$brushMuted = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(90, 98, 108))
$penGrid = [Drawing.Pen]::new([Drawing.Color]::FromArgb(220, 224, 229), 1)
$penAxis = [Drawing.Pen]::new([Drawing.Color]::FromArgb(90, 98, 108), 2)
$penCh1 = [Drawing.Pen]::new([Drawing.Color]::FromArgb(26, 115, 232), 4)
$penCh2 = [Drawing.Pen]::new([Drawing.Color]::FromArgb(230, 126, 34), 4)
$penDelta = [Drawing.Pen]::new([Drawing.Color]::FromArgb(90, 70, 180), 3)
$penStep = [Drawing.Pen]::new([Drawing.Color]::FromArgb(120, 128, 138), 2)
$penStep.DashStyle = [Drawing.Drawing2D.DashStyle]::Dash

$upper = [Drawing.RectangleF]::new(120, 170, 1390, 485)
$lower = [Drawing.RectangleF]::new(120, 760, 1390, 145)
$fMin = 1.5
$fMax = 4.5
$upperMin = -25.0
$upperMax = 1.0
$lowerMin = -1.0
$lowerMax = 4.0

function Convert-X {
    param([double]$FrequencyGHz)
    return [single]($upper.Left +
        ($FrequencyGHz - $fMin) / ($fMax - $fMin) * $upper.Width)
}

function Convert-UpperY {
    param([double]$Value)
    return [single]($upper.Top +
        ($upperMax - $Value) / ($upperMax - $upperMin) * $upper.Height)
}

function Convert-LowerY {
    param([double]$Value)
    return [single]($lower.Top +
        ($lowerMax - $Value) / ($lowerMax - $lowerMin) * $lower.Height)
}

try {
    $graphics.DrawString(
        'Dual-channel transmission response: 1.5-4.5 GHz',
        $fontTitle, $brushText, 120, 22)
    $graphics.DrawString(
        'Uncalibrated PLUTO loop-through | 50 MHz steps | external ATT 20 dB | board ATT 0 dB | LNA1/2 ON',
        $fontSubtitle, $brushMuted, 120, 72)

    foreach ($value in @(-25, -20, -15, -10, -5, 0)) {
        $y = Convert-UpperY $value
        $graphics.DrawLine($penGrid, $upper.Left, $y, $upper.Right, $y)
        $label = [string]$value
        $size = $graphics.MeasureString($label, $fontTick)
        $graphics.DrawString(
            $label, $fontTick, $brushMuted,
            $upper.Left - $size.Width - 12, $y - $size.Height / 2)
    }

    foreach ($value in @(-1, 0, 1, 2, 3, 4)) {
        $y = Convert-LowerY $value
        $linePen = if ($value -eq 0) { $penAxis } else { $penGrid }
        $graphics.DrawLine($linePen, $lower.Left, $y, $lower.Right, $y)
        $label = [string]$value
        $size = $graphics.MeasureString($label, $fontTick)
        $graphics.DrawString(
            $label, $fontTick, $brushMuted,
            $lower.Left - $size.Width - 12, $y - $size.Height / 2)
    }

    foreach ($frequency in @(1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5)) {
        $x = Convert-X $frequency
        $graphics.DrawLine($penGrid, $x, $upper.Top, $x, $upper.Bottom)
        $graphics.DrawLine($penGrid, $x, $lower.Top, $x, $lower.Bottom)

        $frequencyLabel = $frequency.ToString('0.0')
        $frequencySize = $graphics.MeasureString($frequencyLabel, $fontTick)
        $graphics.DrawString(
            $frequencyLabel, $fontTick, $brushMuted,
            $x - $frequencySize.Width / 2, $lower.Bottom + 9)

        $omega = 2.0 * [Math]::PI * $frequency
        $omegaLabel = $omega.ToString('0.00')
        $omegaSize = $graphics.MeasureString($omegaLabel, $fontTick)
        $graphics.DrawString(
            $omegaLabel, $fontTick, $brushMuted,
            $x - $omegaSize.Width / 2, $upper.Top - 31)
    }

    $graphics.DrawRectangle(
        $penAxis, [single]$upper.Left, [single]$upper.Top,
        [single]$upper.Width, [single]$upper.Height)
    $graphics.DrawRectangle(
        $penAxis, [single]$lower.Left, [single]$lower.Top,
        [single]$lower.Width, [single]$lower.Height)

    $ch1Points = [Drawing.PointF[]]@(
        $data | ForEach-Object {
            [Drawing.PointF]::new(
                (Convert-X $_.frequency_ghz),
                (Convert-UpperY $_.ch1_relative_db))
        })
    $ch2Points = [Drawing.PointF[]]@(
        $data | ForEach-Object {
            [Drawing.PointF]::new(
                (Convert-X $_.frequency_ghz),
                (Convert-UpperY $_.ch2_relative_db))
        })
    $deltaPoints = [Drawing.PointF[]]@(
        $data | ForEach-Object {
            [Drawing.PointF]::new(
                (Convert-X $_.frequency_ghz),
                (Convert-LowerY $_.channel_delta_db))
        })

    $graphics.DrawLines($penCh1, $ch1Points)
    $graphics.DrawLines($penCh2, $ch2Points)
    $graphics.DrawLines($penDelta, $deltaPoints)

    $stepX = Convert-X 4.025
    $graphics.DrawLine($penStep, $stepX, $upper.Top, $stepX, $upper.Bottom)
    $graphics.DrawString(
        '~5 dB common step near 4.05 GHz',
        $fontNote, $brushMuted, $stepX + 10, $upper.Top + 12)

    $graphics.DrawString(
        'Angular frequency omega (10^9 rad/s)',
        $fontAxis, $brushText, 590, 108)
    $graphics.DrawString(
        'RF frequency f (GHz)',
        $fontAxis, $brushText, 720, 946)
    $graphics.DrawString(
        'Relative received level (dB)',
        $fontAxis, $brushText, 120, 108)
    $graphics.DrawString(
        'CH1 - CH2 (dB)',
        $fontAxis, $brushText, 120, 718)

    $legendX = 1160
    $legendY = 42
    $graphics.DrawLine($penCh1, $legendX, $legendY, $legendX + 45, $legendY)
    $graphics.DrawString('CH1', $fontLegend, $brushText, $legendX + 57, $legendY - 13)
    $graphics.DrawLine($penCh2, $legendX + 145, $legendY, $legendX + 190, $legendY)
    $graphics.DrawString('CH2', $fontLegend, $brushText, $legendX + 202, $legendY - 13)

    $graphics.DrawString(
        'Normalized per channel | CH1 span 21.36 dB | CH2 span 23.67 dB | mean absolute channel difference 1.40 dB',
        $fontNote, $brushMuted, 120, 680)

    $bitmap.Save($OutputPng, [Drawing.Imaging.ImageFormat]::Png)
}
finally {
    foreach ($resource in @(
        $fontTitle, $fontSubtitle, $fontAxis, $fontTick, $fontLegend, $fontNote,
        $brushText, $brushMuted, $penGrid, $penAxis, $penCh1, $penCh2,
        $penDelta, $penStep, $graphics, $bitmap
    )) {
        if ($null -ne $resource) { $resource.Dispose() }
    }
}

Write-Host "Saved graph: $OutputPng"
