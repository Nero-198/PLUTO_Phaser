[CmdletBinding()]
param(
    [string]$PortName = 'COM4',
    [ValidateRange(50, 1000)][int]$HalfPeriodMilliseconds = 200,
    [ValidateRange(5, 600)][int]$DurationSeconds = 120,
    [string]$StopFile = 'tmp/toggle_att_qc.stop',
    [string]$StateFile = 'tmp/toggle_att_qc_state.json'
)

$ErrorActionPreference = 'Stop'
$serial = [System.IO.Ports.SerialPort]::new(
    $PortName, 115200, [System.IO.Ports.Parity]::None, 8,
    [System.IO.Ports.StopBits]::One
)
$serial.DtrEnable = $true
$serial.ReadTimeout = 2500
$serial.WriteTimeout = 2500
$serial.NewLine = "`n"
$rfActive = $false

function Read-RfLine {
    while ($true) {
        $line = $serial.ReadLine().Trim()
        if ($line -like 'READY RF_FRONTEND*') { continue }
        return $line
    }
}

function Invoke-RfCommand {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$ExpectedPattern
    )

    $serial.Write("$Command`n")
    $line = Read-RfLine
    if ($line -notmatch $ExpectedPattern) {
        throw "Unexpected response to '$Command': $line"
    }
    return $line
}

function Write-ToggleState {
    param(
        [Parameter(Mandatory)][string]$Status,
        [double]$AttenuationDb,
        [int]$Cycle
    )

    [pscustomobject]@{
        timestamp = (Get-Date).ToString('o')
        status = $Status
        attenuation_db = $AttenuationDb
        cycle = $Cycle
        half_period_ms = $HalfPeriodMilliseconds
        expected_d0_ic7_qb = 'LOW'
        expected_d1_ic7_qc = if ($AttenuationDb -eq 0.5) { 'HIGH' } else { 'LOW' }
        expected_d6_ic8_qb = 'LOW'
        expected_d7_ic8_qc = if ($AttenuationDb -eq 0.5) { 'HIGH' } else { 'LOW' }
        lna1 = 'OFF'
        lna2 = 'OFF'
    } | ConvertTo-Json | Set-Content -LiteralPath $StateFile
}

try {
    $stateDirectory = Split-Path -Parent $StateFile
    if ($stateDirectory) {
        New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    }
    Remove-Item -LiteralPath $StopFile -Force -ErrorAction SilentlyContinue

    $serial.Open()
    Start-Sleep -Milliseconds 120
    $serial.DiscardInBuffer()
    $serial.DiscardOutBuffer()

    $status = Invoke-RfCommand 'STATUS' '^OK '
    $offState = $status -match 'STATE=OFF' -and $status -match 'SOURCE=NONE'
    $externalSafe = $status -match 'STATE=EXTERNAL_SAFE' -and
        $status -match 'SOURCE=EXTERNAL'
    if ($status -notmatch 'FAULT=NONE' -or
        (-not $offState -and -not $externalSafe)) {
        throw "Expected safe OFF state with no fault: $status"
    }

    Invoke-RfCommand 'POWER EXTERNAL ON' '^OK POWER=ON SOURCE=EXTERNAL$' |
        Out-Null
    $rfActive = $true
    Invoke-RfCommand 'ATT ALL 0' '^OK$' | Out-Null
    Invoke-RfCommand 'PHASE ALL 0' '^OK$' | Out-Null
    Invoke-RfCommand 'LNA ALL OFF' '^OK$' | Out-Null

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $cycle = 0
    while ($timer.Elapsed.TotalSeconds -lt $DurationSeconds) {
        if (Test-Path -LiteralPath $StopFile) { break }

        ++$cycle
        Invoke-RfCommand 'ATT ALL 0.5' '^OK$' | Out-Null
        Write-ToggleState 'running' 0.5 $cycle
        Start-Sleep -Milliseconds $HalfPeriodMilliseconds

        if (Test-Path -LiteralPath $StopFile) { break }
        Invoke-RfCommand 'ATT ALL 0' '^OK$' | Out-Null
        Write-ToggleState 'running' 0.0 $cycle
        Start-Sleep -Milliseconds $HalfPeriodMilliseconds

        if (($cycle % 10) -eq 0) {
            $frequency = 1000.0 / (2.0 * $HalfPeriodMilliseconds)
            Write-Host ("cycle={0} D1/D7 toggle={1:F2} Hz" -f
                $cycle, $frequency)
        }
    }

    Invoke-RfCommand 'ATT ALL 31.5' '^OK$' | Out-Null
    Invoke-RfCommand 'LNA ALL OFF' '^OK$' | Out-Null
    Invoke-RfCommand 'POWER OFF' '^OK POWER=EXTERNAL_SAFE REMOVE_RAILS$' |
        Out-Null
    $rfActive = $false
    Write-ToggleState 'complete' 31.5 $cycle
    Write-Host "Toggle complete after $cycle cycles; frontend is EXTERNAL_SAFE."
}
finally {
    if ($serial.IsOpen -and $rfActive) {
        try {
            $serial.Write("SAFE`n")
            Start-Sleep -Milliseconds 100
            Write-ToggleState 'stopped' 31.5 $cycle
            Write-Warning 'SAFE sent during cleanup; external rails remain applied.'
        }
        catch {
            Write-Warning "Could not send SAFE: $($_.Exception.Message)"
        }
    }
    if ($serial.IsOpen) { $serial.Close() }
    $serial.Dispose()
}
