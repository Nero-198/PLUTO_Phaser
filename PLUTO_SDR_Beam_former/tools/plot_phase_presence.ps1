[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Ch1MeasurementCsv,
    [Parameter(Mandatory)][string]$Ch1SummaryCsv,
    [Parameter(Mandatory)][string]$Ch2MeasurementCsv,
    [Parameter(Mandatory)][string]$Ch2SummaryCsv,
    [Parameter(Mandatory)][string]$OutputPng
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing.Common

$ch1Measurements = @(Import-Csv -LiteralPath $Ch1MeasurementCsv)
$ch2Measurements = @(Import-Csv -LiteralPath $Ch2MeasurementCsv)
$ch1Summary = @(Import-Csv -LiteralPath $Ch1SummaryCsv)
$ch2Summary = @(Import-Csv -LiteralPath $Ch2SummaryCsv)
if ($ch1Measurements.Count -eq 0 -or $ch2Measurements.Count -eq 0) {
    throw 'Both channel measurement CSV files must contain data.'
}

function Wrap-Degrees {
    param([double]$Degrees)
    while ($Degrees -ge 180.0) { $Degrees -= 360.0 }
    while ($Degrees -lt -180.0) { $Degrees += 360.0 }
    return $Degrees
}

$ch1Errors = @(
    $ch1Summary | ForEach-Object {
        $commanded = [double]$_.commanded_phase_deg
        [pscustomobject]@{
            commanded_phase_deg = $commanded
            error_deg = Wrap-Degrees (
                [double]$_.measured_delta_mean_deg - $commanded)
        }
    }
)
$ch2Errors = @(
    $ch2Summary | ForEach-Object {
        $commanded = [double]$_.commanded_phase_deg
        [pscustomobject]@{
            commanded_phase_deg = $commanded
            error_deg = Wrap-Degrees (
                [double]$_.measured_delta_mean_deg - $commanded)
        }
    }
)
$maximumError = (
    @($ch1Errors + $ch2Errors) |
        ForEach-Object { [Math]::Abs($_.error_deg) } |
        Measure-Object -Maximum
).Maximum
$errorLimit = [Math]::Max(10.0, [Math]::Ceiling($maximumError / 10.0) * 10.0)
$responseConfirmed = (
    ($ch1Summary | ForEach-Object {
        [Math]::Abs([double]$_.measured_delta_mean_deg)
    } | Measure-Object -Maximum).Maximum -gt 45.0
) -and (
    ($ch2Summary | ForEach-Object {
        [Math]::Abs([double]$_.measured_delta_mean_deg)
    } | Measure-Object -Maximum).Maximum -gt 45.0
)

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
$brushWarning = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(175, 65, 55))
$penGrid = [Drawing.Pen]::new([Drawing.Color]::FromArgb(220, 224, 229), 1)
$penAxis = [Drawing.Pen]::new([Drawing.Color]::FromArgb(90, 98, 108), 2)
$penCh1 = [Drawing.Pen]::new([Drawing.Color]::FromArgb(26, 115, 232), 4)
$penCh2 = [Drawing.Pen]::new([Drawing.Color]::FromArgb(230, 126, 34), 4)
$penExpected = [Drawing.Pen]::new([Drawing.Color]::FromArgb(130, 138, 148), 3)
$penExpected.DashStyle = [Drawing.Drawing2D.DashStyle]::Dash
$brushCh1 = [Drawing.SolidBrush]::new($penCh1.Color)
$brushCh2 = [Drawing.SolidBrush]::new($penCh2.Color)

$upper = [Drawing.RectangleF]::new(130, 175, 1370, 395)
$lower = [Drawing.RectangleF]::new(130, 700, 1370, 205)
$xMin = 0.0
$xMax = 270.0
$upperMin = -200.0
$upperMax = 200.0
$lowerMin = -$errorLimit
$lowerMax = $errorLimit

function Convert-UpperX {
    param([double]$Value)
    return [single]($upper.Left + ($Value - $xMin) / ($xMax - $xMin) * $upper.Width)
}

function Convert-UpperY {
    param([double]$Value)
    return [single]($upper.Top +
        ($upperMax - $Value) / ($upperMax - $upperMin) * $upper.Height)
}

function Convert-LowerX {
    param([double]$Value)
    return [single]($lower.Left + ($Value - $xMin) / ($xMax - $xMin) * $lower.Width)
}

function Convert-LowerY {
    param([double]$Value)
    return [single]($lower.Top +
        ($lowerMax - $Value) / ($lowerMax - $lowerMin) * $lower.Height)
}

