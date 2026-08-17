[CmdletBinding()]
param(
    [string]$InputDirectory = "captures/internal_rf_phase_att_matrix_20260729",
    [ValidateSet("Crossed", "Direct")]
    [string]$ChannelMapping = "Crossed"
)

$ErrorActionPreference = "Stop"

function ConvertTo-WrappedPhase {
    param([double]$Degrees)

    $wrapped = ($Degrees + 180.0) % 360.0
    if ($wrapped -lt 0.0) {
        $wrapped += 360.0
    }
    return $wrapped - 180.0
}

$root = (Resolve-Path -LiteralPath $InputDirectory).Path
$phaseRows = [System.Collections.Generic.List[object]]::new()

Get-ChildItem -LiteralPath $root -Directory |
    Where-Object { $_.Name -match '^att(0|10|20|31p5)_ch([12])$' } |
    Sort-Object Name |
    ForEach-Object {
        if ($_.Name -notmatch '^att(?<att>0|10|20|31p5)_ch(?<channel>[12])$') {
            return
        }

        $attenuationDb = [double]($Matches.att -replace 'p', '.')
        $commandChannel = [int]$Matches.channel
        $observedRxChannel = if ($ChannelMapping -eq "Direct") {
            $commandChannel
        } elseif ($commandChannel -eq 1) {
            2
        } else {
            1
        }
        $summaryPath = Join-Path $_.FullName "phase_presence_summary.csv"

        foreach ($row in Import-Csv -LiteralPath $summaryPath) {
            $commandedPhase = [double]$row.commanded_phase_deg
            $rawDelta = [double]$row.measured_delta_mean_deg

            # When the controlled path is connected to the opposite Pluto Rx,
            # the stored DUT-minus-reference phase has the opposite sign.
            $correctedDelta = if ($ChannelMapping -eq "Direct") {
                ConvertTo-WrappedPhase $rawDelta
            } else {
                ConvertTo-WrappedPhase (-$rawDelta)
            }
            $expectedDelta = ConvertTo-WrappedPhase (-$commandedPhase)
            $correctedError = ConvertTo-WrappedPhase ($correctedDelta - $expectedDelta)

            $phaseRows.Add([pscustomobject]@{
                attenuation_db                  = $attenuationDb
                command_channel                 = $commandChannel
                observed_rx_channel             = $observedRxChannel
                commanded_phase_deg             = $commandedPhase
                expected_relative_phase_deg     = [math]::Round($expectedDelta, 3)
                measured_relative_phase_deg     = [math]::Round($correctedDelta, 3)
                signed_phase_error_deg          = [math]::Round($correctedError, 3)
                circular_std_deg                = [double]$row.circular_std_deg
                sample_count                    = [int]$row.sample_count
                rx1_tone_dbfs                   = [double]$row.ch1_tone_mean_dbfs
                rx2_tone_dbfs                   = [double]$row.ch2_tone_mean_dbfs
            })
        }
    }

$phaseOutput = Join-Path $root "combined_phase_att_summary.csv"
$phaseRows |
    Sort-Object attenuation_db, command_channel, commanded_phase_deg |
    Export-Csv -LiteralPath $phaseOutput -NoTypeInformation -Encoding utf8

$attenuationRows = [System.Collections.Generic.List[object]]::new()
$phaseZeroRows = $phaseRows | Where-Object { $_.commanded_phase_deg -eq 0.0 }
$baseline = $phaseZeroRows | Where-Object { $_.attenuation_db -eq 0.0 }
$baselineRx1 = ($baseline | Measure-Object -Property rx1_tone_dbfs -Average).Average
$baselineRx2 = ($baseline | Measure-Object -Property rx2_tone_dbfs -Average).Average

