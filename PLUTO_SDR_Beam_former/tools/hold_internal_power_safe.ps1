[CmdletBinding()]
param(
    [string]$PortName = "COM4",
    [ValidateRange(10, 900)][int]$DurationSeconds = 300,
    [string]$LogPath = "captures/internal_power_validation_latest.log"
)

$ErrorActionPreference = "Stop"
$serial = [System.IO.Ports.SerialPort]::new(
    $PortName, 115200, [System.IO.Ports.Parity]::None, 8,
    [System.IO.Ports.StopBits]::One
)
$serial.DtrEnable = $true
$serial.NewLine = "`n"
$serial.ReadTimeout = 2500
$serial.WriteTimeout = 2500
$powerEnabled = $false

function Write-Log {
    param([Parameter(Mandatory = $true)][string]$Message)
    $line = "{0:o} {1}" -f [DateTimeOffset]::Now, $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8
    Write-Host $line
}

function Read-Response {
    while ($true) {
        $line = $serial.ReadLine().Trim()
        if ($line -like "READY RF_FRONTEND*") {
            Write-Log $line
            continue
        }
        return $line
    }
}

function Invoke-RfCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$ExpectedPattern
    )

    $serial.Write("$Command`n")
    $response = Read-Response
    Write-Log "> $Command"
    Write-Log "< $response"
    if ($response -notmatch $ExpectedPattern) {
        throw "Unexpected response to '$Command': $response"
    }
    return $response
}

$logDirectory = Split-Path -Parent $LogPath
if ($logDirectory) {
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
}
Set-Content -LiteralPath $LogPath -Value "" -Encoding utf8

try {
    $serial.Open()
    Start-Sleep -Milliseconds 500
    $serial.DiscardInBuffer()

    $status = Invoke-RfCommand "STATUS" "^OK "
    if ($status -notmatch "STATE=OFF" -or
        $status -notmatch "SOURCE=NONE" -or
        $status -notmatch "FAULT=NONE") {
        throw "Frontend is not ready for internal power validation: $status"
    }

    Invoke-RfCommand "POWER ON" "^OK POWER=ON SOURCE=INTERNAL$" | Out-Null
    $powerEnabled = $true
    Invoke-RfCommand "LNA ALL OFF" "^OK$" | Out-Null
    Invoke-RfCommand "ATT ALL 31.5" "^OK$" | Out-Null
    Invoke-RfCommand "PHASE ALL 0" "^OK$" | Out-Null
    $status = Invoke-RfCommand "STATUS" "^OK "
    if ($status -notmatch "STATE=READY" -or
        $status -notmatch "SOURCE=INTERNAL" -or
        $status -notmatch "CH1_LNA=OFF" -or
        $status -notmatch "CH2_LNA=OFF") {
        throw "Unexpected state after power-on: $status"
    }

    Write-Log "MEASURE IC5_OUT=+3.3V IC1_VOUT=-3.3V LNA=OFF"
    $stopAt = [DateTimeOffset]::Now.AddSeconds($DurationSeconds)
    $nextStatus = [DateTimeOffset]::Now.AddSeconds(5)
    while ([DateTimeOffset]::Now -lt $stopAt) {
        Invoke-RfCommand "KEEPALIVE" "^OK KEEPALIVE$" | Out-Null
        if ([DateTimeOffset]::Now -ge $nextStatus) {
            Invoke-RfCommand "STATUS" "^OK STATE=READY .*SOURCE=INTERNAL .*CH1_LNA=OFF .*CH2_LNA=OFF$" |
                Out-Null
            $nextStatus = [DateTimeOffset]::Now.AddSeconds(5)
        }
        Start-Sleep -Milliseconds 500
    }
}
catch {
    Write-Log "ERROR $($_.Exception.Message)"
    throw
}
finally {
    if ($serial.IsOpen) {
        try {
            if ($powerEnabled) {
                Invoke-RfCommand "SAFE" "^OK SAFE$" | Out-Null
                Invoke-RfCommand "STATUS" "^OK " | Out-Null
            }
        }
        catch {
            Write-Log "SAFE_ERROR $($_.Exception.Message)"
        }
        $serial.Close()
    }
    $serial.Dispose()
    Write-Log "TEST_END"
}
