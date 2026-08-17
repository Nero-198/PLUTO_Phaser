[CmdletBinding()]
param(
    [string]$PortName = "COM4",
    [string]$PlutoUri = "ip:192.168.2.1",
    [string]$OutputRoot = "captures/pluto_phase_reference180_20260728",
    [ValidateRange(-3, 71)][int]$RxGainDb = 30,
    [ValidateRange(-89, 0)][double]$TxGainDb = -20.0,
    [ValidateRange(0.0, 1.0)][double]$DdsScale = 0.25,
    [ValidateRange(0.0, 31.5)][double]$FrontendAttenuationDb = 0.0,
    [ValidateRange(1, 10)][int]$Cycles = 1,
    [ValidateRange(1, 20)][int]$CapturesPerState = 2
)

$ErrorActionPreference = "Stop"
$measureScript = Join-Path $PSScriptRoot "measure_pluto_phase_presence.ps1"
$frequenciesMHz = @(2300, 2400, 2500, 2700, 3000, 3300, 3500, 3800)

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null

foreach ($frequencyMHz in $frequenciesMHz) {
    foreach ($phaseChannel in 1, 2) {
        $referenceChannel = if ($phaseChannel -eq 1) { 2 } else { 1 }
        $outputDirectory = Join-Path $OutputRoot (
            "f{0}_sweep_ch{1}_reference_ch{2}_180deg" -f
            $frequencyMHz, $phaseChannel, $referenceChannel)
        Write-Host (
            "Measuring {0} MHz: sweep CH{1}, hold CH{2} at 180 degrees" -f
            $frequencyMHz, $phaseChannel, $referenceChannel)

        & $measureScript `
            -PortName $PortName `
            -PlutoUri $PlutoUri `
            -OutputDirectory $outputDirectory `
            -RfFrequencyMHz $frequencyMHz `
            -RxGainDb $RxGainDb `
            -TxGainDb $TxGainDb `
            -DdsScale $DdsScale `
            -Cycles $Cycles `
            -CapturesPerState $CapturesPerState `
            -PhaseChannel $phaseChannel `
            -ReferencePhaseDegrees 180.0 `
            -FrontendAttenuationDb $FrontendAttenuationDb `
            -FullPhaseSweep `
            -Quiet

        if ($LASTEXITCODE -ne 0) {
            throw "Measurement failed at ${frequencyMHz} MHz, CH$phaseChannel."
        }

        $summaryPath = Join-Path $outputDirectory "phase_presence_summary.csv"
        if (-not (Test-Path -LiteralPath $summaryPath)) {
            throw "Expected summary was not created: $summaryPath"
        }
        $summary = @(Import-Csv -LiteralPath $summaryPath)
        $maxError = (
            $summary |
                ForEach-Object {
                    [Math]::Abs([double]$_.signed_phase_error_mean_deg)
                } |
                Measure-Object -Maximum
        ).Maximum
        $maxStd = (
            $summary |
                Measure-Object -Property phase_error_circular_std_deg -Maximum
        ).Maximum
        Write-Host (
            "Completed {0} MHz CH{1}: max |error|={2:F2} deg, max repeat std={3:F2} deg" -f
            $frequencyMHz, $phaseChannel, $maxError, $maxStd)
    }
}

Write-Host "All 180-degree-reference measurements completed: $OutputRoot"
