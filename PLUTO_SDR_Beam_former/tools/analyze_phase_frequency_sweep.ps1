[CmdletBinding()]
param(
    [string]$SweepRoot = "captures/pluto_phase_frequency_sweep_20260727",
    [string]$Ch1At2400 = "captures/pluto_phase_full_20260727_ch1_after_swap",
    [string]$Ch2At2400 = "captures/pluto_phase_full_20260727_ch2_after_swap",
    [string]$OutputDirectory = "reports/phase_frequency_sweep_20260727"
)

$ErrorActionPreference = "Stop"
$Invariant = [System.Globalization.CultureInfo]::InvariantCulture

function Convert-ToDouble {
    param([Parameter(Mandatory = $true)][string]$Value)
    return [double]::Parse($Value, $Invariant)
}

function Format-Number {
    param(
        [Parameter(Mandatory = $true)][double]$Value,
        [string]$Format = "0.000"
    )
    return $Value.ToString($Format, $Invariant)
}

function Escape-Xml {
    param([Parameter(Mandatory = $true)][string]$Value)
    return [System.Security.SecurityElement]::Escape($Value)
}

function Convert-ToMeasuredMagnitude {
    param(
        [double]$WrappedMeasuredDeltaDeg,
        [double]$CommandedPhaseDeg
    )

    # MAPS-010144 shifts the measured RF phase in the negative direction.
    # Select the equivalent signed angle nearest -commanded, then report its magnitude.
    $targetSigned = -$CommandedPhaseDeg
    $signed = $WrappedMeasuredDeltaDeg
    while (($signed - $targetSigned) -gt 180.0) { $signed -= 360.0 }
    while (($signed - $targetSigned) -lt -180.0) { $signed += 360.0 }
    return -$signed
}

function Get-HeatColor {
    param(
        [double]$Value,
        [double]$Limit
    )

    $normalized = [Math]::Max(-1.0, [Math]::Min(1.0, $Value / $Limit))
    $strength = [Math]::Abs($normalized)
    if ($normalized -ge 0.0) {
        $r = 255
        $g = [int][Math]::Round(248.0 - 150.0 * $strength)
        $b = [int][Math]::Round(245.0 - 150.0 * $strength)
    } else {
        $r = [int][Math]::Round(245.0 - 145.0 * $strength)
        $g = [int][Math]::Round(248.0 - 100.0 * $strength)
        $b = 255
    }
    return "#{0:X2}{1:X2}{2:X2}" -f $r, $g, $b
}

function Get-ScalePoint {
    param(
        [double]$Value,
        [double]$Minimum,
        [double]$Maximum,
        [double]$PixelMinimum,
        [double]$PixelMaximum
    )

    if ($Maximum -eq $Minimum) { return ($PixelMinimum + $PixelMaximum) / 2.0 }
    return $PixelMinimum + (($Value - $Minimum) / ($Maximum - $Minimum)) * ($PixelMaximum - $PixelMinimum)
}

$sourceMap = @()
foreach ($frequencyMHz in 2300, 2500, 2700, 3000, 3300, 3500, 3800) {
    foreach ($channel in 1, 2) {
        $sourceMap += [pscustomobject]@{
            FrequencyMHz = $frequencyMHz
            Channel = $channel
            Directory = Join-Path $SweepRoot ("f{0}_ch{1}" -f $frequencyMHz, $channel)
        }
    }
}
$sourceMap += [pscustomobject]@{ FrequencyMHz = 2400; Channel = 1; Directory = $Ch1At2400 }
$sourceMap += [pscustomobject]@{ FrequencyMHz = 2400; Channel = 2; Directory = $Ch2At2400 }
$sourceMap = $sourceMap | Sort-Object FrequencyMHz, Channel

