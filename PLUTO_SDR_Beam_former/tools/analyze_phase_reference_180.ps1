[CmdletBinding()]
param(
    [string]$InputCsv = "reports/phase_frequency_sweep_20260727/phase_error_all_points.csv",
    [string]$OutputDirectory = "reports/phase_reference_180_20260728"
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

if (-not (Test-Path -LiteralPath $InputCsv)) {
    throw "Input CSV not found: $InputCsv"
}

$inputRows = @(Import-Csv -LiteralPath $InputCsv)
$outputRows = @()

foreach ($group in ($inputRows | Group-Object frequency_ghz, channel)) {
    $items = @($group.Group)
    $reference = $items |
        Where-Object { (Convert-ToDouble $_.commanded_phase_deg) -eq 180.0 } |
        Select-Object -First 1
    if ($null -eq $reference) {
        throw "180-degree state is missing from group $($group.Name)"
    }

    $referenceMeasured = Convert-ToDouble $reference.measured_phase_magnitude_deg
    $referenceError = Convert-ToDouble $reference.phase_error_deg

    foreach ($row in $items) {
        $commanded = Convert-ToDouble $row.commanded_phase_deg
        $measured = Convert-ToDouble $row.measured_phase_magnitude_deg
        $originalError = Convert-ToDouble $row.phase_error_deg
        $relativeCommanded = $commanded - 180.0
        $relativeMeasured = $measured - $referenceMeasured

        $outputRows += [pscustomobject]@{
            frequency_ghz = Convert-ToDouble $row.frequency_ghz
            channel = [int]$row.channel
            absolute_commanded_phase_deg = $commanded
            relative_commanded_from_180_deg = $relativeCommanded
            measured_relative_from_180_deg = $relativeMeasured
            phase_error_from_180_deg = $relativeMeasured - $relativeCommanded
            original_phase_error_from_0_deg = $originalError
            reference_180_measured_magnitude_deg = $referenceMeasured
            reference_180_original_error_deg = $referenceError
            tone_level_dbfs = Convert-ToDouble $row.tone_level_dbfs
            amplitude_delta_from_0_db = Convert-ToDouble $row.amplitude_delta_db
            circular_std_deg = Convert-ToDouble $row.circular_std_deg
            sample_count = [int]$row.sample_count
            source_directory = $row.source_directory
        }
    }
}

$summaryRows = @()
foreach ($group in ($outputRows | Group-Object frequency_ghz, channel)) {
    $items = @($group.Group)
    $reference180Points = @($items | Where-Object { $_.absolute_commanded_phase_deg -ne 180.0 })
    $reference0Points = @($items | Where-Object { $_.absolute_commanded_phase_deg -ne 0.0 })
    $worst180 = $reference180Points |
        Sort-Object { [Math]::Abs($_.phase_error_from_180_deg) } -Descending |
        Select-Object -First 1

    $rms180 = [Math]::Sqrt(
        (($reference180Points |
            ForEach-Object { $_.phase_error_from_180_deg * $_.phase_error_from_180_deg } |
            Measure-Object -Average).Average)
    )
    $rms0 = [Math]::Sqrt(
        (($reference0Points |
            ForEach-Object { $_.original_phase_error_from_0_deg * $_.original_phase_error_from_0_deg } |
            Measure-Object -Average).Average)
    )

    $summaryRows += [pscustomobject]@{
        frequency_ghz = $items[0].frequency_ghz
        channel = $items[0].channel
        rms_error_reference_180_deg = $rms180
        max_abs_error_reference_180_deg = [Math]::Abs($worst180.phase_error_from_180_deg)
        mean_error_reference_180_deg = ($reference180Points |
            Measure-Object -Property phase_error_from_180_deg -Average).Average
        worst_absolute_commanded_phase_deg = $worst180.absolute_commanded_phase_deg
        worst_relative_commanded_phase_deg = $worst180.relative_commanded_from_180_deg
        worst_error_reference_180_deg = $worst180.phase_error_from_180_deg
        rms_error_reference_0_deg = $rms0
        rms_change_180_minus_0_deg = $rms180 - $rms0
        reference_180_original_error_deg = $items[0].reference_180_original_error_deg
    }
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$outputRows |
    Sort-Object frequency_ghz, channel, relative_commanded_from_180_deg |
    Export-Csv -LiteralPath (Join-Path $OutputDirectory "phase_error_reference_180_all_points.csv") `
        -NoTypeInformation -Encoding utf8
$summaryRows |
    Sort-Object frequency_ghz, channel |
    Export-Csv -LiteralPath (Join-Path $OutputDirectory "frequency_summary_reference_180.csv") `
        -NoTypeInformation -Encoding utf8

# Heatmap centered on the 180-degree state.
$svg = [System.Text.StringBuilder]::new()
$width = 1640
$height = 880
$left = 120
$top = 92
$cellW = 88
$cellH = 38
$panelGap = 105
$heatLimit = [Math]::Ceiling(
    ($outputRows |
        ForEach-Object { [Math]::Abs($_.phase_error_from_180_deg) } |
        Measure-Object -Maximum).Maximum
)
[void]$svg.AppendLine("<svg xmlns=`"http://www.w3.org/2000/svg`" width=`"$width`" height=`"$height`" viewBox=`"0 0 $width $height`">")
[void]$svg.AppendLine("<rect width=`"100%`" height=`"100%`" fill=`"#ffffff`"/>")
[void]$svg.AppendLine("<style>text{font-family:'Segoe UI',Arial,sans-serif;fill:#172033}.title{font-size:25px;font-weight:600}.sub{font-size:14px;fill:#526078}.axis{font-size:12px}.cell{font-size:12px;font-weight:600}.panel{font-size:18px;font-weight:600}.grid{stroke:#d8dee9;stroke-width:1}.reference{stroke:#172033;stroke-width:2}</style>")
[void]$svg.AppendLine("<text x=`"$left`" y=`"34`" class=`"title`">MAPS phase error referenced to the 180-degree state</text>")
[void]$svg.AppendLine("<text x=`"$left`" y=`"58`" class=`"sub`">Error = measured relative phase - commanded relative phase; 0 degrees on the horizontal axis is the absolute 180-degree state</text>")

$relativeCommands = @(-180.0, -157.5, -135.0, -112.5, -90.0, -67.5, -45.0, -22.5, 0.0, 22.5, 45.0, 67.5, 90.0, 112.5, 135.0, 157.5)
$frequencies = @(2.3, 2.4, 2.5, 2.7, 3.0, 3.3, 3.5, 3.8)
foreach ($channel in 1, 2) {
    $panelTop = $top + ($channel - 1) * (8 * $cellH + $panelGap)
    [void]$svg.AppendLine("<text x=`"20`" y=`"$($panelTop + 20)`" class=`"panel`">CH$channel</text>")
    for ($column = 0; $column -lt $relativeCommands.Count; $column++) {
        $x = $left + $column * $cellW
        $label = Format-Number $relativeCommands[$column] "0.#"
        [void]$svg.AppendLine("<text x=`"$($x + $cellW / 2)`" y=`"$($panelTop - 10)`" class=`"axis`" text-anchor=`"middle`">$label°</text>")
    }

    for ($rowIndex = 0; $rowIndex -lt $frequencies.Count; $rowIndex++) {
        $frequency = $frequencies[$rowIndex]
        $y = $panelTop + $rowIndex * $cellH
        [void]$svg.AppendLine("<text x=`"$($left - 14)`" y=`"$($y + 24)`" class=`"axis`" text-anchor=`"end`">$(Format-Number $frequency '0.0') GHz</text>")
        for ($column = 0; $column -lt $relativeCommands.Count; $column++) {
            $relativeCommand = $relativeCommands[$column]
            $point = $outputRows |
                Where-Object {
                    $_.channel -eq $channel -and
                    [Math]::Abs($_.frequency_ghz - $frequency) -lt 0.0001 -and
                    [Math]::Abs($_.relative_commanded_from_180_deg - $relativeCommand) -lt 0.001
                } |
                Select-Object -First 1
            $x = $left + $column * $cellW
            $color = Get-HeatColor $point.phase_error_from_180_deg $heatLimit
            $value = Format-Number $point.phase_error_from_180_deg "+0.0;-0.0;0.0"
            $rectClass = if ($relativeCommand -eq 0.0) { "grid reference" } else { "grid" }
            [void]$svg.AppendLine("<rect x=`"$x`" y=`"$y`" width=`"$cellW`" height=`"$cellH`" fill=`"$color`" class=`"$rectClass`"/>")
            [void]$svg.AppendLine("<text x=`"$($x + $cellW / 2)`" y=`"$($y + 24)`" class=`"cell`" text-anchor=`"middle`">$value</text>")
        }
    }
}
[void]$svg.AppendLine("</svg>")
[System.IO.File]::WriteAllText(
    (Join-Path $OutputDirectory "phase_error_reference_180_heatmap.svg"),
    $svg.ToString(),
    [System.Text.UTF8Encoding]::new($false)
)

# Compare RMS error when the same data are referenced to 0 degrees and 180 degrees.
$svg = [System.Text.StringBuilder]::new()
$width = 1500
$height = 780
$plotLeft = 105
$plotRight = 1410
$plotWidth = $plotRight - $plotLeft
$panelTop = @(105, 430)
$panelBottom = @(345, 670)
$yMax = [Math]::Ceiling(
    ($summaryRows |
        ForEach-Object {
            [Math]::Max($_.rms_error_reference_0_deg, $_.rms_error_reference_180_deg)
        } |
        Measure-Object -Maximum).Maximum
)
[void]$svg.AppendLine("<svg xmlns=`"http://www.w3.org/2000/svg`" width=`"$width`" height=`"$height`" viewBox=`"0 0 $width $height`">")
[void]$svg.AppendLine("<rect width=`"100%`" height=`"100%`" fill=`"#ffffff`"/>")
[void]$svg.AppendLine("<style>text{font-family:'Segoe UI',Arial,sans-serif;fill:#172033}.title{font-size:25px;font-weight:600}.sub{font-size:14px;fill:#526078}.axis{font-size:13px}.label{font-size:15px;font-weight:600}.grid{stroke:#d8dee9;stroke-width:1}.ref0{fill:none;stroke:#1565c0;stroke-width:3}.ref180{fill:none;stroke:#ef6c00;stroke-width:3}.dot0{fill:#1565c0}.dot180{fill:#ef6c00}</style>")
[void]$svg.AppendLine("<text x=`"$plotLeft`" y=`"35`" class=`"title`">RMS phase error: 0-degree reference versus 180-degree reference</text>")
[void]$svg.AppendLine("<text x=`"$plotLeft`" y=`"60`" class=`"sub`">Each reference state is zero by definition and is excluded from its corresponding RMS calculation</text>")

foreach ($channel in 1, 2) {
    $topY = $panelTop[$channel - 1]
    $bottomY = $panelBottom[$channel - 1]
    [void]$svg.AppendLine("<text x=`"25`" y=`"$($topY + 20)`" class=`"label`">CH$channel</text>")
    for ($tick = 0; $tick -le $yMax; $tick++) {
        $y = Get-ScalePoint $tick 0.0 $yMax $bottomY $topY
        [void]$svg.AppendLine("<line x1=`"$plotLeft`" y1=`"$y`" x2=`"$plotRight`" y2=`"$y`" class=`"grid`"/>")
        [void]$svg.AppendLine("<text x=`"$($plotLeft - 12)`" y=`"$($y + 5)`" class=`"axis`" text-anchor=`"end`">$tick</text>")
    }

    foreach ($series in @(
        @{ Property = "rms_error_reference_0_deg"; Class = "ref0"; Dot = "dot0" },
        @{ Property = "rms_error_reference_180_deg"; Class = "ref180"; Dot = "dot180" }
    )) {
        $coordinates = @()
        foreach ($frequency in $frequencies) {
            $row = $summaryRows |
                Where-Object {
                    $_.channel -eq $channel -and
                    [Math]::Abs($_.frequency_ghz - $frequency) -lt 0.0001
                } |
                Select-Object -First 1
            $x = Get-ScalePoint $frequency 2.3 3.8 $plotLeft $plotRight
            $y = Get-ScalePoint $row.($series.Property) 0.0 $yMax $bottomY $topY
            $coordinates += "$(Format-Number $x '0.0'),$(Format-Number $y '0.0')"
        }
        [void]$svg.AppendLine("<polyline points=`"$($coordinates -join ' ')`" class=`"$($series.Class)`"/>")
        foreach ($coordinate in $coordinates) {
            $xy = $coordinate.Split(",")
            [void]$svg.AppendLine("<circle cx=`"$($xy[0])`" cy=`"$($xy[1])`" r=`"4`" class=`"$($series.Dot)`"/>")
        }
    }

    foreach ($frequency in $frequencies) {
        $x = Get-ScalePoint $frequency 2.3 3.8 $plotLeft $plotRight
        [void]$svg.AppendLine("<text x=`"$x`" y=`"$($bottomY + 25)`" class=`"axis`" text-anchor=`"middle`">$(Format-Number $frequency '0.0')</text>")
    }
}
[void]$svg.AppendLine("<text x=`"20`" y=`"390`" class=`"axis`" transform=`"rotate(-90 20 390)`" text-anchor=`"middle`">RMS phase error (degrees)</text>")
[void]$svg.AppendLine("<text x=`"$(($plotLeft + $plotRight) / 2)`" y=`"745`" class=`"label`" text-anchor=`"middle`">RF frequency (GHz)</text>")
[void]$svg.AppendLine("<line x1=`"$($plotRight - 360)`" y1=`"85`" x2=`"$($plotRight - 320)`" y2=`"85`" class=`"ref0`"/><text x=`"$($plotRight - 310)`" y=`"90`" class=`"axis`">0-degree reference</text>")
[void]$svg.AppendLine("<line x1=`"$($plotRight - 180)`" y1=`"85`" x2=`"$($plotRight - 140)`" y2=`"85`" class=`"ref180`"/><text x=`"$($plotRight - 130)`" y=`"90`" class=`"axis`">180-degree reference</text>")
[void]$svg.AppendLine("</svg>")
[System.IO.File]::WriteAllText(
    (Join-Path $OutputDirectory "rms_reference_comparison.svg"),
    $svg.ToString(),
    [System.Text.UTF8Encoding]::new($false)
)

$globalSummary = @()
foreach ($channel in 1, 2) {
    $points = @(
        $outputRows |
            Where-Object {
                $_.channel -eq $channel -and
                $_.absolute_commanded_phase_deg -ne 180.0
            }
    )
    $worst = $points |
        Sort-Object { [Math]::Abs($_.phase_error_from_180_deg) } -Descending |
        Select-Object -First 1
    $globalSummary += [pscustomobject]@{
        channel = $channel
        rms_error_reference_180_deg = [Math]::Sqrt(
            (($points |
                ForEach-Object { $_.phase_error_from_180_deg * $_.phase_error_from_180_deg } |
                Measure-Object -Average).Average)
        )
        max_abs_error_reference_180_deg = [Math]::Abs($worst.phase_error_from_180_deg)
        worst_frequency_ghz = $worst.frequency_ghz
        worst_absolute_commanded_phase_deg = $worst.absolute_commanded_phase_deg
        worst_relative_commanded_phase_deg = $worst.relative_commanded_from_180_deg
        worst_error_reference_180_deg = $worst.phase_error_from_180_deg
    }
}

$globalSummary | Format-Table -AutoSize
Write-Output "Output: $((Resolve-Path -LiteralPath $OutputDirectory).Path)"
