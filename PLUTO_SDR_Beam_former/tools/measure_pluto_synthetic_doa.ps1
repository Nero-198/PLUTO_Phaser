[CmdletBinding()]
param(
    [string]$PortName = 'COM4',
    [string]$PlutoUri = 'ip:192.168.2.1',
    [string]$LibiioDirectory = 'tmp/libiio-v0.26/Windows-VS-2022-x64',
    [string]$OutputRoot = '',
    [ValidateRange(325, 6000)][double]$RfFrequencyMHz = 2400.0,
    [ValidateRange(0.05, 2.0)][double]$VirtualSpacingWavelengths = 0.5,
    [ValidateRange(-89.9, 89.9)][double[]]$TargetAnglesDegrees = @(
        -60.0, -45.0, -30.0, -15.0, 0.0, 15.0, 30.0, 45.0, 60.0
    ),
    [ValidateRange(-3, 71)][int]$RxGainDb = 30,
    [ValidateRange(0.0, 1.0)][double]$DdsScale = 0.1,
    [ValidateRange(4096, 262144)][int]$SampleCount = 16384,
    [ValidateRange(1, 5)][int]$Cycles = 1,
    [ValidateRange(1, 10)][int]$CapturesPerState = 2,
    [ValidateRange(0.0, 31.5)][double]$FrontendAttenuationDb = 10.0,
    [ValidateRange(-89.0, -10.0)][double]$EffectiveTxGainDb = -70.0,
    [ValidateRange(0.0, 100.0)][double]$Tx1ExternalAttenuationDb = 20.0,
    [ValidateRange(0.0, 100.0)][double]$Tx2ExternalAttenuationDb = 0.0,
    [switch]$InternalPower,
    [switch]$RfConnectionsVerified,
    [switch]$DryRun,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$culture = [Globalization.CultureInfo]::InvariantCulture
$measureScript = Join-Path $PSScriptRoot 'measure_pluto_phase_presence.ps1'
if (-not (Test-Path -LiteralPath $measureScript)) {
    throw "Measurement script not found: $measureScript"
}
if (-not $DryRun -and -not $RfConnectionsVerified) {
    throw @'
RF loopback has not been confirmed. Connect Tx1/Tx2 through fixed attenuators
to board CH1/CH2 as documented, connect board outputs to Pluto Rx1/Rx2,
terminate unused ports, and rerun with -RfConnectionsVerified.
'@
}
if ([Math]::Max(
        $Tx1ExternalAttenuationDb, $Tx2ExternalAttenuationDb) -lt 20.0) {
    throw 'Place the available fixed attenuator (at least 20 dB) in one Tx path.'
}
$zeroAngleCount = @(
    $TargetAnglesDegrees | Where-Object { [Math]::Abs($_) -lt 1.0e-9 }
).Count
if ($TargetAnglesDegrees.Count -lt 3 -or $zeroAngleCount -eq 0) {
    throw 'TargetAnglesDegrees must contain 0 degrees and at least two other angles.'
}
$tx1GainDb = $EffectiveTxGainDb + $Tx1ExternalAttenuationDb
$tx2GainDb = $EffectiveTxGainDb + $Tx2ExternalAttenuationDb
if ($tx1GainDb -gt 0.0 -or $tx2GainDb -gt 0.0) {
    throw 'Effective gain plus external attenuation exceeds the Pluto gain range.'
}
if ($Tx1ExternalAttenuationDb -lt 20.0 -and $tx1GainDb -gt -60.0) {
    throw 'The Tx1 path without a fixed attenuator must use -60 dB gain or lower.'
}
if ($Tx2ExternalAttenuationDb -lt 20.0 -and $tx2GainDb -gt -60.0) {
    throw 'The Tx2 path without a fixed attenuator must use -60 dB gain or lower.'
}

$orderedAngles = @(
    $TargetAnglesDegrees |
        Sort-Object @{ Expression = { [Math]::Abs([double]$_) } }, @{ Expression = { [double]$_ } }
)
if ($DryRun) {
    $orderedAngles |
        ForEach-Object {
            [pscustomobject]@{
                target_angle_deg = [double]$_
                tx2_relative_phase_deg = [Math]::Round(
                    360.0 * $VirtualSpacingWavelengths *
                    [Math]::Sin([double]$_ * [Math]::PI / 180.0), 6)
                tx1_gain_db = $tx1GainDb
                tx2_gain_db = $tx2GainDb
            }
        } |
        Format-Table -AutoSize |
        Out-String |
        Write-Host
    return
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputRoot = "captures/pluto_synthetic_doa_$stamp"
}
if (Test-Path -LiteralPath $OutputRoot) {
    $existing = @(Get-ChildItem -LiteralPath $OutputRoot -Force)
    if ($existing.Count -gt 0) {
        throw "Output directory is not empty: $OutputRoot"
    }
}
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$OutputRoot = (Resolve-Path -LiteralPath $OutputRoot).Path

$runs = [Collections.Generic.List[object]]::new()
foreach ($angle in $orderedAngles) {
    $angleRadians = [double]$angle * [Math]::PI / 180.0
    $inputPhaseDegrees = 360.0 * $VirtualSpacingWavelengths *
        [Math]::Sin($angleRadians)
    $angleToken = if ($angle -lt 0.0) {
        'm{0:000.0}' -f [Math]::Abs($angle)
    } else {
        'p{0:000.0}' -f $angle
    }
    $runDirectory = Join-Path $OutputRoot "angle_${angleToken}_deg"
    $phaseArgs = @{
        PortName = $PortName
        PlutoUri = $PlutoUri
        LibiioDirectory = $LibiioDirectory
        OutputDirectory = $runDirectory
        RfFrequencyMHz = $RfFrequencyMHz
        RxGainDb = $RxGainDb
        TxGainDb = $tx1GainDb
        Tx2GainDb = $tx2GainDb
        DdsScale = $DdsScale
        EnableSecondTransmitter = $true
        Tx2RelativePhaseDegrees = $inputPhaseDegrees
        LeaveTransmittersSafe = $true
        SampleCount = $SampleCount
        Cycles = $Cycles
        CapturesPerState = $CapturesPerState
        PhaseChannel = 2
        ReferencePhaseDegrees = 0.0
        FrontendAttenuationDb = $FrontendAttenuationDb
        FullPhaseSweep = $true
        InternalPower = [bool]$InternalPower
        Quiet = [bool]$Quiet
    }

    Write-Host (
        'Synthetic angle {0,6:F1} deg: Tx2 relative DDS phase {1,8:F3} deg' -f
        $angle, $inputPhaseDegrees)
    & $measureScript @phaseArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Measurement failed for target angle $angle degrees."
    }

    $runs.Add([pscustomobject]@{
        target_angle_deg = [Math]::Round([double]$angle, 6)
        requested_tx2_relative_phase_deg = [Math]::Round(
            $inputPhaseDegrees, 6)
        directory = Split-Path -Leaf $runDirectory
    })
}