$points = @()
$frequencyRows = @()
foreach ($source in $sourceMap) {
    $summaryPath = Join-Path $source.Directory "phase_presence_summary.csv"
    $measurementPath = Join-Path $source.Directory "phase_presence_measurements.csv"
    if (-not (Test-Path -LiteralPath $summaryPath)) {
        throw "Missing summary: $summaryPath"
    }
    if (-not (Test-Path -LiteralPath $measurementPath)) {
        throw "Missing measurements: $measurementPath"
    }

    $summary = @(Import-Csv -LiteralPath $summaryPath)
    $measurements = @(Import-Csv -LiteralPath $measurementPath)
    $zero = $summary | Where-Object { (Convert-ToDouble $_.commanded_phase_deg) -eq 0.0 } | Select-Object -First 1
    if ($null -eq $zero) { throw "No 0-degree reference in $summaryPath" }

    $zeroTone = if ($source.Channel -eq 1) {
        Convert-ToDouble $zero.ch1_tone_mean_dbfs
    } else {
        Convert-ToDouble $zero.ch2_tone_mean_dbfs
    }

    $sourcePoints = @()
    foreach ($row in $summary) {
        $commanded = Convert-ToDouble $row.commanded_phase_deg
        $wrapped = Convert-ToDouble $row.measured_delta_mean_deg
        $magnitude = Convert-ToMeasuredMagnitude $wrapped $commanded
        $tone = if ($source.Channel -eq 1) {
            Convert-ToDouble $row.ch1_tone_mean_dbfs
        } else {
            Convert-ToDouble $row.ch2_tone_mean_dbfs
        }
        $point = [pscustomobject]@{
            frequency_ghz = $source.FrequencyMHz / 1000.0
            channel = $source.Channel
            commanded_phase_deg = $commanded
            measured_phase_magnitude_deg = $magnitude
            phase_error_deg = $magnitude - $commanded
            tone_level_dbfs = $tone
            amplitude_delta_db = $tone - $zeroTone
            circular_std_deg = Convert-ToDouble $row.circular_std_deg
            sample_count = [int]$row.sample_count
            source_directory = $source.Directory.Replace("\", "/")
        }
        $points += $point
        $sourcePoints += $point
    }

    $nonZero = @($sourcePoints | Where-Object { $_.commanded_phase_deg -gt 0.0 })
    $rms = [Math]::Sqrt((($nonZero | ForEach-Object { $_.phase_error_deg * $_.phase_error_deg } | Measure-Object -Average).Average))
    $maxAbs = ($nonZero | ForEach-Object { [Math]::Abs($_.phase_error_deg) } | Measure-Object -Maximum).Maximum
    $meanError = ($nonZero | Measure-Object -Property phase_error_deg -Average).Average
    $toneMin = ($sourcePoints | Measure-Object -Property tone_level_dbfs -Minimum).Minimum
    $toneMax = ($sourcePoints | Measure-Object -Property tone_level_dbfs -Maximum).Maximum
    $maxRepeatStd = ($sourcePoints | Measure-Object -Property circular_std_deg -Maximum).Maximum
    $clippedSamples = if ($source.Channel -eq 1) {
        ($measurements | Measure-Object -Property ch1_clipped_samples -Sum).Sum
    } else {
        ($measurements | Measure-Object -Property ch2_clipped_samples -Sum).Sum
    }

    $frequencyRows += [pscustomobject]@{
        frequency_ghz = $source.FrequencyMHz / 1000.0
        channel = $source.Channel
        rms_phase_error_deg = $rms
        max_abs_phase_error_deg = $maxAbs
        mean_phase_error_deg = $meanError
        amplitude_span_db = $toneMax - $toneMin
        maximum_repeat_std_deg = $maxRepeatStd
        minimum_tone_level_dbfs = $toneMin
        clipped_sample_count = [int]$clippedSamples
        source_directory = $source.Directory.Replace("\", "/")
    }
}

$phaseRows = @()
foreach ($group in ($points | Group-Object channel, commanded_phase_deg)) {
    $items = @($group.Group)
    $phaseRows += [pscustomobject]@{
        channel = $items[0].channel
        commanded_phase_deg = $items[0].commanded_phase_deg
        mean_phase_error_deg = ($items | Measure-Object -Property phase_error_deg -Average).Average
        rms_phase_error_deg = [Math]::Sqrt((($items | ForEach-Object { $_.phase_error_deg * $_.phase_error_deg } | Measure-Object -Average).Average))
        max_abs_phase_error_deg = ($items | ForEach-Object { [Math]::Abs($_.phase_error_deg) } | Measure-Object -Maximum).Maximum
        minimum_phase_error_deg = ($items | Measure-Object -Property phase_error_deg -Minimum).Minimum
        maximum_phase_error_deg = ($items | Measure-Object -Property phase_error_deg -Maximum).Maximum
        frequency_count = $items.Count
    }
}
$phaseRows = $phaseRows | Sort-Object channel, commanded_phase_deg

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$points |
    Sort-Object frequency_ghz, channel, commanded_phase_deg |
    Export-Csv -LiteralPath (Join-Path $OutputDirectory "phase_error_all_points.csv") -NoTypeInformation -Encoding utf8
$frequencyRows |
    Sort-Object frequency_ghz, channel |
    Export-Csv -LiteralPath (Join-Path $OutputDirectory "frequency_summary.csv") -NoTypeInformation -Encoding utf8
$phaseRows |
    Export-Csv -LiteralPath (Join-Path $OutputDirectory "phase_state_summary.csv") -NoTypeInformation -Encoding utf8

# Heatmap: every requested frequency, channel, and phase state is visible at once.
$svg = [System.Text.StringBuilder]::new()
$width = 1640
$height = 880
$left = 120
$top = 92
$cellW = 88
$cellH = 38
$panelGap = 105
$heatLimit = [Math]::Ceiling(($points | ForEach-Object { [Math]::Abs($_.phase_error_deg) } | Measure-Object -Maximum).Maximum)
[void]$svg.AppendLine("<svg xmlns=`"http://www.w3.org/2000/svg`" width=`"$width`" height=`"$height`" viewBox=`"0 0 $width $height`">")
[void]$svg.AppendLine("<rect width=`"100%`" height=`"100%`" fill=`"#ffffff`"/>")
[void]$svg.AppendLine("<style>text{font-family:'Segoe UI',Arial,sans-serif;fill:#172033}.title{font-size:25px;font-weight:600}.sub{font-size:14px;fill:#526078}.axis{font-size:12px}.cell{font-size:12px;font-weight:600}.panel{font-size:18px;font-weight:600}.grid{stroke:#d8dee9;stroke-width:1}</style>")
[void]$svg.AppendLine("<text x=`"$left`" y=`"34`" class=`"title`">MAPS phase error by frequency and commanded phase</text>")
[void]$svg.AppendLine("<text x=`"$left`" y=`"58`" class=`"sub`">Error = measured phase-shift magnitude - commanded phase; values in degrees</text>")

foreach ($channel in 1, 2) {
    $panelTop = $top + ($channel - 1) * (8 * $cellH + $panelGap)
    [void]$svg.AppendLine("<text x=`"20`" y=`"$($panelTop + 20)`" class=`"panel`">CH$channel</text>")
    $commands = @(0..15 | ForEach-Object { $_ * 22.5 })
    for ($column = 0; $column -lt $commands.Count; $column++) {
        $x = $left + $column * $cellW
        $label = Format-Number $commands[$column] "0.#"
        [void]$svg.AppendLine("<text x=`"$($x + $cellW / 2)`" y=`"$($panelTop - 10)`" class=`"axis`" text-anchor=`"middle`">$label°</text>")
    }
    $frequencies = @(2.3, 2.4, 2.5, 2.7, 3.0, 3.3, 3.5, 3.8)
    for ($rowIndex = 0; $rowIndex -lt $frequencies.Count; $rowIndex++) {
        $frequency = $frequencies[$rowIndex]
        $y = $panelTop + $rowIndex * $cellH
        $frequencyLabel = Format-Number $frequency "0.0"
        [void]$svg.AppendLine("<text x=`"$($left - 14)`" y=`"$($y + 24)`" class=`"axis`" text-anchor=`"end`">$frequencyLabel GHz</text>")
        for ($column = 0; $column -lt $commands.Count; $column++) {
            $command = $commands[$column]
            $point = $points | Where-Object {
                $_.channel -eq $channel -and
                [Math]::Abs($_.frequency_ghz - $frequency) -lt 0.0001 -and
                [Math]::Abs($_.commanded_phase_deg - $command) -lt 0.001
            } | Select-Object -First 1
            $x = $left + $column * $cellW
            $color = Get-HeatColor $point.phase_error_deg $heatLimit
            $value = Format-Number $point.phase_error_deg "+0.0;-0.0;0.0"
            [void]$svg.AppendLine("<rect x=`"$x`" y=`"$y`" width=`"$cellW`" height=`"$cellH`" fill=`"$color`" class=`"grid`"/>")
            [void]$svg.AppendLine("<text x=`"$($x + $cellW / 2)`" y=`"$($y + 24)`" class=`"cell`" text-anchor=`"middle`">$value</text>")
        }
    }
}
[void]$svg.AppendLine("</svg>")
[System.IO.File]::WriteAllText((Join-Path $OutputDirectory "phase_error_heatmap.svg"), $svg.ToString(), [System.Text.UTF8Encoding]::new($false))

# Frequency summary plot.
$svg = [System.Text.StringBuilder]::new()
$width = 1500
$height = 930
$plotLeft = 105
$plotRight = 1410
$plotWidth = $plotRight - $plotLeft
$frequencies = @(2.3, 2.4, 2.5, 2.7, 3.0, 3.3, 3.5, 3.8)
$phaseTop = 105
$phaseBottom = 465
$ampTop = 575
$ampBottom = 835
$phaseMax = [Math]::Ceiling(($frequencyRows | Measure-Object -Property max_abs_phase_error_deg -Maximum).Maximum)
$ampMax = [Math]::Max(1.0, [Math]::Ceiling(($frequencyRows | Measure-Object -Property amplitude_span_db -Maximum).Maximum))
[void]$svg.AppendLine("<svg xmlns=`"http://www.w3.org/2000/svg`" width=`"$width`" height=`"$height`" viewBox=`"0 0 $width $height`">")
[void]$svg.AppendLine("<rect width=`"100%`" height=`"100%`" fill=`"#ffffff`"/>")
[void]$svg.AppendLine("<style>text{font-family:'Segoe UI',Arial,sans-serif;fill:#172033}.title{font-size:25px;font-weight:600}.sub{font-size:14px;fill:#526078}.axis{font-size:13px}.label{font-size:14px;font-weight:600}.grid{stroke:#d8dee9;stroke-width:1}.line1{fill:none;stroke:#1565c0;stroke-width:3}.line2{fill:none;stroke:#ef6c00;stroke-width:3}.dash{stroke-dasharray:9 6}.dot1{fill:#1565c0}.dot2{fill:#ef6c00}</style>")
[void]$svg.AppendLine("<text x=`"$plotLeft`" y=`"35`" class=`"title`">Frequency dependence of phase accuracy and amplitude variation</text>")
[void]$svg.AppendLine("<text x=`"$plotLeft`" y=`"60`" class=`"sub`">Solid = RMS phase error; dashed = maximum absolute phase error; lower panel = amplitude span over 16 phase states</text>")

foreach ($plot in @(
    @{ Top = $phaseTop; Bottom = $phaseBottom; Max = $phaseMax; Label = "Phase error (deg)"; Step = 1 },
    @{ Top = $ampTop; Bottom = $ampBottom; Max = $ampMax; Label = "Amplitude span (dB)"; Step = 0.5 }
)) {
    [void]$svg.AppendLine("<line x1=`"$plotLeft`" y1=`"$($plot.Bottom)`" x2=`"$plotRight`" y2=`"$($plot.Bottom)`" class=`"grid`"/>")
    [void]$svg.AppendLine("<line x1=`"$plotLeft`" y1=`"$($plot.Top)`" x2=`"$plotLeft`" y2=`"$($plot.Bottom)`" class=`"grid`"/>")
    for ($tick = 0.0; $tick -le $plot.Max + 0.0001; $tick += $plot.Step) {
        $y = Get-ScalePoint $tick 0.0 $plot.Max $plot.Bottom $plot.Top
        [void]$svg.AppendLine("<line x1=`"$plotLeft`" y1=`"$y`" x2=`"$plotRight`" y2=`"$y`" class=`"grid`"/>")
        [void]$svg.AppendLine("<text x=`"$($plotLeft - 12)`" y=`"$($y + 5)`" class=`"axis`" text-anchor=`"end`">$(Format-Number $tick '0.#')</text>")
    }
    [void]$svg.AppendLine("<text x=`"25`" y=`"$((($plot.Top + $plot.Bottom) / 2))`" class=`"label`" transform=`"rotate(-90 25 $((($plot.Top + $plot.Bottom) / 2)))`" text-anchor=`"middle`">$($plot.Label)</text>")
}

for ($i = 0; $i -lt $frequencies.Count; $i++) {
    $x = Get-ScalePoint $frequencies[$i] 2.3 3.8 $plotLeft $plotRight
    [void]$svg.AppendLine("<text x=`"$x`" y=`"$($ampBottom + 28)`" class=`"axis`" text-anchor=`"middle`">$(Format-Number $frequencies[$i] '0.0')</text>")
}
[void]$svg.AppendLine("<text x=`"$(($plotLeft + $plotRight) / 2)`" y=`"$($ampBottom + 62)`" class=`"label`" text-anchor=`"middle`">RF frequency (GHz)</text>")

foreach ($channel in 1, 2) {
    $class = if ($channel -eq 1) { "line1" } else { "line2" }
    $dotClass = if ($channel -eq 1) { "dot1" } else { "dot2" }
    foreach ($metric in @(
        @{ Name = "rms_phase_error_deg"; Dashed = $false; Top = $phaseTop; Bottom = $phaseBottom; Max = $phaseMax },
        @{ Name = "max_abs_phase_error_deg"; Dashed = $true; Top = $phaseTop; Bottom = $phaseBottom; Max = $phaseMax },
        @{ Name = "amplitude_span_db"; Dashed = $false; Top = $ampTop; Bottom = $ampBottom; Max = $ampMax }
    )) {
        $coordinates = @()
        foreach ($frequency in $frequencies) {
            $row = $frequencyRows | Where-Object { $_.channel -eq $channel -and [Math]::Abs($_.frequency_ghz - $frequency) -lt 0.0001 } | Select-Object -First 1
            $x = Get-ScalePoint $frequency 2.3 3.8 $plotLeft $plotRight
            $y = Get-ScalePoint $row.($metric.Name) 0.0 $metric.Max $metric.Bottom $metric.Top
            $coordinates += "$(Format-Number $x '0.0'),$(Format-Number $y '0.0')"
        }
        $lineClass = $class + $(if ($metric.Dashed) { " dash" } else { "" })
        [void]$svg.AppendLine("<polyline points=`"$($coordinates -join ' ')`" class=`"$lineClass`"/>")
        foreach ($coordinate in $coordinates) {
            $xy = $coordinate.Split(",")
            [void]$svg.AppendLine("<circle cx=`"$($xy[0])`" cy=`"$($xy[1])`" r=`"4`" class=`"$dotClass`"/>")
        }
    }
}

[void]$svg.AppendLine("<line x1=`"$($plotRight - 300)`" y1=`"85`" x2=`"$($plotRight - 260)`" y2=`"85`" class=`"line1`"/><text x=`"$($plotRight - 250)`" y=`"90`" class=`"axis`">CH1</text>")
[void]$svg.AppendLine("<line x1=`"$($plotRight - 180)`" y1=`"85`" x2=`"$($plotRight - 140)`" y2=`"85`" class=`"line2`"/><text x=`"$($plotRight - 130)`" y=`"90`" class=`"axis`">CH2</text>")
[void]$svg.AppendLine("</svg>")
[System.IO.File]::WriteAllText((Join-Path $OutputDirectory "frequency_summary.svg"), $svg.ToString(), [System.Text.UTF8Encoding]::new($false))

$globalWorst = $points | Sort-Object { [Math]::Abs($_.phase_error_deg) } -Descending | Select-Object -First 1
$globalRmsByChannel = @()
foreach ($channel in 1, 2) {
    $items = @($points | Where-Object { $_.channel -eq $channel -and $_.commanded_phase_deg -gt 0.0 })
    $globalRmsByChannel += [pscustomobject]@{
        channel = $channel
        rms_phase_error_deg = [Math]::Sqrt((($items | ForEach-Object { $_.phase_error_deg * $_.phase_error_deg } | Measure-Object -Average).Average))
        max_abs_phase_error_deg = ($items | ForEach-Object { [Math]::Abs($_.phase_error_deg) } | Measure-Object -Maximum).Maximum
    }
}

[pscustomobject]@{
    OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
    PointCount = $points.Count
    WorstFrequencyGHz = $globalWorst.frequency_ghz
    WorstChannel = $globalWorst.channel
    WorstCommandedPhaseDeg = $globalWorst.commanded_phase_deg
    WorstPhaseErrorDeg = $globalWorst.phase_error_deg
    Ch1RmsPhaseErrorDeg = ($globalRmsByChannel | Where-Object channel -eq 1).rms_phase_error_deg
    Ch2RmsPhaseErrorDeg = ($globalRmsByChannel | Where-Object channel -eq 2).rms_phase_error_deg
    TotalClippedSamples = ($frequencyRows | Measure-Object -Property clipped_sample_count -Sum).Sum
} | Format-List