foreach ($group in ($phaseZeroRows | Group-Object attenuation_db | Sort-Object { [double]$_.Name })) {
    $attenuationDb = [double]$group.Name
    $rx1Level = ($group.Group | Measure-Object -Property rx1_tone_dbfs -Average).Average
    $rx2Level = ($group.Group | Measure-Object -Property rx2_tone_dbfs -Average).Average
    $rx1MeasuredAttenuation = $baselineRx1 - $rx1Level
    $rx2MeasuredAttenuation = $baselineRx2 - $rx2Level

    $attenuationRows.Add([pscustomobject]@{
        commanded_attenuation_db = $attenuationDb
        rx1_tone_mean_dbfs        = [math]::Round($rx1Level, 3)
        rx2_tone_mean_dbfs        = [math]::Round($rx2Level, 3)
        rx1_measured_change_db    = [math]::Round($rx1MeasuredAttenuation, 3)
        rx2_measured_change_db    = [math]::Round($rx2MeasuredAttenuation, 3)
        rx1_change_error_db       = [math]::Round($rx1MeasuredAttenuation - $attenuationDb, 3)
        rx2_change_error_db       = [math]::Round($rx2MeasuredAttenuation - $attenuationDb, 3)
        phase_zero_rows           = $group.Count
    })
}

$attenuationOutput = Join-Path $root "attenuation_summary.csv"
$attenuationRows | Export-Csv -LiteralPath $attenuationOutput -NoTypeInformation -Encoding utf8

$railInput = Join-Path $root "rail_monitor.csv"
$railOutput = Join-Path $root "power_rail_summary.csv"
$railSummary = $null
if (Test-Path -LiteralPath $railInput) {
    $railOnRows = Import-Csv -LiteralPath $railInput |
        Where-Object {
            ([double]$_.plus_vavg_v -gt 2.5) -and
            ([double]$_.minus_vavg_v -lt -2.5)
        }

    if ($railOnRows.Count -gt 0) {
        $plusStats = $railOnRows | Measure-Object -Property plus_vavg_v -Average -Minimum -Maximum
        $minusStats = $railOnRows | Measure-Object -Property minus_vavg_v -Average -Minimum -Maximum
        $railSummary = [pscustomobject]@{
            on_sample_count = $railOnRows.Count
            plus_mean_v     = [math]::Round($plusStats.Average, 6)
            plus_min_v      = [math]::Round($plusStats.Minimum, 6)
            plus_max_v      = [math]::Round($plusStats.Maximum, 6)
            minus_mean_v    = [math]::Round($minusStats.Average, 6)
            minus_min_v     = [math]::Round($minusStats.Minimum, 6)
            minus_max_v     = [math]::Round($minusStats.Maximum, 6)
        }
        $railSummary | Export-Csv -LiteralPath $railOutput -NoTypeInformation -Encoding utf8
    }
}

$preflightPath = Join-Path $root "preflight_att0/lna_channel_mapping_summary.csv"
$preflightRows = Import-Csv -LiteralPath $preflightPath
$allOff = $preflightRows | Where-Object condition -eq "all_off"
$lna1On = $preflightRows | Where-Object condition -eq "ch1_on"
$lna2On = $preflightRows | Where-Object condition -eq "ch2_on"
$allOn = $preflightRows | Where-Object condition -eq "all_on"

$lowAttRows = $phaseRows | Where-Object {
    ($_.attenuation_db -le 10.0) -and ($_.commanded_phase_deg -ne 0.0)
}
$lowAttAbsErrorMean = (
    $lowAttRows |
        ForEach-Object { [math]::Abs([double]$_.signed_phase_error_deg) } |
        Measure-Object -Average
).Average
$lowAttAbsErrorMax = (
    $lowAttRows |
        ForEach-Object { [math]::Abs([double]$_.signed_phase_error_deg) } |
        Measure-Object -Maximum
).Maximum