function Draw-CenteredText {
    param(
        [string]$Text,
        [Drawing.Font]$Font,
        [Drawing.Brush]$Brush,
        [single]$CenterX,
        [single]$Y
    )
    $size = $graphics.MeasureString($Text, $Font)
    $graphics.DrawString($Text, $Font, $Brush, $CenterX - $size.Width / 2, $Y)
}

try {
    $graphics.DrawString(
        'MAPS phase-shifter verification at 2.4 GHz',
        $fontTitle, $brushText, 130, 22)
    $graphics.DrawString(
        (
            'Simultaneous PLUTO Rx1/Rx2 complex-IQ comparison | ' +
            "CH1: $($ch1Measurements.Count) captures | " +
            "CH2: $($ch2Measurements.Count) captures"
        ),
        $fontSubtitle, $brushMuted, 130, 72)
    $resultText = if ($responseConfirmed) {
        'Result: RF phase response confirmed on CH1 and CH2'
    } else {
        'Result: no commanded-state separation detected'
    }
    $resultBrush = if ($responseConfirmed) { $brushText } else { $brushWarning }
    $graphics.DrawString($resultText, $fontLegend, $resultBrush, 130, 112)

    foreach ($value in @(-180, -90, 0, 90, 180)) {
        $y = Convert-UpperY $value
        $linePen = if ($value -eq 0) { $penAxis } else { $penGrid }
        $graphics.DrawLine($linePen, $upper.Left, $y, $upper.Right, $y)
        $label = [string]$value
        $size = $graphics.MeasureString($label, $fontTick)
        $graphics.DrawString(
            $label, $fontTick, $brushMuted,
            $upper.Left - $size.Width - 14, $y - $size.Height / 2)
    }
    foreach ($value in @(0, 90, 180, 270)) {
        $x = Convert-UpperX $value
        $graphics.DrawLine($penGrid, $x, $upper.Top, $x, $upper.Bottom)
        Draw-CenteredText ([string]$value) $fontTick $brushMuted $x ($upper.Bottom + 10)
    }
    $graphics.DrawRectangle(
        $penAxis, [single]$upper.Left, [single]$upper.Top,
        [single]$upper.Width, [single]$upper.Height)

    $expectedValues = @(
        [pscustomobject]@{ x = 0.0; y = 0.0 },
        [pscustomobject]@{ x = 90.0; y = 90.0 },
        [pscustomobject]@{ x = 180.0; y = 180.0 },
        [pscustomobject]@{ x = 270.0; y = -90.0 }
    )
    $expectedPoints = [Drawing.PointF[]]@(
        $expectedValues | ForEach-Object {
            [Drawing.PointF]::new(
                (Convert-UpperX $_.x), (Convert-UpperY $_.y))
        })
    $graphics.DrawLines($penExpected, $expectedPoints)

    $ch1Points = [Drawing.PointF[]]@(
        $ch1Summary | ForEach-Object {
            [Drawing.PointF]::new(
                (Convert-UpperX ([double]$_.commanded_phase_deg)),
                (Convert-UpperY ([double]$_.measured_delta_mean_deg)))
        })
    $ch2Points = [Drawing.PointF[]]@(
        $ch2Summary | ForEach-Object {
            [Drawing.PointF]::new(
                (Convert-UpperX ([double]$_.commanded_phase_deg)),
                (Convert-UpperY ([double]$_.measured_delta_mean_deg)))
        })
    $graphics.DrawLines($penCh1, $ch1Points)
    $graphics.DrawLines($penCh2, $ch2Points)
    foreach ($point in $ch1Points) {
        $graphics.FillEllipse($brushCh1, $point.X - 6, $point.Y - 6, 12, 12)
    }
    foreach ($point in $ch2Points) {
        $graphics.FillEllipse($brushCh2, $point.X - 6, $point.Y - 6, 12, 12)
    }

    $graphics.DrawString(
        'Measured phase change (degrees)',
        $fontAxis, $brushText, 130, 143)
    Draw-CenteredText 'Commanded phase (degrees)' $fontAxis $brushText 815 615

    $legendX = 1080
    $legendY = 140
    $graphics.DrawLine($penExpected, $legendX, $legendY, $legendX + 45, $legendY)
    $graphics.DrawString('Nominal reference', $fontLegend, $brushText, $legendX + 57, $legendY - 13)
    $graphics.DrawLine($penCh1, $legendX, $legendY + 32, $legendX + 45, $legendY + 32)
    $graphics.DrawString('CH1 measured', $fontLegend, $brushText, $legendX + 57, $legendY + 19)
    $graphics.DrawLine($penCh2, $legendX + 245, $legendY + 32, $legendX + 290, $legendY + 32)
    $graphics.DrawString('CH2 measured', $fontLegend, $brushText, $legendX + 302, $legendY + 19)

    foreach ($value in @(
        (-$errorLimit), (-$errorLimit / 2.0), 0.0,
        ($errorLimit / 2.0), $errorLimit
    )) {
        $y = Convert-LowerY $value
        $linePen = if ([Math]::Abs($value) -lt 1.0e-9) { $penAxis } else { $penGrid }
        $graphics.DrawLine($linePen, $lower.Left, $y, $lower.Right, $y)
        $label = $value.ToString('0.0')
        $size = $graphics.MeasureString($label, $fontTick)
        $graphics.DrawString(
            $label, $fontTick, $brushMuted,
            $lower.Left - $size.Width - 14, $y - $size.Height / 2)
    }
    foreach ($commanded in @(0.0, 90.0, 180.0, 270.0)) {
        $x = Convert-LowerX $commanded
        $graphics.DrawLine($penGrid, $x, $lower.Top, $x, $lower.Bottom)
        Draw-CenteredText ([string][Math]::Round($commanded)) `
            $fontTick $brushMuted $x ($lower.Bottom + 8)
    }
    $graphics.DrawRectangle(
        $penAxis, [single]$lower.Left, [single]$lower.Top,
        [single]$lower.Width, [single]$lower.Height)

    $ch1NoisePoints = [Drawing.PointF[]]@(
        $ch1Errors | ForEach-Object {
            [Drawing.PointF]::new(
                (Convert-LowerX ([double]$_.commanded_phase_deg)),
                (Convert-LowerY ([double]$_.error_deg)))
        })
    $graphics.DrawLines($penCh1, $ch1NoisePoints)
    foreach ($point in $ch1NoisePoints) {
        $graphics.FillEllipse($brushCh1, $point.X - 3, $point.Y - 3, 6, 6)
    }

    $ch2NoisePoints = [Drawing.PointF[]]@(
        $ch2Errors | ForEach-Object {
            [Drawing.PointF]::new(
                (Convert-LowerX ([double]$_.commanded_phase_deg)),
                (Convert-LowerY ([double]$_.error_deg)))
        })
    $graphics.DrawLines($penCh2, $ch2NoisePoints)
    foreach ($point in $ch2NoisePoints) {
        $graphics.FillEllipse($brushCh2, $point.X - 5, $point.Y - 5, 10, 10)
    }

    $graphics.DrawString(
        'Measured minus commanded phase (degrees)',
        $fontAxis, $brushText, 130, 665)
    Draw-CenteredText 'Commanded phase (degrees)' $fontAxis $brushText 815 942
    $ch1ErrorMinimum = ($ch1Errors.error_deg | Measure-Object -Minimum).Minimum
    $ch1ErrorMaximum = ($ch1Errors.error_deg | Measure-Object -Maximum).Maximum
    $ch2ErrorMinimum = ($ch2Errors.error_deg | Measure-Object -Minimum).Minimum
    $ch2ErrorMaximum = ($ch2Errors.error_deg | Measure-Object -Maximum).Maximum
    $footerText = (
        (
            'CH1 error range: {0:+0.00;-0.00;0.00} to {1:+0.00;-0.00;0.00} deg | ' +
            'CH2 error range: {2:+0.00;-0.00;0.00} to {3:+0.00;-0.00;0.00} deg | clipped samples: 0'
        ) -f $ch1ErrorMinimum, $ch1ErrorMaximum,
            $ch2ErrorMinimum, $ch2ErrorMaximum
    )
    $graphics.DrawString(
        $footerText, $fontNote, $brushMuted, 130, 965)

    $bitmap.Save($OutputPng, [Drawing.Imaging.ImageFormat]::Png)
}
finally {
    foreach ($resource in @(
        $fontTitle, $fontSubtitle, $fontAxis, $fontTick, $fontLegend, $fontNote,
        $brushText, $brushMuted, $brushWarning, $brushCh1, $brushCh2,
        $penGrid, $penAxis, $penCh1, $penCh2, $penExpected, $graphics, $bitmap
    )) {
        if ($null -ne $resource) { $resource.Dispose() }
    }
}

Write-Host "Saved graph: $OutputPng"