$manifest = [ordered]@{
    timestamp = (Get-Date).ToString('o')
    measurement_type = 'two_tx_synthetic_doa_dual_rx_virtual_combiner'
    rf_frequency_mhz = $RfFrequencyMHz
    virtual_spacing_wavelengths = $VirtualSpacingWavelengths
    phase_scan_channel = 2
    phase_scan_step_deg = 22.5
    rx_gain_db = $RxGainDb
    effective_tx_gain_db_before_dds_scale = $EffectiveTxGainDb
    tx1_gain_db = $tx1GainDb
    tx2_gain_db = $tx2GainDb
    dds_scale = $DdsScale
    frontend_attenuation_db = $FrontendAttenuationDb
    tx1_external_attenuation_db = $Tx1ExternalAttenuationDb
    tx2_external_attenuation_db = $Tx2ExternalAttenuationDb
    captures_per_state = $CapturesPerState
    cycles = $Cycles
    runs = $runs
}
$manifest |
    ConvertTo-Json -Depth 5 |
    Set-Content -LiteralPath (Join-Path $OutputRoot 'synthetic_doa_manifest.json')

Write-Host "Synthetic DoA sweep completed: $OutputRoot"
Write-Host (
    'Analyze with: python tools/analyze_synthetic_doa.py "{0}"' -f
    $OutputRoot)
