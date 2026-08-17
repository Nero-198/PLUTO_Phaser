[CmdletBinding()]
param(
    [string]$PortName = 'COM4',
    [ValidateRange(0.0, 31.5)][double]$Channel1AttenuationDb = 31.5,
    [ValidateRange(0.0, 31.5)][double]$AttenuationDb = 21.0,
    [ValidateRange(10, 3600)][int]$MaximumHoldSeconds = 600,
    [string]$StopFile = 'tmp/hold_att2.stop',
    [string]$StateFile = 'tmp/hold_att2_state.json'
)

$ErrorActionPreference = 'Stop'
$serial = [System.IO.Ports.SerialPort]::new(
    $PortName, 115200, [System.IO.Ports.Parity]::None, 8,
    [System.IO.Ports.StopBits]::One
)
$serial.DtrEnable = $true
$serial.ReadTimeout = 2000
$serial.WriteTimeout = 2000
$serial.NewLine = "`n"
$rfActive = $false
$stopReason = 'error'

function Write-State {
    param([string]$Status, [string]$Detail)
    [pscustomobject]@{
        timestamp = (Get-Date).ToString('o')
        status = $Status
        detail = $Detail
        attenuation_db = $AttenuationDb
        process_id = $PID
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
    param([string]$Command, [string]$ExpectedPattern)
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
    $serial.Open()
    Start-Sleep -Milliseconds 120
    $serial.DiscardInBuffer()
    $serial.DiscardOutBuffer()

    $status = Invoke-RfCommand 'STATUS' '^OK '
    $offState = $status -match 'STATE=OFF' -and $status -match 'SOURCE=NONE'
    $externalSafe = $status -match 'STATE=EXTERNAL_SAFE' -and $status -match 'SOURCE=EXTERNAL'
    if ($status -notmatch 'FAULT=NONE' -or (-not $offState -and -not $externalSafe)) {
        throw "Expected safe OFF state with no fault: $status"
    }

    Invoke-RfCommand 'POWER EXTERNAL ON' '^OK POWER=ON SOURCE=EXTERNAL$' | Out-Null
    $rfActive = $true
    Invoke-RfCommand 'ATT ALL 31.5' '^OK$' | Out-Null
    Invoke-RfCommand 'PHASE ALL 0' '^OK$' | Out-Null
    Invoke-RfCommand 'LNA ALL OFF' '^OK$' | Out-Null
    $channel1Attenuation = $Channel1AttenuationDb.ToString(
        '0.0', [Globalization.CultureInfo]::InvariantCulture)
    Invoke-RfCommand "ATT 1 $channel1Attenuation" '^OK$' | Out-Null
    $attenuation = $AttenuationDb.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)
    Invoke-RfCommand "ATT 2 $attenuation" '^OK$' | Out-Null
    Write-State 'holding' "ATT1=$channel1Attenuation dB; ATT2=$attenuation dB; LNA1/2 OFF"

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
    Write-State 'error' $_.Exception.Message
    throw
}
finally {
    if ($serial.IsOpen -and $rfActive) {
        try {
            Invoke-RfCommand 'ATT 2 31.5' '^OK$' | Out-Null
            Invoke-RfCommand 'LNA ALL OFF' '^OK$' | Out-Null
            Invoke-RfCommand 'POWER OFF' '^OK POWER=EXTERNAL_SAFE REMOVE_RAILS$' | Out-Null
            $rfActive = $false
            Write-State 'stopped' "reason=$stopReason; safe state requested"
        }
        catch {
            try { $serial.Write("SAFE`n") } catch {}
            Write-State 'cleanup_error' $_.Exception.Message
        }
    }
    if ($serial.IsOpen) { $serial.Close() }
    $serial.Dispose()
}
