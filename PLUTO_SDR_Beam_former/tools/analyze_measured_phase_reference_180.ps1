[CmdletBinding()]
param(
    [string]$CaptureRoot = "captures/pluto_phase_reference180_20260728",
    [string]$PredictedCsv = "reports/phase_reference_180_20260728/phase_error_reference_180_all_points.csv",
    [string]$OutputDirectory = "reports/phase_reference_180_measured_20260728"
)

$ErrorActionPreference = "Stop"
$directoryPattern = [regex]::new(
    "f(?<frequency>\d+)_sweep_ch(?<dut>[12])_reference_ch(?<reference>[12])_180deg")

$points = @()
foreach ($directory in (Get-ChildItem -LiteralPath $CaptureRoot -Directory)) {
    $match = $directoryPattern.Match($directory.Name)
    if (-not $match.Success) { continue }

    $frequencyGHz = [double]$match.Groups["frequency"].Value / 1000.0
    $dutChannel = [int]$match.Groups["dut"].Value
    $referenceChannel = [int]$match.Groups["reference"].Value
    $summaryPath = Join-Path $directory.FullName "phase_presence_summary.csv"
    if (-not (Test-Path -LiteralPath $summaryPath)) {
        throw "Missing summary: $summaryPath"
    }

    foreach ($row in (Import-Csv -LiteralPath $summaryPath)) {
        $points += [pscustomobject]@{
            frequency_ghz = $frequencyGHz
            swept_channel = $dutChannel
            reference_channel = $referenceChannel
            reference_phase_deg = [double]$row.reference_phase_deg
            swept_commanded_phase_deg = [double]$row.commanded_phase_deg
            expected_relative_phase_deg = [double]$row.expected_delta_from_both_zero_deg
            measured_relative_phase_deg = [double]$row.measured_delta_mean_deg
            signed_phase_error_deg = [double]$row.signed_phase_error_mean_deg
            repeat_circular_std_deg = [double]$row.phase_error_circular_std_deg
            sample_count = [int]$row.sample_count
            ch1_tone_mean_dbfs = [double]$row.ch1_tone_mean_dbfs
            ch2_tone_mean_dbfs = [double]$row.ch2_tone_mean_dbfs
            source_directory = $directory.FullName.Replace("\", "/")
        }
    }
}

if ($points.Count -ne 256) {
    throw "Expected 256 summary points, found $($points.Count)."
}

$frequencySummary = @()
foreach ($group in ($points | Group-Object frequency_ghz, swept_channel)) {
    $items = @($group.Group)
    $nonReference = @(
        $items | Where-Object { $_.swept_commanded_phase_deg -ne 180.0 }
    )
    $worst = $nonReference |
        Sort-Object { [Math]::Abs($_.signed_phase_error_deg) } -Descending |
        Select-Object -First 1
    $frequencySummary += [pscustomobject]@{
        frequency_ghz = $items[0].frequency_ghz
        swept_channel = $items[0].swept_channel
        reference_channel = $items[0].reference_channel
        rms_phase_error_deg = [Math]::Sqrt(
            (($nonReference |
                ForEach-Object {
                    $_.signed_phase_error_deg * $_.signed_phase_error_deg
                } |
                Measure-Object -Average).Average)
        )
        max_abs_phase_error_deg = [Math]::Abs($worst.signed_phase_error_deg)
        worst_commanded_phase_deg = $worst.swept_commanded_phase_deg
        worst_signed_phase_error_deg = $worst.signed_phase_error_deg
        maximum_repeat_std_deg = (
            $items |
                Measure-Object -Property repeat_circular_std_deg -Maximum
        ).Maximum
        minimum_ch1_tone_dbfs = (
            $items | Measure-Object -Property ch1_tone_mean_dbfs -Minimum
        ).Minimum
        minimum_ch2_tone_dbfs = (
            $items | Measure-Object -Property ch2_tone_mean_dbfs -Minimum
        ).Minimum
    }
}

$comparison = @()
if (Test-Path -LiteralPath $PredictedCsv) {
    $predicted = @(Import-Csv -LiteralPath $PredictedCsv)
    foreach ($point in $points) {
        $predictedPoint = $predicted |
            Where-Object {
                [Math]::Abs([double]$_.frequency_ghz - $point.frequency_ghz) -lt 0.0001 -and
                [int]$_.channel -eq $point.swept_channel -and
                [Math]::Abs(
                    [double]$_.absolute_commanded_phase_deg -
                    $point.swept_commanded_phase_deg
                ) -lt 0.001
            } |
            Select-Object -First 1
        if ($null -eq $predictedPoint) { continue }

        # The previous report expressed increasing phase-shift magnitude.
        # The direct measurement expresses signed DUT/reference phase, so its
        # predicted error has the opposite sign.
        $predictedDirectError = -[double]$predictedPoint.phase_error_from_180_deg
        $comparison += [pscustomobject]@{
            frequency_ghz = $point.frequency_ghz
            swept_channel = $point.swept_channel
            swept_commanded_phase_deg = $point.swept_commanded_phase_deg
            directly_measured_error_deg = $point.signed_phase_error_deg
            predicted_from_previous_sweep_deg = $predictedDirectError
            direct_minus_predicted_deg =
                $point.signed_phase_error_deg - $predictedDirectError
        }
    }
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$points |
    Sort-Object frequency_ghz, swept_channel, swept_commanded_phase_deg |
    Export-Csv -LiteralPath (
        Join-Path $OutputDirectory "measured_reference_180_all_points.csv"
    ) -NoTypeInformation -Encoding utf8
$frequencySummary |
    Sort-Object frequency_ghz, swept_channel |
    Export-Csv -LiteralPath (
        Join-Path $OutputDirectory "measured_reference_180_frequency_summary.csv"
    ) -NoTypeInformation -Encoding utf8
if ($comparison.Count -gt 0) {
    $comparison |
        Sort-Object frequency_ghz, swept_channel, swept_commanded_phase_deg |
        Export-Csv -LiteralPath (
            Join-Path $OutputDirectory "direct_vs_postprocessed_comparison.csv"
        ) -NoTypeInformation -Encoding utf8
}

$global = foreach ($channel in 1, 2) {
    $items = @(
        $points |
            Where-Object {
                $_.swept_channel -eq $channel -and
                $_.swept_commanded_phase_deg -ne 180.0
            }
    )
    $worst = $items |
        Sort-Object { [Math]::Abs($_.signed_phase_error_deg) } -Descending |
        Select-Object -First 1
    [pscustomobject]@{
        swept_channel = $channel
        rms_phase_error_deg = [Math]::Sqrt(
            (($items |
                ForEach-Object {
                    $_.signed_phase_error_deg * $_.signed_phase_error_deg
                } |
                Measure-Object -Average).Average)
        )
        max_abs_phase_error_deg = [Math]::Abs($worst.signed_phase_error_deg)
        worst_frequency_ghz = $worst.frequency_ghz
        worst_commanded_phase_deg = $worst.swept_commanded_phase_deg
        worst_signed_phase_error_deg = $worst.signed_phase_error_deg
    }
}

$global | Format-Table -AutoSize
if ($comparison.Count -gt 0) {
    $comparisonWithoutReferences = @(
        $comparison |
            Where-Object { $_.swept_commanded_phase_deg -ne 180.0 }
    )
    $comparisonRms = [Math]::Sqrt(
        (($comparisonWithoutReferences |
            ForEach-Object {
                $_.direct_minus_predicted_deg * $_.direct_minus_predicted_deg
            } |
            Measure-Object -Average).Average)
    )
    Write-Output (
        "Direct-versus-postprocessed residual RMS: {0:F3} degrees" -f
        $comparisonRms)
}
Write-Output "Output: $((Resolve-Path -LiteralPath $OutputDirectory).Path)"