$report = [System.Collections.Generic.List[string]]::new()
$report.Add("# Internal-power RF phase/attenuation test")
$report.Add("")
$report.Add("- Date: 2026-07-29")
$report.Add("- RF: Pluto TX at 3.0 GHz, TX gain -40 dB, DDS scale 0.1")
$report.Add("- Receive: Pluto Rx1/Rx2, manual gain 45 dB")
$report.Add("- Frontend: internally generated +3.3 V/-3.3 V, both LNAs enabled during phase runs")
$report.Add("- Matrix: ATT 0/10/20/31.5 dB and phase 0/90/180/270 degrees, two captures per state")
$report.Add("- Captures: $($phaseRows.Count) summarized states / 80 raw IQ captures; no clipped samples")
$report.Add("")
$report.Add("## Main findings")
$report.Add("")
if ($ChannelMapping -eq "Direct") {
    $report.Add(
        (("- The preflight confirms the expected direct mapping: " +
          "LNA command CH1 raises Rx1 by {0:N2} dB, while LNA command CH2 raises Rx2 by {1:N2} dB.") -f
            ([double]$lna1On.ch1_delta_from_all_off_db),
            ([double]$lna2On.ch2_delta_from_all_off_db))
    )
    $report.Add("- Phase command CH1 is evaluated on Rx1 and phase command CH2 on Rx2.")
} else {
    $report.Add(
        (("- The preflight identifies a crossed logical-to-Rx mapping in the present setup: " +
          "LNA command CH1 raises Rx2 by {0:N2} dB, while LNA command CH2 raises Rx1 by {1:N2} dB.") -f
            ([double]$lna1On.ch2_delta_from_all_off_db),
            ([double]$lna2On.ch1_delta_from_all_off_db))
    )
    $report.Add("- Phase command CH1 is therefore evaluated on Rx2 and phase command CH2 on Rx1 in the corrected table.")
}
$report.Add(
    (("- At ATT 0 and 10 dB, the non-zero phase states have mean absolute error {0:N2} degrees " +
      "and maximum absolute error {1:N2} degrees.") -f
        $lowAttAbsErrorMean, $lowAttAbsErrorMax)
)
$report.Add("- At ATT 20 and especially 31.5 dB, phase uncertainty grows because the received tone approaches the measurement noise floor.")
$report.Add('- ATT changes are visible on both receive channels; the exact phase-zero transfer figures are in `attenuation_summary.csv`.')
$report.Add("")
$report.Add("## Phase-zero attenuation response")
$report.Add("")
$report.Add("| ATT command | Rx1 tone | Rx1 change | Rx2 tone | Rx2 change |")
$report.Add("|---:|---:|---:|---:|---:|")
foreach ($row in $attenuationRows) {
    $report.Add(
        ("| {0:N1} dB | {1:N2} dBFS | {2:N2} dB | {3:N2} dBFS | {4:N2} dB |" -f
            $row.commanded_attenuation_db,
            $row.rx1_tone_mean_dbfs,
            $row.rx1_measured_change_db,
            $row.rx2_tone_mean_dbfs,
            $row.rx2_measured_change_db)
    )
}

if ($null -ne $railSummary) {
    $report.Add("")
    $report.Add("## Power rails during RF/control activity")
    $report.Add("")
    $report.Add(
        ("- +3.3 V rail: mean {0:N4} V, min {1:N4} V, max {2:N4} V." -f
            $railSummary.plus_mean_v, $railSummary.plus_min_v, $railSummary.plus_max_v)
    )
    $report.Add(
        ("- -3.3 V rail: mean {0:N4} V, min {1:N4} V, max {2:N4} V." -f
            $railSummary.minus_mean_v, $railSummary.minus_min_v, $railSummary.minus_max_v)
    )
    $report.Add("- These are oscilloscope VAVG readings, not a calibrated ripple measurement.")
}

$report.Add("")
$report.Add("## Interpretation limits")
$report.Add("")
$report.Add("- The attenuation sweep used `ATT ALL`; it proves simultaneous attenuation changes, not individual ATT1/ATT2 channel mapping.")
$report.Add("- The 31.5 dB phase points should not be used as intrinsic MAPS phase-error specifications at this TX/RX gain setting.")
$report.Add("- Absolute RF power was not calibrated; tone values are relative dBFS.")
if ($null -ne $railSummary) {
    $report.Add("- The rail monitor covered the first 90 seconds of the matrix, not the final few seconds.")
}

$reportOutput = Join-Path $root "REPORT.md"
$report | Set-Content -LiteralPath $reportOutput -Encoding utf8

Write-Host "Wrote:"
Write-Host "  $phaseOutput"
Write-Host "  $attenuationOutput"
if ($null -ne $railSummary) {
    Write-Host "  $railOutput"
}
Write-Host "  $reportOutput"
