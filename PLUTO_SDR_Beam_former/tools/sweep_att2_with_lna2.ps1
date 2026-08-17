[CmdletBinding()]
param(
    [string]$PortName = 'COM4',
    [ValidateRange(1, 30)][int]$StepHoldSeconds = 5
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

function Hold-Step {
    param([Parameter(Mandatory)][double]$AttenuationDb)

    $attenuation = $AttenuationDb.ToString(
        '0.0', [Globalization.CultureInfo]::InvariantCulture)
    Invoke-RfCommand "ATT 2 $attenuation" '^OK$' | Out-Null
    Write-Host ("{0:HH:mm:ss.fff} ATT2={1} dB LNA2=ON" -f
        (Get-Date), $attenuation)

    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $StepHoldSeconds) {
        Start-Sleep -Milliseconds 500
        Invoke-RfCommand 'KEEPALIVE' '^OK KEEPALIVE$' | Out-Null
    }
}

try {
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
    Invoke-RfCommand 'LNA 2 ON' '^OK$' | Out-Null

    foreach ($attenuation in @(
        31.5, 25.0, 20.0, 15.0, 10.0, 5.0, 0.0,
        5.0, 10.0, 15.0, 20.0, 25.0, 31.5
    )) {
        Hold-Step -AttenuationDb $attenuation
    }

    Invoke-RfCommand 'ATT 2 31.5' '^OK$' | Out-Null
    Invoke-RfCommand 'LNA 2 OFF' '^OK$' | Out-Null
    Invoke-RfCommand 'POWER OFF' '^OK POWER=EXTERNAL_SAFE REMOVE_RAILS$' |
        Out-Null
    $rfActive = $false
    Write-Host 'Sweep complete; frontend returned to EXTERNAL_SAFE.'
}
finally {
    if ($serial.IsOpen -and $rfActive) {
        try {
            $serial.Write("SAFE`n")
            Start-Sleep -Milliseconds 100
            Write-Warning 'SAFE sent during cleanup; external rails remain applied.'
        }
        catch {
            Write-Warning "Could not send SAFE: $($_.Exception.Message)"
        }
    }
    if ($serial.IsOpen) { $serial.Close() }
    $serial.Dispose()
}
