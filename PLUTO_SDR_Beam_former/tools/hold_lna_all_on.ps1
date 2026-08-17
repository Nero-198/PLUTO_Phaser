[CmdletBinding()]
param(
    [string]$PortName = 'COM4',
    [ValidateRange(10, 3600)][int]$MaximumHoldSeconds = 600,
    [string]$StopFile = 'tmp/hold_lna_all_on.stop',
    [string]$StateFile = 'tmp/hold_lna_all_on_state.json'
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
$stopReason = 'error'

function Write-HoldState {
    param([string]$Status, [string]$Detail)

    [pscustomobject]@{
        timestamp = (Get-Date).ToString('o')
        status = $Status
        detail = $Detail
        process_id = $PID
        attenuation_ch1_db = 31.5
        attenuation_ch2_db = 31.5
        phase_ch1_degrees = 0.0
        phase_ch2_degrees = 0.0
        lna1 = if ($Status -eq 'holding') { 'ON' } else { 'OFF' }
        lna2 = if ($Status -eq 'holding') { 'ON' } else { 'OFF' }
    } | ConvertTo-Json | Set-Content -LiteralPath $StateFile
}

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

    Write-Host "> $Command"
    $serial.Write("$Command`n")
    $line = Read-RfLine
    Write-Host "< $line"
    if ($line -notmatch $ExpectedPattern) {
        throw "Unexpected response to '$Command': $line"
    }
    return $line
}

try {
    $stateDirectory = Split-Path -Parent $StateFile
    if ($stateDirectory) {
        New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    }
    Remove-Item -LiteralPath $StopFile -Force -ErrorAction SilentlyContinue
    Write-HoldState 'starting' 'Opening RF control connection.'

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
    Invoke-RfCommand 'ATT ALL 31.5' '^OK$' | Out-Null
    Invoke-RfCommand 'PHASE ALL 0' '^OK$' | Out-Null
    Invoke-RfCommand 'LNA ALL OFF' '^OK$' | Out-Null
    Invoke-RfCommand 'LNA ALL ON' '^OK$' | Out-Null
    Write-HoldState 'holding' 'LNA1/2 ON; ATT1/2=31.5 dB; PHASE1/2=0 degrees.'

    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $MaximumHoldSeconds) {
        if (Test-Path -LiteralPath $StopFile) {
            $stopReason = 'requested'
            break
        }
        Start-Sleep -Milliseconds 500
        Invoke-RfCommand 'KEEPALIVE' '^OK KEEPALIVE$' | Out-Null
    }
    if ($stopReason -ne 'requested') { $stopReason = 'timeout' }
}
catch {
    Write-HoldState 'error' $_.Exception.Message
    throw
}
finally {
    if ($serial.IsOpen -and $rfActive) {
        try {
            Invoke-RfCommand 'LNA ALL OFF' '^OK$' | Out-Null
            Invoke-RfCommand 'ATT ALL 31.5' '^OK$' | Out-Null
            Invoke-RfCommand 'POWER OFF' '^OK POWER=EXTERNAL_SAFE REMOVE_RAILS$' |
                Out-Null
            $rfActive = $false
            Write-HoldState 'stopped' "reason=$stopReason; frontend is EXTERNAL_SAFE."
        }
        catch {
            try { $serial.Write("SAFE`n") } catch {}
            Write-HoldState 'cleanup_error' $_.Exception.Message
        }
    }
    if ($serial.IsOpen) { $serial.Close() }
    $serial.Dispose()
}
